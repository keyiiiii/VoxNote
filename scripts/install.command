#!/bin/bash
# VoxNote インストーラー
# このファイルをダブルクリックして実行してください。

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VoxNote.app"
APP_SRC="$SCRIPT_DIR/$APP_NAME"
APP_DST="/Applications/$APP_NAME"

echo ""
echo "================================"
echo "  VoxNote インストーラー"
echo "================================"
echo ""

if [[ ! -d "$APP_SRC" ]]; then
    echo "❌ $APP_NAME が見つかりません。"
    echo "   install.command と VoxNote.app を同じフォルダに置いてください。"
    echo ""
    read -p "Enter で終了..."
    exit 1
fi

# Gatekeeper の隔離属性を除去
echo "🔓 セキュリティ属性を解除中..."
xattr -cr "$APP_SRC"

# /Applications にコピー
echo "📦 /Applications にインストール中..."
if [[ -d "$APP_DST" ]]; then
    rm -rf "$APP_DST"
fi
cp -R "$APP_SRC" "$APP_DST"

echo "✅ インストール完了！"
echo ""
echo "VoxNote を起動します..."
open "$APP_DST"
echo ""
