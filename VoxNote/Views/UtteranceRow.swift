import SwiftUI

/// 1 発言分の表示行。常時編集可能な WYSIWYG エディタ。
struct UtteranceRow: View {
    let entry: TranscriptEntry
    @ObservedObject var store: TranscriptStore

    @State private var editBuffer: String = ""
    @State private var textHeight: CGFloat = 40
    @State private var isInitialized = false
    @FocusState private var isFocused: Bool

    var speaker: Speaker? { store.speaker(for: entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ヘッダー: 話者チップ + 時刻
            HStack(spacing: 8) {
                if let sp = speaker {
                    SpeakerChip(speaker: sp, store: store)
                } else {
                    Text("話者?")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()
            }

            // テキスト本体
            if entry.isPending {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                    Text("文字起こし中…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else {
                ZStack(alignment: .topLeading) {
                    // 非表示の Text で正確な高さを計測
                    Text(editBuffer.isEmpty ? " " : editBuffer)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .opacity(0)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { textHeight = geo.size.height }
                                    .onChange(of: editBuffer) { _ in
                                        textHeight = geo.size.height
                                    }
                            }
                        )

                    // 常時編集可能な TextEditor
                    TextEditor(text: $editBuffer)
                        .font(.body)
                        .focused($isFocused)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .frame(height: max(textHeight, 30))
                        .padding(.horizontal, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isFocused
                                      ? Color(NSColor.textBackgroundColor).opacity(0.3)
                                      : Color.clear)
                        )
                }
                .onAppear {
                    if !isInitialized {
                        editBuffer = entry.text
                        isInitialized = true
                    }
                }
                .onChange(of: entry.text) { newValue in
                    if !isFocused { editBuffer = newValue }
                }
                .onChange(of: isFocused) { focused in
                    if !focused {
                        store.updateEntryText(id: entry.id, text: editBuffer)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
