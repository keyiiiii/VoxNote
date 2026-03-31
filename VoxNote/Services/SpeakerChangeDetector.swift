import AVFoundation
import Accelerate

/// 音声ソース（マイク/システム）+ MFCC 音声特徴量を使って話者を推定するクラス。
/// マイク入力は常に「自分」、システム音声は音響特徴量で相手を区別する。
class SpeakerChangeDetector {
    // 既存話者プロファイル
    private var profiles: [SpeakerProfile] = []
    // マイク（自分）用の固定 ID
    private var microphoneSpeakerId: UUID?

    // 新話者と判定するコサイン距離の閾値 (低いほど敏感に分離)
    private let newSpeakerThreshold: Float = 0.15

    // MFCC 設定
    private let numMFCC = 13
    private let fftSize = 512
    private let numMelFilters = 26

    struct SpeakerProfile {
        let speakerId: UUID
        var features: [Float]         // MFCC 平均特徴量
        let source: AudioSource       // このプロファイルのソース
        var sampleCount: Int = 1      // プロファイル更新回数
    }

    /// 音声バッファ列からセグメントの話者を推定する。
    /// source: .microphone なら常に「自分」として固定 ID を返す。
    /// source: .system なら MFCC 特徴量で既存話者と比較・クラスタリング。
    func detectSpeaker(from buffers: [AVAudioPCMBuffer], source: AudioSource = .system) -> UUID {
        // マイク入力 = 自分 (常に同じ ID)
        if source == .microphone {
            if microphoneSpeakerId == nil {
                microphoneSpeakerId = UUID()
            }
            return microphoneSpeakerId!
        }

        // システム音声 = 相手。MFCC で話者クラスタリング
        guard !buffers.isEmpty else {
            return createNewSpeaker(features: [], source: source)
        }

        // 各バッファから複数フレームの MFCC を抽出
        var perFrameFeatures: [[Float]] = []
        for buffer in buffers.prefix(10) {
            let multiFrame = extractMultiFrameMFCC(buffer)
            perFrameFeatures.append(contentsOf: multiFrame)
        }
        guard !perFrameFeatures.isEmpty else {
            return createNewSpeaker(features: [], source: source)
        }

        let avgFeatures = averageFeatures(perFrameFeatures)

        // システム音声のプロファイルのみ比較
        let systemProfiles = profiles.filter { $0.source == .system }
        var minDist: Float = Float.infinity
        var closestId: UUID? = nil

        for profile in systemProfiles {
            guard !profile.features.isEmpty else { continue }
            let d = cosineDistance(avgFeatures, profile.features)
            if d < minDist {
                minDist = d
                closestId = profile.speakerId
            }
        }

        if minDist <= newSpeakerThreshold, let id = closestId {
            // 既存話者のプロファイルを更新 (指数移動平均)
            if let idx = profiles.firstIndex(where: { $0.speakerId == id }) {
                let alpha: Float = 1.0 / Float(min(profiles[idx].sampleCount + 1, 20))
                profiles[idx].features = ema(old: profiles[idx].features, new: avgFeatures, alpha: alpha)
                profiles[idx].sampleCount += 1
            }
            return id
        } else {
            return createNewSpeaker(features: avgFeatures, source: source)
        }
    }

    func reset() {
        profiles = []
        microphoneSpeakerId = nil
    }

    // MARK: - MFCC 特徴量抽出

    /// 長いバッファから複数位置の MFCC を抽出 (音声全体の特徴を捉える)
    private func extractMultiFrameMFCC(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        guard let data = buffer.floatChannelData?[0],
              buffer.frameLength >= UInt32(fftSize) else { return [] }

        let totalFrames = Int(buffer.frameLength)
        let hopSize = fftSize  // フレーム間隔 = FFT サイズ (オーバーラップなし)
        let numFrames = min((totalFrames - fftSize) / hopSize + 1, 20) // 最大 20 フレーム
        guard numFrames > 0 else { return [] }

        var results: [[Float]] = []
        for i in 0..<numFrames {
            let offset = i * hopSize
            let frameData = Array(UnsafeBufferPointer(start: data + offset, count: fftSize))
            if let mfcc = computeSingleFrameMFCC(frameData, sampleRate: Float(buffer.format.sampleRate)) {
                results.append(mfcc)
            }
        }
        return results
    }

    /// 1フレーム (512 samples) から MFCC を抽出
    private func computeSingleFrameMFCC(_ samples: [Float], sampleRate: Float) -> [Float]? {
        guard samples.count >= fftSize else { return nil }

        var windowed = applyHammingWindow(samples)
        let powerSpectrum = computePowerSpectrum(&windowed)
        let melEnergies = applyMelFilterBank(powerSpectrum, sampleRate: sampleRate)
        let mfcc = computeDCT(melEnergies)
        return Array(mfcc.prefix(numMFCC))
    }

