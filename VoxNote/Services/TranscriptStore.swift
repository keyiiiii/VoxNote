import Foundation
import AVFoundation
import AppKit
import Accelerate
import Combine

/// アプリ全体の状態管理。音声処理パイプラインのオーケストレーションを行う。
@MainActor
class TranscriptStore: ObservableObject {
    @Published var session = TranscriptSession()
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastError: String?
    @Published var isPermissionError = false
    /// 現在の音声入力レベル (0.0〜1.0)
    @Published var audioLevel: Float = 0
    /// 録音ステータスメッセージ
    @Published var statusMessage: String = ""
    /// AI 要約テキスト
    @Published var summary: String = ""
    @Published var isSummarizing = false
    @Published var autoSummarize = true

    let ollamaManager = OllamaManager.shared

    private let audioCapture = AudioCaptureService()
    private let vad = VoiceActivityDetector()
    private let speakerDetector = SpeakerChangeDetector()
    private var whisperService: LocalWhisperService?

    // 録音中に蓄積している現在セグメントのバッファ (ソース情報付き)
    private var currentChunkBuffers: [TaggedAudioBuffer] = []
    // 現在処理中のエントリ ID
    private var pendingEntryId: UUID?
    // オーディオプロファイル UUID → セッション内話者 UUID
    private var speakerMap: [UUID: UUID] = [:]

    private var durationTimer: Timer?

    // 最大チャンクサイズ (15 秒 × 48000 Hz)
    private let maxChunkFrames: AVAudioFrameCount = 720_000
    // 最小チャンクサイズ (2 秒 × 48000 Hz) — これ未満のセグメントは次の発話と結合する
    private let minChunkFrames: AVAudioFrameCount = 96_000

    // Whisper 推論の直列化キュー (whisper.cpp はスレッドセーフでない)
    private var transcriptionQueue: [(buffers: [TaggedAudioBuffer], entryId: UUID)] = []
    private var isTranscribing = false

    private var lastSummaryEntryCount = 0
    private var summaryTask: Task<Void, Never>?

    let modelManager = ModelManager.shared

    // MARK: - 録音制御

