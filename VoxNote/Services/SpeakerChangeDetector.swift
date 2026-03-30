import AVFoundation
import Accelerate

/// 音声セグメントの簡易スペクトル特徴量を比較して話者を推定するクラス。
/// スレッドセーフではないため、単一スレッドから呼ぶこと。
class SpeakerChangeDetector {
    // 既存話者プロファイルとの距離がこれを超えたら新話者と判定
    private let newSpeakerThreshold: Float = 0.25
    // 各話者の特徴量プロファイル (speakerId → 平均特徴量)
    private var profiles: [(speakerId: UUID, features: [Float])] = []

    /// 音声バッファ列全体からセグメントの特徴量を計算し、
    /// 最も近い既存話者 UUID (なければ新規 UUID) を返す。
    func detectSpeaker(from buffers: [AVAudioPCMBuffer]) -> UUID {
        guard !buffers.isEmpty else {
            return createNewSpeaker(features: [])
        }

        // 最初の 20 バッファ(~1 秒)で特徴量を計算
        let sampleBuffers = Array(buffers.prefix(20))
        let perFrameFeatures = sampleBuffers.compactMap { extractFeatures($0) }
        guard !perFrameFeatures.isEmpty else {
            return createNewSpeaker(features: [])
        }

        let avgFeatures = averageFeatures(perFrameFeatures)

        // 最も近いプロファイルを探す
        var minDist: Float = Float.infinity
        var closestId: UUID? = nil

        for profile in profiles {
            let d = cosineDistance(avgFeatures, profile.features)
            if d < minDist {
                minDist = d
                closestId = profile.speakerId
            }
        }

        if minDist <= newSpeakerThreshold, let id = closestId {
            // 既存話者のプロファイルを指数移動平均で更新
            if let idx = profiles.firstIndex(where: { $0.speakerId == id }) {
                profiles[idx].features = ema(old: profiles[idx].features, new: avgFeatures, alpha: 0.3)
            }
            return id
        } else {
            return createNewSpeaker(features: avgFeatures)
        }
    }

    func reset() {
        profiles = []
    }

    // MARK: - 特徴量抽出

    /// エネルギー・ゼロ交差率・スペクトル重心の 3 次元特徴量を返す
    private func extractFeatures(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard
            let data = buffer.floatChannelData?[0],
            buffer.frameLength > 8
        else { return nil }

        let n = Int(buffer.frameLength)
        let ptr = UnsafeBufferPointer(start: data, count: n)
        let samples = Array(ptr)

        // RMS エネルギー
        var sqSum: Float = 0
        vDSP_svesq(samples, 1, &sqSum, vDSP_Length(n))
        let energy = sqrt(sqSum / Float(n))

        // ゼロ交差率
        var zcr: Float = 0
        for i in 1..<n {
            if (samples[i] >= 0) != (samples[i - 1] >= 0) { zcr += 1 }
        }
        zcr /= Float(n)

        // スペクトル重心 (FFT)
        let fftN = min(n, 512)
        var real = Array(samples.prefix(fftN))
        var imag = [Float](repeating: 0, count: fftN)
        var mags = [Float](repeating: 0, count: fftN / 2)

        real.withUnsafeMutableBufferPointer { rBuf in
            imag.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                let log2n = vDSP_Length(log2(Float(fftN)))
                guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(fftN / 2))
                vDSP_destroy_fftsetup(setup)
            }
        }

        var weightedIdx: Float = 0, totalMag: Float = 0
        for (i, m) in mags.enumerated() { weightedIdx += Float(i) * m; totalMag += m }
        let centroid = totalMag > 0 ? (weightedIdx / totalMag) / Float(fftN / 2) : 0

        return [energy, zcr, centroid]
    }

    // MARK: - ヘルパー

    private func createNewSpeaker(features: [Float]) -> UUID {
        let id = UUID()
        profiles.append((speakerId: id, features: features))
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
