import SwiftUI

/// 発言一覧をチャット形式で表示するビュー。
struct TranscriptView: View {
    @ObservedObject var store: TranscriptStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.session.entries) { entry in
                        UtteranceRow(entry: entry, store: store)
                            .id(entry.id)

                        if entry.id != store.session.entries.last?.id {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                    // 録音中のスクロール余白
                    if store.isRecording {
                        Color.clear.frame(height: 20).id(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
                    }
                }
                .padding(.vertical, 8)
            }
            // 新しいエントリが追加されたら最下部にスクロール
            .onChange(of: store.session.entries.count) { _ in
                guard store.isRecording else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    if let lastId = store.session.entries.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }
}
