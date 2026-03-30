# VoxNote

Slack Huddle / Zoom などのオンライン MTG を、リアルタイムで文字起こしする macOS アプリ。

自分だけでなく**相手の発言もすべて文字起こし**します。API キー不要、完全ローカル処理でプライバシーも安心。

![macOS 13+](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## どんなアプリ？

MTG 中にこんな画面が表示されます:

```
┌─────────────────────────────────────────┐
│  VoxNote   ▅▃▅▇▅  ● 02:34   [■ 停止]   │
├─────────────────────────────────────────┤
│  話者A  14:03                           │
│  こんにちは、今日のミーティングを         │
│  始めましょう。                          │
│                                         │
│  話者B  14:03                           │
│  はい、まず先週のタスクの進捗について     │
│  報告をお願いします。                    │
│                                         │
│  話者A  14:04                           │
│  先週は新機能のプロトタイプを...          │
├─────────────────────────────────────────┤
│  [Markdown 保存]  [全コピー]    3 発言    │
└─────────────────────────────────────────┘
```

- 話者が変わるたびに自動で分離
- テキストはその場でクリックして編集可能
- 録音終了後に Markdown で書き出し

---

## 主な機能

### リアルタイム文字起こし
macOS のシステム音声をキャプチャして、発話が終わるたびに文字起こし結果が表示されます。Zoom / Slack Huddle / Google Meet など、どの通話アプリでも動きます。

### 話者の自動分離
音声の特徴から話者 A / B / C を自動で識別。話者名はクリックして「田中」「鈴木」などに変更できます。

### WYSIWYG 編集
文字起こし結果はクリックするだけで直接編集できます。「meating → meeting」のような誤変換をその場でサッと修正。フォーカスが外れると自動保存。

### Markdown エクスポート
議事録として Markdown ファイルに書き出し、またはクリップボードにワンクリックでコピー。

### 完全ローカル処理
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) によるオンデバイス推論。音声データは一切外部に送信されません。API キーも不要です。

### 音声レベルモニター
録音中は音声レベルバーが表示され、音声が正しくキャプチャされているか一目で確認できます。

---

## インストール

### ダウンロード

[Releases](../../releases) から最新の ZIP をダウンロード。

ZIP を展開し、**`install.command` をダブルクリック**すると `/Applications` に自動インストールされます。

> Gatekeeper の警告が出た場合は、**システム設定 > プライバシーとセキュリティ** の下部にある「このまま開く」をクリックしてください。

### ソースからビルド

```bash
brew install xcodegen
git clone https://github.com/keyiiiii/VoxNote.git
cd VoxNote
xcodegen generate
xcodebuild -scheme VoxNote -configuration Release build
```

リリース用 ZIP:

```bash
./scripts/build-release.sh
```

---

## 使い方

### 1. 初回セットアップ

1. VoxNote を起動
2. Whisper モデルが自動ダウンロードされます（約 142 MB）
3. **システム設定 > プライバシーとセキュリティ > 画面収録** で VoxNote を許可
4. VoxNote を一度終了して再起動（権限反映のため）

### 2. MTG を文字起こし

1. Zoom / Slack Huddle などで通話を開始
2. VoxNote で `⌘R` または「録音開始」ボタン
3. 発言がリアルタイムで表示されます
4. 「停止」で録音終了 → セッションは自動保存

### 3. テキストを編集・エクスポート

- テキスト部分をクリックしてそのまま編集
- 話者名をクリックして名前を変更（話者A → 田中）
- 「Markdown 保存」でファイル書き出し
- 「全コピー」でクリップボードにコピー

---

## Whisper モデル

初回起動時に自動ダウンロードされます。設定画面（⚙）からモデルサイズを変更できます。

| モデル | サイズ | 用途 |
|--------|--------|------|
| Tiny | ~75 MB | 速度重視・軽量マシン向け |
| **Base** | **~142 MB** | **推奨バランス** |
| Small | ~466 MB | 精度重視 |

ダウンロード後は完全オフラインで動作します。

---

## デバッグモード

`⌘D` でデバッグバーを表示。音声がなくても動作確認できます。

- **TTS → Whisper**: テキストを音声合成 → Whisper で文字起こし（パイプライン全体のテスト）
- **音声ファイル**: WAV / MP3 / M4A を読み込んで Whisper で文字起こし

---

## 動作環境

- macOS 13.0 (Ventura) 以降
- Apple Silicon 推奨（Metal GPU アクセラレーション）
- Intel Mac でも動作

---

## 開発者向け

### ローカル開発で画面収録の権限がリセットされる場合

ビルドごとに署名が変わると macOS が別アプリと認識します。自己署名証明書をセットアップしてください:

```bash
./scripts/setup-signing.sh
```

### プロジェクト構成

```
VoxNote/
├── Models/          データモデル
├── Services/        音声キャプチャ, VAD, 話者検出, Whisper, 状態管理
├── Views/           SwiftUI ビュー (WYSIWYG エディタ含む)
├── Export/          Markdown エクスポート
└── Vendor/          whisper.cpp v1.7.1
```

### CI/CD

GitHub Actions で自動ビルド・リリース:

```bash
git tag v1.0.0 && git push origin v1.0.0
# → Release ページに .app の ZIP が自動公開
```

---

## ライセンス

MIT License

whisper.cpp は [MIT License](https://github.com/ggerganov/whisper.cpp/blob/master/LICENSE) で提供されています。
