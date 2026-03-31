import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = TranscriptStore()
    @State private var showSettings = false
    @State private var debugInput = ""
    @State private var showDebugInput = false

    @State private var showSummary = true

    var body: some View {
        VStack(spacing: 0) {
            // 上部コントロール
            ControlBar(store: store, showSettings: $showSettings)

            Divider()

            // メインエリア: 左 文字起こし | 右 要約
            HSplitView {
                // 左: 文字起こし
                Group {
                    if store.session.entries.isEmpty && !showDebugInput {
                        EmptyStateView(
                            modelManager: store.modelManager,
                            showSettings: $showSettings
                        )
                    } else {
                        TranscriptView(store: store)
                    }
                }
                .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)

                // 右: AI 要約パネル
                if showSummary {
                    SummaryPanel(store: store, ollamaManager: store.ollamaManager)
                        .frame(minWidth: 250, maxHeight: .infinity)
                }
            }

            Divider()

            // デバッグ入力バー (⌘D で表示切替)
            if showDebugInput {
                DebugInputBar(text: $debugInput, store: store)
            }

            // 下部バー
            BottomBar(store: store)
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $showSettings) {
            SettingsView(modelManager: store.modelManager)
        }
        .alert(
            store.isPermissionError ? "画面収録の設定" : "エラー",
            isPresented: .constant(store.lastError != nil),
            actions: {
                if store.isPermissionError {
                    Button("システム設定を開く") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                        )
                        store.lastError = nil
                    }
                    Button("閉じる", role: .cancel) { store.lastError = nil }
                } else {
                    Button("OK") { store.lastError = nil }
                }
            },
            message: {
                if store.isPermissionError {
                    Text("Zoom / Slack の音声を録音するには画面収録の許可が必要です。\n\nシステム設定で許可した後、VoxNote を再起動してください。")
                } else {
                    Text(store.lastError ?? "")
                }
            }
        )
        .keyboardShortcut("d", modifiers: .command)
        .onAppear {
            // ⌘D のグローバルショートカット
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) && event.characters == "d" {
                    showDebugInput.toggle()
                    return nil
                }
                return event
            }
        }
        .task {
            // 起動時に Whisper モデルを自動ダウンロード
            await store.modelManager.downloadModelIfNeeded()
            // Ollama のセットアップ (バックグラウンド)
            await store.ollamaManager.ensureReady()
        }
    }
}

// MARK: - デバッグ入力バー

struct DebugInputBar: View {
    @Binding var text: String
    @ObservedObject var store: TranscriptStore
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "ant")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Debug — 実パイプラインテスト")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("⌘D で非表示")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    // テキスト → TTS → Whisper パイプライン
                    TextField("テキストを入力 → TTS → VAD → Whisper", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .onSubmit { submitTTS() }
                        .disabled(isProcessing)

                    Button("TTS→Whisper") { submitTTS() }
                        .buttonStyle(.bordered)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing)
                        .help("テキストを音声合成 → 実際の Whisper パイプラインで文字起こし")

                    Divider().frame(height: 20)

                    // 音声ファイル読み込み
                    Button("音声ファイル") { selectAudioFile() }
                        .buttonStyle(.bordered)
                        .disabled(isProcessing)
                        .help("WAV/MP3/M4A を読み込んで実パイプラインに通す")
                }

                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(height: 14)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.05))
        }
    }

    private func submitTTS() {
        let input = text
        text = ""
        isProcessing = true
        Task {
            await store.simulateFromText(input)
            isProcessing = false
        }
    }

    private func selectAudioFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]
        panel.message = "パイプラインに流す音声ファイルを選択"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isProcessing = true
        Task {
            await store.simulateFromAudioFile(url: url)
            isProcessing = false
        }
    }
}

// MARK: - 空状態ビュー

struct EmptyStateView: View {
    @ObservedObject var modelManager: ModelManager
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            if modelManager.isDownloading {
                // モデルダウンロード中
                VStack(spacing: 12) {
                    Text("Whisper モデルをダウンロード中…")
                        .font(.title3)
                    ProgressView(value: modelManager.downloadProgress)
                        .frame(width: 240)
                    Text("\(Int(modelManager.downloadProgress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if modelManager.isModelReady {
                // 準備完了
                VStack(spacing: 6) {
                    Text("Command + R で録音を開始")
                        .font(.title3)
                    Text("Slack Huddle や Zoom に入室した状態で録音を開始してください")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                // モデル未ダウンロード
                VStack(spacing: 12) {
                    Text("Whisper モデルのダウンロードが必要です")
                        .font(.title3)
                    Text("文字起こしに使う AI モデルをダウンロードしてください（約 142 MB）")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        Button("ダウンロード") {
                            Task { await modelManager.downloadModelIfNeeded() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("設定を開く") { showSettings = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
