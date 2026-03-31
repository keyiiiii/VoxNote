import Foundation

/// Ollama HTTP API クライアント。要約リクエストとストリーミングレスポンスを処理する。
class OllamaService {
    let baseURL: URL
    var model: String

    init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String = "qwen3:8b") {
        self.baseURL = baseURL
        self.model = model
    }

    // MARK: - 要約

    /// 文字起こしテキストを要約する。ストリーミングでコールバックに逐次テキストを返す。
    func summarize(
        transcript: String,
        onToken: @escaping (String) -> Void
    ) async throws -> String {
        let prompt = """
        以下はミーティングの文字起こしです。これを構造化された議事録にまとめてください。
        日本語で出力してください。

        出力フォーマット:
        ## 概要
        （会議の概要を1-2文で）

        ## 主な議題と議論内容
        - （箇条書きで）

        ## 決定事項
        - （あれば箇条書きで、なければ「特になし」）

        ## TODO / 次のアクション
        - （あれば箇条書きで、なければ「特になし」）

        ---
        文字起こし:
        \(transcript)
        """

        return try await generate(prompt: prompt, onToken: onToken)
    }

    // MARK: - Ollama API

    /// /api/generate にストリーミングリクエストを送信
    private func generate(
        prompt: String,
        onToken: @escaping (String) -> Void
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300 // 5分（長い要約に対応）

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.requestFailed
        }

        var fullResponse = ""
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["response"] as? String else { continue }

            fullResponse += token
            onToken(token)

            // done フラグで終了
            if let done = json["done"] as? Bool, done { break }
        }

        return fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 接続確認

    /// Ollama サーバーが起動しているか確認
    func isAvailable() async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// インストール済みモデル一覧を取得
    func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }

        return models.compactMap { $0["name"] as? String }
    }
}

enum OllamaError: LocalizedError {
    case requestFailed
    case serverNotRunning
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed: return "Ollama へのリクエストに失敗しました"
        case .serverNotRunning: return "Ollama サーバーが起動していません"
        case .modelNotFound(let m): return "モデル '\(m)' が見つかりません"
        }
    }
}
