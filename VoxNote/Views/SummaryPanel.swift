import SwiftUI

/// 右サイドパネル: AI による議事録要約を表示
struct SummaryPanel: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var ollamaManager: OllamaManager
    @State private var availableModels: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ヘッダー
            HStack {
                Label("議事録要約", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()

                if store.isSummarizing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }

                Button {
                    Task { await store.updateSummary() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isSummarizing || store.session.entries.isEmpty)
                .help("要約を更新")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // 本体
            ScrollView {
                Group {
                    switch ollamaManager.status {
                    case .ready:
                        if store.summary.isEmpty && !store.isSummarizing {
                            emptyState
                        } else {
                            summaryContent
                        }
                    case .error:
                        errorState
                    default:
                        setupProgress
                    }
                }
                .padding(12)
            }

            Divider()

            // フッター: モデル選択 + 自動更新トグル
            VStack(spacing: 6) {
                // モデル選択
                HStack(spacing: 6) {
                    Text("モデル:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { ollamaManager.service.model },
                        set: { ollamaManager.service.model = $0 }
                    )) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(maxWidth: 180)
                }

                HStack {
                    Toggle("自動更新", isOn: $store.autoSummarize)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                    Text(ollamaManager.status.displayText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 280, idealWidth: 380)
        .task {
            await loadModels()
        }
    }

    // MARK: - モデル一覧の読み込み

    private func loadModels() async {
        if let models = try? await ollamaManager.service.listModels() {
            availableModels = models
            // 現在のモデルがリストにない場合は最初のモデルを選択
            if !models.contains(ollamaManager.service.model), let first = models.first {
                ollamaManager.service.model = first
            }
        }
    }

    // MARK: - 状態別ビュー

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("録音を開始すると、AIが自動で\n議事録を生成します")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !store.session.entries.isEmpty {
                Button("今すぐ要約を生成") {
                    Task { await store.updateSummary() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Markdown をパース & 整形して表示
            ForEach(Array(summaryLines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    // 見出し
                    Text(line.replacingOccurrences(of: "## ", with: ""))
                        .font(.headline)
                        .padding(.top, 8)
                } else if line.hasPrefix("- ") {
                    // 箇条書き
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(line.replacingOccurrences(of: "- ", with: ""))
                            .textSelection(.enabled)
                    }
                } else if line.hasPrefix("---") {
                    Divider()
                } else if !line.isEmpty {
                    Text(line)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if store.isSummarizing {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("要約を生成中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    /// 要約テキストを行ごとに分割
    private var summaryLines: [String] {
        store.summary
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private var setupProgress: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(ollamaManager.status.displayText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if ollamaManager.status == .pullingModel {
                ProgressView(value: ollamaManager.pullProgress)
                    .frame(width: 200)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(ollamaManager.errorMessage ?? "Ollama に接続できません")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("再試行") {
                Task { await ollamaManager.ensureReady() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}
