#!/bin/bash
set -euo pipefail

# ── VoxNote 用自己署名証明書のセットアップ ──
# ローカル開発専用スクリプト。配布には使用しません。
# macOS の画面収録権限はコード署名 ID で管理されるため、
# ビルドごとに権限がリセットされないよう安定した署名 ID を用意する。
# パスワードはローカル証明書生成用の一時値であり、機密情報ではありません。

CERT_NAME="VoxNote Developer"
KEYCHAIN=~/Library/Keychains/login.keychain-db

echo "🔑 VoxNote コード署名セットアップ"
echo ""

# 既存の証明書チェック
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ 証明書「$CERT_NAME」は既に存在します"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

echo "📝 自己署名コード署名証明書を作成します..."

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# 証明書 + 秘密鍵を生成
openssl req -x509 -newkey rsa:2048 \
    -keyout "$TMPDIR/key.pem" -out "$TMPDIR/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=$CERT_NAME" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    2>/dev/null

# PKCS12 にパッケージ化 (-descert で DES3 暗号化、macOS Keychain 互換)
openssl pkcs12 -export \
    -out "$TMPDIR/voxnote.p12" \
    -inkey "$TMPDIR/key.pem" \
    -in "$TMPDIR/cert.pem" \
    -passout pass:_voxnote_setup_ \
    -descert \
    2>/dev/null

# 既存のがあればクリーンアップ
security delete-identity -c "$CERT_NAME" 2>/dev/null || true

# キーチェーンにインポート
security import "$TMPDIR/voxnote.p12" \
    -k "$KEYCHAIN" \
    -T /usr/bin/codesign \
    -P "_voxnote_setup_"

# 証明書をコード署名用に信頼
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMPDIR/cert.pem"

echo ""
echo "✅ 証明書「$CERT_NAME」を作成しました"
security find-identity -v -p codesigning | grep "$CERT_NAME" || true
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "次のステップ:"
echo "  1. xcodegen generate"
echo "  2. Xcode でビルド (⌘R) または ./scripts/build-release.sh"
echo "  3. 初回のみ: 画面収録の権限を付与 → アプリ再起動"
echo "  4. 以降はリビルドしても権限がリセットされません"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
