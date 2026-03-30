import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import Accelerate
import Foundation

/// システム音声を ScreenCaptureKit 経由でキャプチャするサービス。
/// onAudioBuffer コールバックはバックグラウンドスレッドで呼ばれます。
class AudioCaptureService: NSObject {
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 現在の音声レベル (0.0〜1.0)。UI のレベルメーター用。
    var onAudioLevel: ((Float) -> Void)?

    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?

    /// 画面収録の権限が付与済みかチェック
    static var hasScreenCapturePermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 画面収録の権限をリクエスト (システムダイアログを表示)
    /// 権限付与後はアプリの再起動が必要
    static func requestScreenCapturePermission() {
        CGRequestScreenCaptureAccess()
    }

    func startCapture() async throws {
        // 権限チェック
        if !Self.hasScreenCapturePermission {
            Self.requestScreenCapturePermission()
            throw AudioCaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayAvailable
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // サンプルレート・チャンネルはシステムデフォルトを使用
        // (16kHz を要求するとデバイスによっては無音になるため)
        // Whisper 用の 16kHz mono 変換は LocalWhisperService 側で行う
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
            self?.onAudioBuffer?(buffer)
            // 音声レベルを計算して通知
            if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var rms: Float = 0
                vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
                self?.onAudioLevel?(rms)
            }
        }
        streamOutput = output

        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(
            output, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "com.voxnote.audio", qos: .userInteractive)
        )
        try await stream?.startCapture()
    }

    func stopCapture() async throws {
        try await stream?.stopCapture()
        stream = nil
        streamOutput = nil
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
                + "1. 「システム設定を開く」をクリック\n"
                + "2. 画面収録で VoxNote を許可\n"
                + "3. VoxNote を⌘Q で終了して再起動\n\n"
                + "※ 権限付与後はアプリの再起動が必須です"
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
