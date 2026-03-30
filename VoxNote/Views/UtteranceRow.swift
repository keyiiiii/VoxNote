import SwiftUI

/// 1 発言分の表示行。テキスト部分は常時編集可能な WYSIWYG スタイル。
struct UtteranceRow: View {
    let entry: TranscriptEntry
    @ObservedObject var store: TranscriptStore

    @State private var editBuffer: String = ""
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
                // 常時編集可能なテキストエディタ
                InlineTextEditor(
                    text: $editBuffer,
                    isFocused: $isFocused,
                    onCommit: {
                        store.updateEntryText(id: entry.id, text: editBuffer)
                    }
                )
                .onAppear {
                    if !isInitialized {
                        editBuffer = entry.text
                        isInitialized = true
                    }
                }
                .onChange(of: entry.text) { newValue in
                    // Whisper から更新された場合のみ同期
                    if !isFocused {
                        editBuffer = newValue
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - インラインテキストエディタ

/// 普段はプレーンテキストに見えるが、クリックするとそのまま編集できるエディタ。
struct InlineTextEditor: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onCommit: () -> Void

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .font(.body)
            .focused(isFocused)
            .textFieldStyle(.plain)
            .lineLimit(nil)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isFocused.wrappedValue
                          ? Color(NSColor.textBackgroundColor).opacity(0.5)
                          : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isFocused.wrappedValue
                            ? Color.accentColor.opacity(0.3)
                            : Color.clear,
                            lineWidth: 1)
            )
            .onChange(of: isFocused.wrappedValue) { focused in
                if !focused {
                    onCommit()
                }
            }
    }
}
