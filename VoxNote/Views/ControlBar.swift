import SwiftUI

/// 上部のコントロールバー: タイトル・録音タイマー・音声レベル・録音ボタン・設定ボタン
struct ControlBar: View {
    @ObservedObject var store: TranscriptStore
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // タイトル
                Text("VoxNote")
                    .font(.headline)

                Spacer()

                // 録音中: タイマー + 音声レベルメーター
                if store.isRecording {
                    HStack(spacing: 8) {
                        // 音声レベルバー
                        AudioLevelView(level: store.audioLevel)
                            .frame(width: 60, height: 16)

                        // 録音インジケーター
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .opacity(timerOpacity)
                            .animation(
                                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                value: store.isRecording
                            )
                        Text(formattedDuration)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }

                // 録音開始 / 停止ボタン
                Button {
                    Task {
                        if store.isRecording {
                            await store.stopRecording()
                        } else {
                            await store.startRecording()
                        }
                    }
                } label: {
                    Label(
                        store.isRecording ? "停止" : "録音開始",
                        systemImage: store.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .foregroundStyle(store.isRecording ? .red : .primary)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!store.modelManager.isModelReady && !store.isRecording)

                // 設定ボタン
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .help("設定")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // ステータスメッセージ
            if store.isRecording && !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
    }

    private var timerOpacity: Double { store.isRecording ? 1.0 : 0.0 }

    private var formattedDuration: String {
        let secs = Int(store.recordingDuration)
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }
}

// MARK: - 音声レベルインジケーター

/// 音声入力レベルをバー表示するビュー。
/// レベルが 0 のままなら音声キャプチャに問題があることが分かる。
struct AudioLevelView: View {
    let level: Float
    private let barCount = 8

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                let threshold = Float(i) / Float(barCount)
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(index: i))
                    .opacity(level > threshold ? 1.0 : 0.15)
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }

    private func barColor(index: Int) -> Color {
        let ratio = Float(index) / Float(barCount)
        if ratio > 0.75 { return .red }
        if ratio > 0.5 { return .yellow }
        return .green
    }
}
