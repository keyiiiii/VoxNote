import Foundation
import CryptoKit

/// Whisper モデルファイルのダウンロードと管理を行うクラス。
/// モデルは ~/Library/Application Support/VoxNote/models/ に保存される。
@MainActor
class ModelManager: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var downloadingModel: WhisperModel?
    @Published var isModelReady = false
    @Published var selectedModel: WhisperModel {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: "whisper_model") }
    }
    @Published var errorMessage: String?
    @Published var statusMessage: String = ""

    private var downloadTask: URLSessionDownloadTask?

    static let shared = ModelManager()

    private init() {
        let saved = UserDefaults.standard.string(forKey: "whisper_model") ?? WhisperModel.base.rawValue
        self.selectedModel = WhisperModel(rawValue: saved) ?? .base
        self.isModelReady = modelFileExists(for: selectedModel)
    }

    // MARK: - モデルファイルパス

    var currentModelPath: String? {
        let url = modelFileURL(for: selectedModel)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    func modelFileURL(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.filename)
    }

    func modelFileExists(for model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: modelFileURL(for: model).path)
    }

    private var modelsDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxNote/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - ダウンロード

    func downloadModelIfNeeded() async {
        guard !modelFileExists(for: selectedModel) else {
            isModelReady = true
            return
        }
        await downloadModel(selectedModel)
    }

    func downloadModel(_ model: WhisperModel) async {
        guard !isDownloading else { return }

        isDownloading = true
        downloadingModel = model
        downloadProgress = 0
        errorMessage = nil

        let destination = modelFileURL(for: model)

        do {
            let (tempURL, _) = try await downloadWithProgress(from: model.downloadURL, to: destination)

            // SHA256 チェックサム検証
            if let expectedHash = model.sha256 {
                statusMessage = "チェックサム検証中…"
                let data = try Data(contentsOf: tempURL)
                let hash = SHA256.hash(data: data)
                let hexHash = hash.map { String(format: "%02x", $0) }.joined()
                guard hexHash == expectedHash else {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw ModelError.checksumMismatch(expected: expectedHash, actual: hexHash)
                }
            }

            // 一時ファイルを最終パスに移動
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)

            selectedModel = model
            isModelReady = true
        } catch is CancellationError {
            errorMessage = "ダウンロードがキャンセルされました"
        } catch {
            errorMessage = "ダウンロード失敗: \(error.localizedDescription)"
        }

        isDownloading = false
        downloadingModel = nil
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
    }

    func selectModel(_ model: WhisperModel) {
        selectedModel = model
        isModelReady = modelFileExists(for: model)
    }

    // MARK: - ダウンロード実装

    private func downloadWithProgress(from url: URL, to destination: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.downloadProgress = progress }
                },
                onComplete: { result in
                    continuation.resume(with: result)
                }
            )

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        }
    }
}

// MARK: - モデル定義

enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"
    case largeTurbo = "large-v3-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny:       return "Tiny (~75 MB)"
        case .base:       return "Base (~142 MB)"
        case .small:      return "Small (~466 MB) — 推奨"
        case .medium:     return "Medium (~1.5 GB) — 高精度"
        case .largeTurbo: return "Large v3 Turbo (~1.6 GB) — 最高精度"
        }
    }

    var filename: String { "ggml-\(rawValue).bin" }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(rawValue).bin")!
    }

    /// ダウンロード後に検証する SHA256 チェックサム (nil の場合はスキップ)
    var sha256: String? {
        switch self {
        case .base: return "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        default:    return nil
        }
    }
}

enum ModelError: LocalizedError {
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch(let expected, let actual):
            return "モデルファイルの整合性チェックに失敗しました。\n期待: \(expected.prefix(16))…\n実際: \(actual.prefix(16))…\nダウンロードが破損している可能性があります。再試行してください。"
        }
    }
}

// MARK: - ダウンロードデリゲート

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onComplete: (Result<(URL, URLResponse), Error>) -> Void
    private var completed = false

    init(onProgress: @escaping (Double) -> Void, onComplete: @escaping (Result<(URL, URLResponse), Error>) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !completed else { return }
        completed = true

        // 一時ファイルをコピー (URLSession がすぐ消すため)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        do {
            try FileManager.default.copyItem(at: location, to: temp)
            let response = downloadTask.response ?? URLResponse()
            onComplete(.success((temp, response)))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !completed, let error = error else { return }
        completed = true
        onComplete(.failure(error))
    }
}
