import Foundation

/// Ollama のインストール・起動・モデル管理を全自動で行うマネージャー。
@MainActor
class OllamaManager: ObservableObject {
    @Published var status: OllamaStatus = .unknown
    @Published var pullProgress: Double = 0
    @Published var errorMessage: String?

    let service: OllamaService
    private var serverProcess: Process?

    static let shared = OllamaManager()
    static let defaultModel = "qwen3:8b"

    private init() {
        self.service = OllamaService()
    }

    // MARK: - 自動セットアップ

    /// Ollama のインストール・起動・モデルダウンロードを全自動で行う
    func ensureReady() async {
        errorMessage = nil

        // 1. サーバーが既に起動中か確認
        if await service.isAvailable() {
            await checkModel()
            return
        }

        // 2. ollama バイナリが存在するか確認
        if !ollamaIsInstalled() {
            status = .notInstalled
            // 自動インストールを試みる
            do {
                try await installOllama()
            } catch {
                errorMessage = "Ollama のインストールに失敗しました: \(error.localizedDescription)"
                return
            }
        }

        // 3. サーバーを起動
        status = .starting
        do {
            try startServer()
            // サーバーが起動するまで待つ
            for _ in 0..<30 {
                try await Task.sleep(for: .seconds(1))
                if await service.isAvailable() { break }
            }
            guard await service.isAvailable() else {
                status = .error
                errorMessage = "Ollama サーバーの起動に失敗しました"
                return
            }
        } catch {
            status = .error
            errorMessage = "Ollama サーバーの起動に失敗: \(error.localizedDescription)"
            return
        }

        // 4. モデルを確認
        await checkModel()
    }

    /// モデルの存在確認、なければダウンロード
    private func checkModel() async {
        do {
            let models = try await service.listModels()
            if models.contains(where: { $0.hasPrefix(Self.defaultModel) }) {
                status = .ready
            } else {
                try await pullModel(Self.defaultModel)
            }
        } catch {
            // モデル一覧の取得に失敗しても、直接使ってみる
            status = .ready
        }
    }

    // MARK: - インストール

    private func ollamaIsInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ollama")
            || FileManager.default.fileExists(atPath: "/usr/local/bin/ollama")
            || (try? Process.run(URL(fileURLWithPath: "/usr/bin/which"), arguments: ["ollama"]).waitUntilExit()) != nil
    }

    private func ollamaPath() -> String? {
        for path in ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    func installOllama() async throws {
        status = .installing

        // brew install ollama を試みる
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        process.arguments = ["install", "ollama"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw OllamaError.requestFailed
        }
    }

    // MARK: - サーバー管理

    func startServer() throws {
        guard let path = ollamaPath() else {
            throw OllamaError.serverNotRunning
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        serverProcess = process
    }

    func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
    }

    // MARK: - モデル管理

    func pullModel(_ model: String) async throws {
        status = .pullingModel
        pullProgress = 0

        guard let path = ollamaPath() else {
            throw OllamaError.serverNotRunning
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["pull", model]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // バックグラウンドで進捗を読む
        Task.detached { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // 最後の行から進捗を推定
                await MainActor.run {
                    self?.pullProgress = 1.0
                }
            }
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw OllamaError.modelNotFound(model)
        }

        status = .ready
    }
}

enum OllamaStatus: Equatable {
    case unknown
    case notInstalled
    case installing
    case starting
    case pullingModel
    case ready
    case error

    var displayText: String {
        switch self {
        case .unknown: return "確認中…"
        case .notInstalled: return "Ollama をインストール中…"
        case .installing: return "Ollama をインストール中…"
        case .starting: return "Ollama を起動中…"
        case .pullingModel: return "AI モデルをダウンロード中…"
        case .ready: return "準備完了"
        case .error: return "エラー"
        }
    }
}
