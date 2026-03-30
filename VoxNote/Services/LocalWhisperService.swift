import Foundation
import AVFoundation
// whisper.h は BridgingHeader.h 経由でインポート

/// whisper.cpp を使ったローカル音声文字起こしサービス。
/// API キー不要、完全オフラインで動作する。
class LocalWhisperService {
    private var ctx: OpaquePointer?

    // Whisper が安定して動作する最低サンプル数 (16kHz × 3秒)
    // 短すぎる音声はハルシネーションを起こすため、無音でパディングする
    private static let minSamples = 16000 * 3

    init(modelPath: String) throws {
        ctx = whisper_init_from_file(modelPath)
        guard ctx != nil else {
            throw LocalWhisperError.modelLoadFailed(modelPath)
        }
    }

    deinit {
        if let ctx = ctx {
            whisper_free(ctx)
        }
    }

    /// 音声バッファ列を文字起こしする。
    /// バッファは 16kHz mono Float32 に変換される。
    /// language: nil で日本語、"en" で英語、"auto" で自動検出。
    func transcribe(buffers: [AVAudioPCMBuffer], language: String? = nil) throws -> String {
        var samples = try extractSamples(from: buffers)
        guard samples.count >= 1600 else { throw LocalWhisperError.audioTooShort }

        // 短い音声は無音パディングで最低3秒にする (ハルシネーション防止)
        if samples.count < Self.minSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: Self.minSamples - samples.count))
        }

        return transcribeSamples(samples, language: language)
    }

    // MARK: - whisper.cpp 呼び出し

    private func transcribeSamples(_ samples: [Float], language: String? = nil) -> String {
        guard let ctx = ctx else { return "" }

        // BEAM_SEARCH で精度を優先 (GREEDY より遅いが正確)
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_timestamps = true
        params.no_context = true            // 前回の結果を引きずらない
        params.single_segment = false       // 長いチャンクは複数セグメントで処理
        params.suppress_blank = true        // 空白トークンを抑制
        params.temperature = 0.0            // 決定的な出力 (ハルシネーション抑制)
        params.temperature_inc = 0.0        // 温度を上げない
        params.greedy.best_of = 5           // 候補を増やして精度向上
        params.beam_search.beam_size = 5    // ビームサーチ幅
        params.n_threads = Int32(min(ProcessInfo.processInfo.activeProcessorCount, 8))

        // 言語設定
        let langStr = strdup(language ?? "ja")
        params.language = UnsafePointer(langStr)
        defer { free(langStr) }

        let result = samples.withUnsafeBufferPointer { ptr in
            whisper_full(ctx, params, ptr.baseAddress, Int32(samples.count))
        }

        guard result == 0 else { return "[文字起こし失敗]" }

        var text = ""
        let nSegments = whisper_full_n_segments(ctx)
        for i in 0..<nSegments {
            if let segText = whisper_full_get_segment_text(ctx, i) {
                let segment = String(cString: segText).trimmingCharacters(in: .whitespacesAndNewlines)
                // ハルシネーション抑制: 短い繰り返しや明らかな誤検出を除外
                if !segment.isEmpty && !isHallucination(segment) {
                    text += segment
                }
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// よくあるハルシネーションパターンを検出
    private func isHallucination(_ text: String) -> Bool {
        let hallucinations = [
            "ご視聴ありがとうございました",
            "お疲れ様でした",
            "さようなら",
            "ありがとうございました",
            "チャンネル登録",
            "おやすみなさい",
            "Thank you for watching",
            "Thanks for watching",
            "Subscribe",
        ]
        return hallucinations.contains { text.contains($0) }
    }

    // MARK: - 音声変換

    private func extractSamples(from buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        guard let first = buffers.first else { throw LocalWhisperError.audioTooShort }

        let sourceFormat = first.format
        let targetRate: Double = 16000

        // 全バッファのサンプルを結合
        var allSamples: [Float] = []

        for buffer in buffers {
            guard let data = buffer.floatChannelData?[0] else { continue }
            let count = Int(buffer.frameLength)
            let arr = Array(UnsafeBufferPointer(start: data, count: count))
            allSamples.append(contentsOf: arr)
        }

        // リサンプリング (sourceFormat.sampleRate → 16kHz)
        if abs(sourceFormat.sampleRate - targetRate) > 1.0 {
            allSamples = resample(allSamples, from: sourceFormat.sampleRate, to: targetRate)
        }

        return allSamples
    }

    /// 線形補間によるシンプルなリサンプリング
    private func resample(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        let ratio = srcRate / dstRate
        let outCount = Int(Double(input.count) / ratio)
        guard outCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcIdx = Double(i) * ratio
            let lo = Int(srcIdx)
            let hi = min(lo + 1, input.count - 1)
            let frac = Float(srcIdx - Double(lo))
            output[i] = input[lo] * (1 - frac) + input[hi] * frac
        }
        return output
    }
}

enum LocalWhisperError: LocalizedError {
    case modelLoadFailed(String)
    case audioTooShort

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): return "Whisper モデルの読み込みに失敗: \(path)"
        case .audioTooShort: return "音声が短すぎます"
        }
    }
}
