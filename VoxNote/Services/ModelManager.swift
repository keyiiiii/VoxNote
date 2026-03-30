import Foundation

/// Whisper モデルファイルのダウンロードと管理を行うクラス。
/// モデルは ~/Library/Application Support/VoxNote/models/ に保存される。
@MainActor
class ModelManager: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var isModelReady = false
    @Published var selectedModel: WhisperModel {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: "whisper_model") }
    }
    @Published var errorMessage: String?

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
        downloadProgress = 0
        errorMessage = nil

        let destination = modelFileURL(for: model)

        do {
            let (tempURL, _) = try await downloadWithProgress(from: model.downloadURL, to: destination)

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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny:  return "Tiny (~75 MB)"
        case .base:  return "Base (~142 MB) — 推奨"
        case .small: return "Small (~466 MB) — 高精度"
        }
    }

    var filename: String { "ggml-\(rawValue).bin" }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(rawValue).bin")!
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