    /// 13次元 MFCC 特徴量を抽出 (単一バッファ、後方互換)
    private func extractMFCC(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let data = buffer.floatChannelData?[0],
              buffer.frameLength >= UInt32(fftSize) else { return nil }

        let n = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: data, count: min(n, fftSize)))

        // 1. ハミング窓を適用
        var windowed = applyHammingWindow(samples)

        // 2. FFT → パワースペクトル
        let powerSpectrum = computePowerSpectrum(&windowed)

        // 3. メルフィルタバンク適用
        let melEnergies = applyMelFilterBank(powerSpectrum, sampleRate: Float(buffer.format.sampleRate))

        // 4. DCT → MFCC
        let mfcc = computeDCT(melEnergies)

        return Array(mfcc.prefix(numMFCC))
    }

    private func applyHammingWindow(_ samples: [Float]) -> [Float] {
        var result = samples
        let n = samples.count
        for i in 0..<n {
            let w = 0.54 - 0.46 * cos(2.0 * Float.pi * Float(i) / Float(n - 1))
            result[i] *= w
        }
        return result
    }

    private func computePowerSpectrum(_ samples: inout [Float]) -> [Float] {
        let n = samples.count
        var imag = [Float](repeating: 0, count: n)
        var mags = [Float](repeating: 0, count: n / 2)

        samples.withUnsafeMutableBufferPointer { rBuf in
            imag.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                let log2n = vDSP_Length(log2(Float(n)))
                guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
                vDSP_destroy_fftsetup(setup)
            }
        }

        // パワーに変換 (magnitude^2 / N)
        var scale = Float(n)
        vDSP_vsdiv(mags, 1, &scale, &mags, 1, vDSP_Length(n / 2))

        return mags
    }

    private func applyMelFilterBank(_ powerSpectrum: [Float], sampleRate: Float) -> [Float] {
        let nfft = powerSpectrum.count * 2
        let lowFreq: Float = 0
        let highFreq = sampleRate / 2

        // Hz → Mel 変換
        func hzToMel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

        let lowMel = hzToMel(lowFreq)
        let highMel = hzToMel(highFreq)

        // メルスケールで等間隔にフィルタ中心を配置
        var melPoints = [Float](repeating: 0, count: numMelFilters + 2)
        for i in 0..<(numMelFilters + 2) {
            melPoints[i] = lowMel + Float(i) * (highMel - lowMel) / Float(numMelFilters + 1)
        }

        // Mel → Hz → FFT bin
        let binPoints = melPoints.map { mel -> Int in
            let hz = melToHz(mel)
            return Int(floor(Float(nfft + 1) * hz / sampleRate))
        }

        var filterEnergies = [Float](repeating: 0, count: numMelFilters)
        for m in 0..<numMelFilters {
            let start = binPoints[m]
            let center = binPoints[m + 1]
            let end = binPoints[m + 2]

            for k in start..<center {
                guard k < powerSpectrum.count else { continue }
                let weight = Float(k - start) / max(Float(center - start), 1)
                filterEnergies[m] += powerSpectrum[k] * weight
            }
            for k in center..<end {
                guard k < powerSpectrum.count else { continue }
                let weight = Float(end - k) / max(Float(end - center), 1)
                filterEnergies[m] += powerSpectrum[k] * weight
            }
        }

        // log エネルギー
        for i in 0..<numMelFilters {
            filterEnergies[i] = log(max(filterEnergies[i], 1e-10))
        }

        return filterEnergies
    }

    private func computeDCT(_ input: [Float]) -> [Float] {
        let n = input.count
        var output = [Float](repeating: 0, count: n)
        for k in 0..<n {
            var sum: Float = 0
            for i in 0..<n {
                sum += input[i] * cos(Float.pi * Float(k) * (Float(i) + 0.5) / Float(n))
            }
            output[k] = sum
        }
        return output
    }

    // MARK: - ヘルパー

    private func createNewSpeaker(features: [Float], source: AudioSource) -> UUID {
        let id = UUID()
        profiles.append(SpeakerProfile(speakerId: id, features: features, source: source))
        return id
    }

    private func averageFeatures(_ list: [[Float]]) -> [Float] {
        guard let dim = list.first?.count else { return [] }
        var avg = [Float](repeating: 0, count: dim)
        for f in list {
            for i in 0..<min(dim, f.count) { avg[i] += f[i] }
        }
        return avg.map { $0 / Float(list.count) }
    }

    private func ema(old: [Float], new: [Float], alpha: Float) -> [Float] {
        guard old.count == new.count else { return new }
        return zip(old, new).map { o, n in (1 - alpha) * o + alpha * n }
    }

    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let denom = sqrt(na) * sqrt(nb)
        return denom > 0 ? 1.0 - (dot / denom) : 1.0
    }
}
