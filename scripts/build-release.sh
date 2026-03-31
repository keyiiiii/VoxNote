#!/bin/bash
set -euo pipefail

# ── 設定 ──
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_NAME="VoxNote"
EXPORT_DIR="${BUILD_DIR}/release"
CERT_NAME="VoxNote Developer"

echo "🔨 VoxNote Release ビルド開始..."

# ── 署名 ID の検出 (SHA-1 ハッシュで一意に指定) ──
CERT_HASH=$(security find-identity -v -p codesigning 2>/dev/null | grep "$CERT_NAME" | head -1 | awk '{print $2}')
if [[ -n "$CERT_HASH" ]]; then
    SIGN_IDENTITY="$CERT_HASH"
    SIGN_FLAGS=""
    echo "🔑 署名: $CERT_NAME ($CERT_HASH)"
else
    SIGN_IDENTITY="-"
    SIGN_FLAGS="CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO"
    echo "⚠️  証明書「$CERT_NAME」が見つかりません (ad-hoc 署名を使用)"
    echo "   画面収録の権限がリビルドごとにリセットされます"
    echo "   → ./scripts/setup-signing.sh を実行してセットアップしてください"
    echo ""
fi

# ── クリーン ──
rm -rf "${BUILD_DIR}"
mkdir -p "${EXPORT_DIR}"

# ── アイコン生成 ──
ICNS="${PROJECT_DIR}/VoxNote/Resources/AppIcon.icns"
if [[ ! -f "$ICNS" ]]; then
    echo "🎨 アイコン生成中..."
    "${PROJECT_DIR}/scripts/generate-icon.sh" 2>/dev/null || true
fi

# ── xcodegen ──
if command -v xcodegen &>/dev/null; then
    echo "⚙️  xcodegen でプロジェクト再生成..."
    cd "${PROJECT_DIR}" && xcodegen generate --quiet
fi

# ── バージョン取得 ──
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0")
echo "📌 バージョン: ${VERSION}"

# ── Release ビルド ──
echo "📦 Release ビルド中..."
xcodebuild \
    -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
    ${SIGN_FLAGS} \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${VERSION}" \
    build \
    2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:" || true

# ── .app を取り出す ──
APP_PATH=$(find "${BUILD_DIR}/DerivedData" -name "${APP_NAME}.app" -type d | head -1)

if [[ -z "$APP_PATH" ]]; then
    echo "❌ ビルド失敗: ${APP_NAME}.app が見つかりません"
    exit 1
fi

echo "✅ ビルド成功: ${APP_PATH}"

# ── .app をコピー ──
cp -R "${APP_PATH}" "${EXPORT_DIR}/${APP_NAME}.app"

# ── 署名の再適用 (deep sign) ──
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    echo "🔏 署名中..."
    codesign --force --deep --sign "$SIGN_IDENTITY" "${EXPORT_DIR}/${APP_NAME}.app"
fi

# ── ZIP 作成 ──
cd "${EXPORT_DIR}"
ZIP_NAME="${APP_NAME}-$(date +%Y%m%d).zip"
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "${ZIP_NAME}"

# ── SHA256 ──
shasum -a 256 "${ZIP_NAME}" > "${ZIP_NAME}.sha256"
ZIP_SIZE=$(du -h "${ZIP_NAME}" | cut -f1)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📁 配布ファイル: ${EXPORT_DIR}/${ZIP_NAME} (${ZIP_SIZE})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 チームへの共有手順:"
echo "  1. 上記 ZIP を Slack / Google Drive / AirDrop で共有"
echo "  2. 受け取った人は ZIP を展開"
echo "  3. VoxNote.app を /Applications に移動"
echo "  4. 初回起動時:"
echo "     - 右クリック → 「開く」 → 「開く」で Gatekeeper を通過"
echo "     - または Terminal で: xattr -cr /Applications/VoxNote.app"
echo "  5. システム設定 > プライバシーとセキュリティ > 画面収録 で許可"
echo ""
