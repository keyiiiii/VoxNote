import AVFoundation

/// 音声バッファの出所を区別するタグ
enum AudioSource {
    case microphone  // 自分の声
    case system      // 相手の声（ScreenCaptureKit 経由）
}

/// ソース付き音声バッファ
struct TaggedAudioBuffer {
    let buffer: AVAudioPCMBuffer
    let source: AudioSource
}
