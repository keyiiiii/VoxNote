import SwiftUI

/// 下部バー: エクスポートボタン・コピーボタン・発言数表示
struct BottomBar: View {
    @ObservedObject var store: TranscriptStore
    @State private var copied = false

    private var hasContent: Bool {
        store.session.entries.contains { !$0.isPending && !$0.text.isEmpty }
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                MarkdownExporter.export(session: store.session)
            } label: {
                Label("Markdown 保存", systemImage: "doc.text")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .disabled(!hasContent)
            .help("文字起こし結果を Markdown ファイルとして保存")

            Divider().frame(height: 14)

            Button {
                MarkdownExporter.copyToClipboard(session: store.session)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "コピーしました" : "全コピー",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline)
                    .animation(.easeInOut, value: copied)
            }
            .buttonStyle(.borderless)
            .disabled(!hasContent)
            .help("全発言をクリップボードにコピー")

            Spacer()

            let count = store.session.entries.filter { !$0.isPending }.count
            if count > 0 {
                Text("\(count) 発言")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
