import SwiftUI

/// 話者ラベルを表示するチップ。クリックでリネームポップオーバーを表示。
struct SpeakerChip: View {
    let speaker: Speaker
    @ObservedObject var store: TranscriptStore
    @State private var showRename = false
    @State private var nameInput = ""

    var accent: Color { Color(hex: speaker.colorHex) ?? .blue }

    var body: some View {
        Button {
            nameInput = speaker.customName ?? ""
            showRename = true
        } label: {
            Text(speaker.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(accent.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showRename, arrowEdge: .bottom) {
            RenamePopover(
                speakerName: speaker.displayName,
                nameInput: $nameInput
            ) {
                store.renameSpeaker(id: speaker.id, name: nameInput)
                showRename = false
            } onCancel: {
                showRename = false
            }
        }
    }
}

private struct RenamePopover: View {
    let speakerName: String
    @Binding var nameInput: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(speakerName) を編集")
                .font(.headline)

            TextField("名前 (例: 田中)", text: $nameInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { onSave() }

            HStack {
                Button("キャンセル", action: onCancel)
                    .buttonStyle(.borderless)
                Spacer()
                Button("保存", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(16)
    }
}
