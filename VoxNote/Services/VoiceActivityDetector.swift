import AVFoundation
import Accelerate

/// エネルギー閾値ベースのシンプルな音声区間検出 (VAD)。
/// スレッドセーフではないため、単一スレッドから呼ぶこと。
class VoiceActivityDetector {
    // 音声と判断するエネルギー閾値 (RMS)
    // システム音声は直接入力より小さいため低めに設定
    private let speechThreshold: Float = 0.001
    // この時間以上無音が続いたら発話終了とみなす
    private let silenceTimeout: TimeInterval = 0.5

    private var isSpeaking = false
    private var silenceStartTime: Date?

    func process(buffer: AVAudioPCMBuffer) -> VADEvent {
        let rms = computeRMS(buffer: buffer)
        let now = Date()

        if rms > speechThreshold {
            // 音声あり
            silenceStartTime = nil
            if !isSpeaking {
                isSpeaking = true
                return .speechStarted
            }
            return .speaking
        } else {
            // 無音
            if isSpeaking {
                if let start = silenceStartTime {
                    if now.timeIntervalSince(start) >= silenceTimeout {
                        isSpeaking = false
                        silenceStartTime = nil
                        return .speechEnded
                    }
                } else {
                    silenceStartTime = now
                }
                // まだタイムアウト前は speaking 扱い
                return .speaking
            }
            return .silence
        }
    }

    func reset() {
        isSpeaking = false
        silenceStartTime = nil
    }

    private func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard
            let data = buffer.floatChannelData?[0],
            buffer.frameLength > 0
        else { return 0 }

        var sumOfSquares: Float = 0
        vDSP_svesq(data, 1, &sumOfSquares, vDSP_Length(buffer.frameLength))
        return sqrt(sumOfSquares / Float(buffer.frameLength))
    }
}

enum VADEvent {
    case silence
    case speechStarted
    case speaking
    case speechEnded
}
