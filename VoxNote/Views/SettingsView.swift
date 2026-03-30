import SwiftUI

struct SettingsView: View {
    @ObservedObject var modelManager: ModelManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("設定")
                .font(.title2.bold())

            Divider()

            // Whisper モデル選択
            VStack(alignment: .leading, spacing: 12) {
                Label("Whisper モデル", systemImage: "cpu")
                    .font(.headline)

                Text("文字起こしに使用する AI モデルを選択してください。モデルが大きいほど精度が上がりますが、処理に時間がかかります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(WhisperModel.allCases) { model in
                    ModelRow(
                        model: model,
                        isSelected: modelManager.selectedModel == model,
                        isDownloaded: modelManager.modelFileExists(for: model),
                        isDownloading: modelManager.downloadingModel == model,
                        progress: modelManager.downloadProgress,
                        onSelect: { modelManager.selectModel(model) },
                        onDownload: { Task { await modelManager.downloadModel(model) } },
                        onCancel: { modelManager.cancelDownload() }
                    )
                }
            }

            Divider()

            // 画面収録の権限
            VStack(alignment: .leading, spacing: 8) {
                Label("画面収録の権限", systemImage: "rectangle.on.rectangle")
                    .font(.headline)

                Text("Slack / Zoom の相手の声を録音するには、システム設定 > プライバシーとセキュリティ > 画面収録 で VoxNote を許可してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("システム設定を開く") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                    )
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if let error = modelManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
    }
}

// MARK: - モデル行

private struct ModelRow: View {
    let model: WhisperModel
    let isSelected: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let progress: Double
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.subheadline)
            }

            Spacer()

            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                    Button("中止") { onCancel() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else if isDownloaded {
                Label("ダウンロード済み", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("ダウンロード") { onDownload() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if isDownloaded { onSelect() }
        }
    }
}