    func startRecording() async {
        guard let modelPath = modelManager.currentModelPath else {
            lastError = "Whisper モデルがまだダウンロードされていません。設定からダウンロードしてください。"
            return
        }

        // Whisper モデルを読み込み
        do {
            whisperService = try LocalWhisperService(modelPath: modelPath)
        } catch {
            lastError = error.localizedDescription
            return
        }

        speakerDetector.reset()
        vad.reset()
        speakerMap = [:]
        session = TranscriptSession()
        currentChunkBuffers = []
        pendingEntryId = nil
        lastError = nil
        recordingDuration = 0
        isRecording = true

        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordingDuration += 1 }
        }

        audioCapture.onAudioBuffer = { [weak self] tagged in
            Task { @MainActor in self?.processAudioBuffer(tagged) }
        }

        audioCapture.onAudioLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = min(level * 10, 1.0) }
        }

        statusMessage = "音声キャプチャを開始中…"

        do {
            try await audioCapture.startCapture()
            statusMessage = "録音中 — 音声を待機しています…"
        } catch let error as AudioCaptureError {
            lastError = error.localizedDescription
            isPermissionError = (error == .permissionDenied || error == .permissionRequiresRestart)
            isRecording = false
            durationTimer?.invalidate()
        } catch {
            lastError = error.localizedDescription
            isPermissionError = false
            isRecording = false
            durationTimer?.invalidate()
        }
    }

    func stopRecording() async {
        isRecording = false
        statusMessage = ""
        audioLevel = 0
        durationTimer?.invalidate()
        durationTimer = nil
        audioCapture.onAudioBuffer = nil
        audioCapture.onAudioLevel = nil

        try? await audioCapture.stopCapture()

        // 残バッファを処理
        if !currentChunkBuffers.isEmpty, let id = pendingEntryId {
            let buffers = currentChunkBuffers
            currentChunkBuffers = []
            enqueueTranscription(buffers: buffers, entryId: id)
        }

        // キューが空になるまで待つ
        while isTranscribing || !transcriptionQueue.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        }

        saveSession()
        whisperService = nil // メモリ解放
    }

    // MARK: - 音声処理

    private func processAudioBuffer(_ tagged: TaggedAudioBuffer) {
        // システム音声で無音に近いバッファは無視（VAD を乱さないため）
        if tagged.source == .system {
            guard let data = tagged.buffer.floatChannelData?[0],
                  tagged.buffer.frameLength > 0 else { return }
            var rms: Float = 0
            vDSP_rmsqv(data, 1, &rms, vDSP_Length(tagged.buffer.frameLength))
            if rms < 0.001 { return }
        }

        let event = vad.process(buffer: tagged.buffer)

        switch event {
        case .speechStarted:
            // 短いチャンクがバッファに残っている場合は結合する
            if currentChunkBuffers.isEmpty {
                currentChunkBuffers = [tagged]
            } else {
                currentChunkBuffers.append(tagged)
            }
            statusMessage = "音声を検出 — 文字起こし準備中…"
            // 仮エントリがなければ作成 (話者・テキストは後から設定)
            if pendingEntryId == nil {
                let placeholderId = getOrCreateSpeaker(profileId: UUID()).id
                let entry = TranscriptEntry(speakerId: placeholderId, text: "", isPending: true)
                pendingEntryId = entry.id
                session.entries.append(entry)
            }

        case .speaking:
            currentChunkBuffers.append(tagged)

            // 最大チャンクサイズ超過時に中間送信
            let totalFrames = currentChunkBuffers.reduce(AVAudioFrameCount(0)) { $0 + $1.buffer.frameLength }
            if totalFrames >= maxChunkFrames {
                let toSend = currentChunkBuffers
                currentChunkBuffers = []
                if let id = pendingEntryId {
                    enqueueTranscription(buffers: toSend, entryId: id)
                    // 新しいエントリを継続用に作成
                    let contEntry = TranscriptEntry(
                        speakerId: session.entries.last?.speakerId ?? UUID(),
                        text: "", isPending: true
                    )
                    pendingEntryId = contEntry.id
                    session.entries.append(contEntry)
                }
            }

        case .speechEnded:
            // 最低フレーム数未満なら送信せずバッファに保持して次の発話と結合する
            let totalFrames = currentChunkBuffers.reduce(AVAudioFrameCount(0)) { $0 + $1.buffer.frameLength }
            if totalFrames < minChunkFrames {
                // バッファを保持したまま、次の speechStarted で結合される
                break
            }
            statusMessage = "文字起こし中…"
            let toSend = currentChunkBuffers
            currentChunkBuffers = []
            if !toSend.isEmpty, let id = pendingEntryId {
                let capturedId = id
                pendingEntryId = nil
                enqueueTranscription(buffers: toSend, entryId: capturedId)
                statusMessage = "録音中 — 音声を待機しています…"
            }

        case .silence:
            break
        }
    }

    private func enqueueTranscription(buffers: [TaggedAudioBuffer], entryId: UUID) {
        transcriptionQueue.append((buffers: buffers, entryId: entryId))
        processTranscriptionQueue()
    }

    private func processTranscriptionQueue() {
        guard !isTranscribing, let next = transcriptionQueue.first else { return }
        transcriptionQueue.removeFirst()
        isTranscribing = true
        Task {
            await self.transcribeSegment(buffers: next.buffers, entryId: next.entryId)
            self.isTranscribing = false
            self.autoSummaryCheck()
            self.processTranscriptionQueue()
        }
    }

    private func transcribeSegment(buffers: [TaggedAudioBuffer], entryId: UUID) async {
        // 1. 話者検出 (ソース情報 + 音声特徴量から)
        let rawBuffers = buffers.map { $0.buffer }
        let dominantSource = detectDominantSource(buffers)
        let profileId = speakerDetector.detectSpeaker(from: rawBuffers, source: dominantSource)
        let speaker = getOrCreateSpeaker(profileId: profileId)

        // 2. エントリの話者を更新
        updateEntry(id: entryId, speakerId: speaker.id)

        // 3. ローカル Whisper で文字起こし (バックグラウンドスレッドで実行)
        do {
            guard let whisper = whisperService else { return }
            let text = try await Task.detached(priority: .userInitiated) {
                try whisper.transcribe(buffers: rawBuffers)
            }.value
            updateEntry(id: entryId, text: text.isEmpty ? "[無音]" : text)
        } catch LocalWhisperError.audioTooShort {
            removeEntry(id: entryId)
        } catch {
            updateEntry(id: entryId, text: "[エラー: \(error.localizedDescription)]")
        }
    }

    // MARK: - デバッグ: 音声ファイルを実パイプラインに流す

    /// 音声ファイルを読み込み、Whisper で直接文字起こしする。
    func simulateFromAudioFile(url: URL) async {
        guard let modelPath = modelManager.currentModelPath else {
            lastError = "Whisper モデルがまだダウンロードされていません"
            return
        }

        // セッション初期化 (既存があれば追加)
        if session.speakers.isEmpty {
            session = TranscriptSession()
        }

        statusMessage = "音声ファイルを読み込み中…"

        // 音声ファイルを読み込み
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            lastError = "音声ファイルを開けません: \(error.localizedDescription)"
            return
        }

        let format = audioFile.processingFormat
        let totalFrames = AVAudioFrameCount(audioFile.length)
        let duration = Double(totalFrames) / format.sampleRate

        statusMessage = "音声: \(String(format: "%.1f", duration))秒, \(Int(format.sampleRate))Hz — Whisper 処理中…"

        do {
            let whisper = try LocalWhisperService(modelPath: modelPath)

            // ファイル全体を読み込み
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
                lastError = "バッファ作成失敗"
                return
            }
            try audioFile.read(into: buffer)

            // 話者検出 (音声ファイルは .system 扱いで MFCC 比較)
            let profileId = speakerDetector.detectSpeaker(from: [buffer], source: .system)
            let speaker = getOrCreateSpeaker(profileId: profileId)

            // pending エントリを作成
            let entry = TranscriptEntry(speakerId: speaker.id, text: "", isPending: true)
            session.entries.append(entry)

            // Whisper で文字起こし
            let result = try await Task.detached(priority: .userInitiated) {
                try whisper.transcribe(buffers: [buffer], language: "ja")
            }.value

            if result.isEmpty {
                updateEntry(id: entry.id, text: "[Whisper: 空の結果 — \(String(format: "%.1f", duration))秒]")
            } else {
                updateEntry(id: entry.id, text: result)
            }
            statusMessage = "完了"
        } catch {
            lastError = error.localizedDescription
            statusMessage = "エラー: \(error.localizedDescription)"
        }
    }

    /// macOS の TTS でテキストから音声を生成し、Whisper で直接文字起こしする。
    /// VAD/話者検出をバイパスして Whisper の動作のみを検証する。
    func simulateFromText(_ text: String) async {
        guard !text.isEmpty else { return }

        guard let modelPath = modelManager.currentModelPath else {
            lastError = "Whisper モデルがまだダウンロードされていません"
            return
        }

        statusMessage = "音声を合成中…"

        // TTS で音声ファイルを生成
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxnote-tts-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let synth = NSSpeechSynthesizer()

        // 日本語ボイスを探す
        let japaneseVoice = NSSpeechSynthesizer.availableVoices.first { voice in
            let attrs = NSSpeechSynthesizer.attributes(forVoice: voice)
            let locale = attrs[.localeIdentifier] as? String ?? ""
            return locale.hasPrefix("ja")
        }

        let useJapanese = japaneseVoice != nil
        let whisperLanguage: String?
        let ttsText: String

        if useJapanese {
            synth.setVoice(japaneseVoice)
            whisperLanguage = "ja"
            ttsText = text
        } else {
            // 日本語ボイスがない → 英語で代替テスト
            synth.setVoice(NSSpeechSynthesizer.defaultVoice)
            whisperLanguage = "en"
            // 日本語テキストを英語テスト文に置き換え
            ttsText = "Hello, this is a test of the speech recognition system."
            statusMessage = "日本語 TTS なし → 英語でテスト中…"
        }

        let done = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            class Delegate: NSObject, NSSpeechSynthesizerDelegate {
                var continuation: CheckedContinuation<Bool, Never>?
                func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
                    continuation?.resume(returning: finishedSpeaking)
                    continuation = nil
                }
            }
            let delegate = Delegate()
            delegate.continuation = cont
            synth.delegate = delegate
            synth.startSpeaking(ttsText, to: tempURL)
            objc_setAssociatedObject(synth, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        }

        guard done, FileManager.default.fileExists(atPath: tempURL.path) else {
            lastError = "音声合成に失敗しました"
            return
        }

        // 音声ファイルのサイズを確認
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0
        statusMessage = "TTS 完了 (\(fileSize / 1024) KB) — Whisper 処理中…"

        // セッション未開始なら初期化 (2回目以降は追加)
        if session.speakers.isEmpty {
            session = TranscriptSession()
        }
        let speaker = session.speakers.first ?? {
            let s = Speaker(index: 0)
            session.speakers.append(s)
            return s
        }()

        // pending エントリを作成
        let entry = TranscriptEntry(speakerId: speaker.id, text: "", isPending: true)
        session.entries.append(entry)

        // Whisper モデル読み込み
        do {
            let whisper = try LocalWhisperService(modelPath: modelPath)

            // 音声ファイルを丸ごと読み込んで 1 つの AVAudioPCMBuffer にする
            let audioFile = try AVAudioFile(forReading: tempURL)
            let format = audioFile.processingFormat
            let totalFrames = AVAudioFrameCount(audioFile.length)

            statusMessage = "音声: \(format.sampleRate)Hz, \(format.channelCount)ch, \(totalFrames) frames"

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
                updateEntry(id: entry.id, text: "[バッファ作成失敗]")
                return
            }
            try audioFile.read(into: buffer)

            // Whisper で文字起こし (バックグラウンド)
            statusMessage = "Whisper 処理中… (\(totalFrames) frames @ \(Int(format.sampleRate))Hz)"

            let lang = whisperLanguage
            let result = try await Task.detached(priority: .userInitiated) {
                try whisper.transcribe(buffers: [buffer], language: lang)
            }.value

            if result.isEmpty {
                let voiceName = useJapanese ? "Japanese" : "English (fallback)"
                updateEntry(id: entry.id, text: "[Whisper: 空 — voice: \(voiceName), \(Int(format.sampleRate))Hz, \(totalFrames)frames, 入力: \(text)]")
                statusMessage = "Whisper が空を返しました"
            } else {
                let prefix = useJapanese ? "" : "[EN テスト] "
                updateEntry(id: entry.id, text: prefix + result)
                statusMessage = "完了 — \(useJapanese ? "日本語" : "英語フォールバック")"
            }
        } catch {
            updateEntry(id: entry.id, text: "[エラー: \(error.localizedDescription)]")
            statusMessage = "エラー: \(error.localizedDescription)"
        }
    }

    // MARK: - AI 要約

    /// 手動で要約を更新
    func updateSummary() async {
        guard !isSummarizing else { return }
        let completedEntries = session.entries.filter { !$0.isPending && !$0.text.isEmpty }
        guard !completedEntries.isEmpty else { return }

        // Ollama が使えるか確認
        if !(await ollamaManager.service.isAvailable()) {
            await ollamaManager.ensureReady()
            guard ollamaManager.status == .ready else { return }
        }

        isSummarizing = true
        summary = ""
        lastSummaryEntryCount = completedEntries.count

        let transcript = MarkdownExporter.buildPlainText(session: session)

        do {
            _ = try await ollamaManager.service.summarize(transcript: transcript) { [weak self] token in
                Task { @MainActor in
                    self?.summary += token
                }
            }
        } catch {
            if summary.isEmpty {
                summary = "[要約エラー: \(error.localizedDescription)]"
            }
        }

        isSummarizing = false
    }

    /// 自動要約チェック（新しい発言が5件追加されたら実行）
    private func autoSummaryCheck() {
        guard autoSummarize, ollamaManager.status == .ready else { return }
        let completedCount = session.entries.filter { !$0.isPending && !$0.text.isEmpty }.count
        guard completedCount - lastSummaryEntryCount >= 5 else { return }

        summaryTask?.cancel()
        summaryTask = Task {
            await updateSummary()
        }
    }

    // MARK: - セッション操作

    func updateEntryText(id: UUID, text: String) {
        updateEntry(id: id, text: text)
    }

    func renameSpeaker(id: UUID, name: String) {
        guard let idx = session.speakers.firstIndex(where: { $0.id == id }) else { return }
        session.speakers[idx].customName = name.isEmpty ? nil : name
    }

    func speaker(for entry: TranscriptEntry) -> Speaker? {
        session.speakers.first { $0.id == entry.speakerId }
    }

    /// セグメント内で支配的な音声ソースを判定。
    /// マイクに音声があれば（RMS > 閾値）無条件でマイク扱い。
    /// 自分の声はマイク経由が確実なので、マイク優先で判定する。
    private func detectDominantSource(_ buffers: [TaggedAudioBuffer]) -> AudioSource {
        let micThreshold: Float = 0.001

        // マイクバッファの最大 RMS を計算
        var maxMicRMS: Float = 0
        for tagged in buffers where tagged.source == .microphone {
            guard let data = tagged.buffer.floatChannelData?[0],
                  tagged.buffer.frameLength > 0 else { continue }
            var rms: Float = 0
            vDSP_rmsqv(data, 1, &rms, vDSP_Length(tagged.buffer.frameLength))
            maxMicRMS = max(maxMicRMS, rms)
        }

        // マイクに音声があればマイク、なければシステム
        return maxMicRMS > micThreshold ? .microphone : .system
    }

    // MARK: - プライベートヘルパー

    private func getOrCreateSpeaker(profileId: UUID) -> Speaker {
        if let speakerId = speakerMap[profileId],
           let existing = session.speakers.first(where: { $0.id == speakerId }) {
            return existing
        }
        let speaker = Speaker(index: session.speakers.count)
        speakerMap[profileId] = speaker.id
        session.speakers.append(speaker)
        return speaker
    }

    private func updateEntry(id: UUID, text: String) {
        guard let idx = session.entries.firstIndex(where: { $0.id == id }) else { return }
        session.entries[idx].text = text
        session.entries[idx].isPending = false
    }

    private func updateEntry(id: UUID, speakerId: UUID) {
        guard let idx = session.entries.firstIndex(where: { $0.id == id }) else { return }
        session.entries[idx].speakerId = speakerId
    }

    private func removeEntry(id: UUID) {
        session.entries.removeAll { $0.id == id }
    }

    // MARK: - 永続化

    private func saveSession() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxNote/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let name = formatter.string(from: session.startDate) + ".json"

        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: dir.appendingPathComponent(name))
        }
    }
}
