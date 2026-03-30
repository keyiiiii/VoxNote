#!/bin/bash
set -euo pipefail

# ── VoxNote アプリアイコン生成スクリプト ──
# Swift スクリプトで AppKit を使いアイコンを描画し、iconutil で .icns に変換する。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ICONSET_DIR="$PROJECT_DIR/build/VoxNote.iconset"
OUTPUT_ICNS="$PROJECT_DIR/VoxNote/Resources/AppIcon.icns"

mkdir -p "$ICONSET_DIR" "$(dirname "$OUTPUT_ICNS")"

echo "🎨 アイコン生成中..."

# Swift スクリプトで各サイズの PNG を生成
/usr/bin/swift - "$ICONSET_DIR" << 'SWIFT'
import AppKit
import Foundation

let outputDir = CommandLine.arguments[1]

func generateIcon(size: CGFloat, scale: Int, filename: String) {
    let pixelSize = size * CGFloat(scale)
    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))

    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let rect = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    let cornerRadius = pixelSize * 0.22

    // ── 背景: 濃紺グラデーション ──
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    bgPath.addClip()

    let gradient = NSGradient(
        starting: NSColor(red: 0.12, green: 0.15, blue: 0.35, alpha: 1.0),
        ending: NSColor(red: 0.05, green: 0.07, blue: 0.20, alpha: 1.0)
    )!
    gradient.draw(in: rect, angle: -90)

    // ── 波形 (背景装飾) ──
    let waveColor = NSColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 0.15)
    waveColor.setStroke()

    for i in 0..<3 {
        let wave = NSBezierPath()
        wave.lineWidth = pixelSize * 0.008
        let yOffset = pixelSize * (0.35 + CGFloat(i) * 0.15)
        let amplitude = pixelSize * (0.06 - CGFloat(i) * 0.015)

        wave.move(to: NSPoint(x: pixelSize * 0.1, y: yOffset))
        for x in stride(from: pixelSize * 0.1, through: pixelSize * 0.9, by: 1) {
            let progress = (x - pixelSize * 0.1) / (pixelSize * 0.8)
            let y = yOffset + sin(progress * .pi * 4 + CGFloat(i)) * amplitude
            wave.line(to: NSPoint(x: x, y: y))
        }
        wave.stroke()
    }

    // ── メインアイコン: マイク + 波形 ──
    let centerX = pixelSize * 0.5
    let centerY = pixelSize * 0.52

    // マイク本体 (丸みのある長方形)
    let micWidth = pixelSize * 0.14
    let micHeight = pixelSize * 0.22
    let micRect = CGRect(
        x: centerX - micWidth / 2,
        y: centerY - micHeight * 0.3,
        width: micWidth,
        height: micHeight
    )
    let micPath = NSBezierPath(roundedRect: micRect, xRadius: micWidth / 2, yRadius: micWidth / 2)
    NSColor(red: 0.4, green: 0.65, blue: 1.0, alpha: 1.0).setFill()
    micPath.fill()

    // マイクのハイライト
    let highlightRect = CGRect(
        x: centerX - micWidth * 0.15,
        y: centerY - micHeight * 0.1,
        width: micWidth * 0.2,
        height: micHeight * 0.5
    )
    let hlPath = NSBezierPath(roundedRect: highlightRect, xRadius: micWidth * 0.1, yRadius: micWidth * 0.1)
    NSColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 0.5).setFill()
    hlPath.fill()

    // マイクの U 字カップ
    let cupPath = NSBezierPath()
    cupPath.lineWidth = pixelSize * 0.02
    let cupRadius = micWidth * 0.9
    cupPath.appendArc(
        withCenter: NSPoint(x: centerX, y: centerY + micHeight * 0.2),
        radius: cupRadius,
        startAngle: 0, endAngle: 180
    )
    NSColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 0.8).setStroke()
    cupPath.stroke()

    // マイクスタンド (縦棒)
    let standPath = NSBezierPath()
    standPath.lineWidth = pixelSize * 0.02
    let standBottom = centerY - micHeight * 0.3 - pixelSize * 0.06
    standPath.move(to: NSPoint(x: centerX, y: centerY + micHeight * 0.2 - cupRadius))
    standPath.line(to: NSPoint(x: centerX, y: standBottom))
    // 横棒
    standPath.move(to: NSPoint(x: centerX - pixelSize * 0.06, y: standBottom))
    standPath.line(to: NSPoint(x: centerX + pixelSize * 0.06, y: standBottom))
    NSColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 0.8).setStroke()
    standPath.stroke()

    // ── 音波リング ──
    for i in 1...3 {
        let ringPath = NSBezierPath()
        ringPath.lineWidth = pixelSize * 0.012
        let radius = micWidth * 0.9 + CGFloat(i) * pixelSize * 0.06
        let alpha = 0.6 - CGFloat(i) * 0.15
        ringPath.appendArc(
            withCenter: NSPoint(x: centerX, y: centerY + micHeight * 0.15),
            radius: radius,
            startAngle: 30, endAngle: 150
        )
        NSColor(red: 0.4, green: 0.65, blue: 1.0, alpha: alpha).setStroke()
        ringPath.stroke()
    }

    // ── テキスト "VN" ──
    let fontSize = pixelSize * 0.12
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let textAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(red: 0.7, green: 0.85, blue: 1.0, alpha: 0.9)
    ]
    let text = "VN" as NSString
    let textSize = text.size(withAttributes: textAttrs)
    let textPoint = NSPoint(
        x: centerX - textSize.width / 2,
        y: pixelSize * 0.12
    )
    text.draw(at: textPoint, withAttributes: textAttrs)

    image.unlockFocus()

    // PNG として保存
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        return
    }

    let path = "\(outputDir)/\(filename)"
    try? (png as NSData).write(toFile: path, atomically: true)
}

// macOS アイコンセットに必要な全サイズを生成
let sizes: [(CGFloat, Int, String)] = [
    (16,  1, "icon_16x16.png"),
    (16,  2, "icon_16x16@2x.png"),
    (32,  1, "icon_32x32.png"),
    (32,  2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

for (size, scale, filename) in sizes {
    generateIcon(size: size, scale: scale, filename: filename)
}

print("Generated \(sizes.count) icon sizes")
SWIFT

# iconutil で .icns に変換
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"

echo "✅ アイコン生成完了: $OUTPUT_ICNS"
ls -lh "$OUTPUT_ICNS"
