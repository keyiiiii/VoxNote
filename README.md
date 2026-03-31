# VoxNote

Slack Huddle / Zoom などのオンライン MTG を、リアルタイムで文字起こし & AI 議事録要約する macOS アプリ。

自分だけでなく**相手の発言もすべて文字起こし**し、**Ollama によるローカル LLM で議事録を自動生成**します。API キー不要、完全ローカル処理でプライバシーも安心。

![macOS 13+](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## どんなアプリ？

MTG 中にこんな画面が表示されます:

```
┌──────────────────────────┬─────────────────────┐
│ VoxNote  ▅▃▅▇▅ ● 02:34  │  議事録要約          │
├──────────────────────────┤─────────────────────│
│  話者A  14:03            │  概要               │
│  今日のミーティングを     │  QC効率化について    │
│  始めましょう。           │  議論が行われた。    │
│                          │                     │
│  話者B  14:03            │  主な議題            │
│  はい、まず先週のタスク   │  • 項目書の網羅性    │
│  の進捗について...        │  • テスト自動化      │
│                          │                     │
│  話者A  14:04            │  TODO               │
│  先週は新機能の...        │  • サーバーQC整備    │
├──────────────────────────┴─────────────────────┤
│  [Markdown 保存]  [全コピー]           3 発言   │
└────────────────────────────────────────────────┘
```

- 左: リアルタイム文字起こし（話者自動分離 + WYSIWYG 編集）
- 右: AI が自動生成する構造化議事録（概要・議題・TODO）
- 録音終了後に Markdown で書き出し

---

## 主な機能

### リアルタイム文字起こし
macOS のシステム音声 + マイク入力を同時にキャプチャ。自分と相手の両方の発言を文字起こしします。Zoom / Slack Huddle / Google Meet など、どの通話アプリでも動きます。

### AI 議事録要約
[Ollama](https://ollama.com) によるローカル LLM で、文字起こし結果をリアルタイムに構造化議事録（概要・議題・決定事項・TODO）にまとめます。発言が 5 件追加されるごとに自動更新。手動更新も可能。

### 話者の自動分離
マイク入力（自分）とシステム音声（相手）を分離し、相手同士は MFCC 音声特徴量で自動識別。話者名はクリックして変更できます。

### WYSIWYG 編集
文字起こし結果はクリックするだけで直接編集できます。フォーカスが外れると自動保存。

### Markdown エクスポート
AI 要約 + 文字起こしを Markdown ファイルに書き出し、またはクリップボードにワンクリックでコピー。

### 完全ローカル処理
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) + [Ollama](https://ollama.com) によるオンデバイス推論。音声データも議事録も一切外部に送信されません。

---

## インストール

### Homebrew（推奨）

```bash
brew tap keyiiiii/tap
brew install --cask voxnote
```

アップデートも `brew upgrade voxnote` で完了。画面収録の権限が保たれます。

### ダウンロード

[Releases](../../releases) から最新の ZIP をダウンロード。

ZIP を展開し、`VoxNote.app` を `/Applications` に移動して起動。

初回起動時に Gatekeeper の警告が出る場合は **システム設定 > プライバシーとセキュリティ > 「このまま開く」** で許可する。

### ソースからビルド

```bash
brew install xcodegen
git clone https://github.com/keyiiiii/VoxNote.git
cd VoxNote
xcodegen generate
xcodebuild -scheme VoxNote -configuration Release build
```

---

## 使い方

### 1. 初回セットアップ

VoxNote は以下の macOS 権限が必要。初回起動時にダイアログが表示されます。

| 権限 | 必須 | 用途 |
|------|------|------|
| **画面収録** | 必須 | Zoom / Slack などのシステム音声をキャプチャ |
| **マイク** | 必須 | 自分の声をキャプチャ |

設定場所: **システム設定 > プライバシーとセキュリティ**

> 画面収録の権限を付与した後、VoxNote を一度終了して再起動してください。

起動時に Whisper モデルと Ollama が自動でセットアップされます。

### 2. MTG を文字起こし

1. Zoom / Slack Huddle などで通話を開始
2. VoxNote で `⌘R` または「録音開始」ボタン
3. 左パネルに発言がリアルタイムで表示
4. 右パネルに AI が議事録要約を自動生成
5. 「停止」で録音終了 → セッションは自動保存

### 3. テキストを編集・エクスポート

- テキスト部分をクリックしてそのまま編集
- 話者名をクリックして名前を変更（話者A → 田中）
- 「Markdown 保存」で要約 + 文字起こしをファイル書き出し
- 「全コピー」でクリップボードにコピー

---

## Whisper モデル

設定画面（⚙）からモデルサイズを変更できます。初回ダウンロード後はオフラインで動作します。

| モデル | サイズ | 用途 |
|--------|--------|------|
| Tiny | ~75 MB | 速度重視・軽量マシン向け |
| Base | ~142 MB | 軽量バランス |
| **Small** | **~466 MB** | **推奨** |
| Medium | ~1.5 GB | 高精度 |
| Large v3 Turbo | ~1.6 GB | 最高精度 |

## AI 要約 (Ollama)

議事録要約には [Ollama](https://ollama.com) が必要です。VoxNote が自動でインストール・起動・モデルダウンロードを行います。

要約パネル下部のドロップダウンから Ollama モデルを切り替えられます。

---

## デバッグモード

`⌘D` でデバッグバーを表示。音声がなくても動作確認できます。

- **TTS → Whisper**: テキストを音声合成 → Whisper で文字起こし
- **音声ファイル**: WAV / MP3 / M4A を読み込んで話者検出 + Whisper 文字起こし

---

## 動作環境

- macOS 13.0 (Ventura) 以降
- Apple Silicon 推奨（Metal GPU アクセラレーション）
- Intel Mac でも動作
- メモリ: 8GB 以上（Large モデル + Ollama 使用時は 16GB 以上推奨）

---

## 開発者向け

### プロジェクト構成

```
VoxNote/
├── Models/          データモデル (Session, Entry, Speaker, AudioSource)
├── Services/        音声キャプチャ, VAD, MFCC話者検出, Whisper, Ollama, 状態管理
├── Views/           SwiftUI ビュー (2カラム: 文字起こし + 要約パネル)
├── Export/          Markdown エクスポート (要約付き)
└── Vendor/          whisper.cpp v1.7.1
```

### CI/CD

GitHub Actions で自動ビルド・リリース + Homebrew Tap 自動更新:

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
```

---

## ライセンス

MIT License

whisper.cpp は [MIT License](https://github.com/ggerganov/whisper.cpp/blob/master/LICENSE) で提供されています。
