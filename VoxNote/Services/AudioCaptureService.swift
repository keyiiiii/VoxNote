import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import Accelerate
import Foundation

/// システム音声 (ScreenCaptureKit) + マイク入力 (AVAudioEngine) を同時にキャプチャし、
/// ミックスして1つのバッファとして返すサービス。
class AudioCaptureService: NSObject {
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 現在の音声レベル (0.0〜1.0)。UI のレベルメーター用。
    var onAudioLevel: ((Float) -> Void)?

    // ScreenCaptureKit (システム音声: 相手の声)
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?

    // AVAudioEngine (マイク入力: 自分の声)
    private var audioEngine: AVAudioEngine?
    private let micQueue = DispatchQueue(label: "com.voxnote.mic", qos: .userInteractive)

    /// 画面収録の権限をリクエスト (システムダイアログを表示)
    static func requestScreenCapturePermission() {
        CGRequestScreenCaptureAccess()
    }

    func startCapture() async throws {
        // 1. システム音声キャプチャ (ScreenCaptureKit)
        try await startSystemAudioCapture()

        // 2. マイク入力キャプチャ (AVAudioEngine)
        try startMicrophoneCapture()
    }

    func stopCapture() async throws {
        // マイク停止
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // システム音声停止
        try await stream?.stopCapture()
        stream = nil
        streamOutput = nil
    }

    // MARK: - システム音声 (相手の声)

    private func startSystemAudioCapture() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            CGRequestScreenCaptureAccess()
            throw AudioCaptureError.permissionDenied
        }

        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayAvailable
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 1

        // 画面は最小サイズで取得 (音声のみ必要)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let output = AudioStreamOutput()
        output.onAudioBuffer = { [weak self] buffer in
            self?.handleAudioBuffer(buffer)
        }
        streamOutput = output

        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(
            output, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "com.voxnote.system-audio", qos: .userInteractive)
        )
        try await stream?.startCapture()
    }

    // MARK: - マイク入力 (自分の声)

    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // 48kHz mono に変換するフォーマット
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ) else { return }

        // フォーマット変換が必要な場合は converter を用意
        let needsConversion = inputFormat.sampleRate != targetFormat.sampleRate
            || inputFormat.channelCount != targetFormat.channelCount

        inputNode.installTap(onBus: 0, bufferSize: 4800, format: inputFormat) { [weak self] buffer, _ in
            if needsConversion {
                // リサンプリング + モノ変換
                guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return }
                let ratio = targetFormat.sampleRate / inputFormat.sampleRate
                let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 100
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

                var provided = false
                var convError: NSError?
                converter.convert(to: converted, error: &convError) { _, status in
                    if !provided {
                        provided = true
                        status.pointee = .haveData
                        return buffer
                    }
                    status.pointee = .endOfStream
                    return nil
                }
                if convError == nil {
                    self?.handleAudioBuffer(converted)
                }
            } else {
                self?.handleAudioBuffer(buffer)
            }
        }

        try engine.start()
        audioEngine = engine
    }

    // MARK: - 共通バッファ処理

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        onAudioBuffer?(buffer)
        // 音声レベルを計算して通知
        if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var rms: Float = 0
            vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
            onAudioLevel?(rms)
        }
    }
}

enum AudioCaptureError: LocalizedError, Equatable {
    case noDisplayAvailable
    case permissionDenied
    case permissionRequiresRestart

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "キャプチャできるディスプレイが見つかりません"
        case .permissionDenied:
            return "画面収録の権限が必要です。\n\n"
                + "初回の場合:\n"
                + "  画面収録で VoxNote を許可 → アプリを再起動\n\n"
                + "許可済みなのに表示される場合:\n"
                + "  一覧から VoxNote を「−」で削除 → アプリを再起動\n"
                + "  → 自動で再追加されるので ON にする"
        case .permissionRequiresRestart:
            return "画面収録の権限が更新されました。\n"
                + "VoxNote を⌘Q で完全に終了してから再度起動してください。"
        }
    }
}

// MARK: - SCStreamOutput 実装

private class AudioStreamOutput: NSObject, SCStreamOutput {
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard let buffer = try? sampleBuffer.toAVAudioPCMBuffer() else { return }
        onAudioBuffer?(buffer)
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer 変換

private extension CMSampleBuffer {
    func toAVAudioPCMBuffer() throws -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self) else { return nil }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }

        return buffer
    }
}
