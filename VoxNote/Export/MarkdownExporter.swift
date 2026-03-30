import Foundation
import AppKit

struct MarkdownExporter {
    static func export(session: TranscriptSession) {
        let md = buildMarkdown(session: session)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = filename(for: session.startDate)
        panel.message = "Markdown ファイルの保存先を選択してください"

        if panel.runModal() == .OK, let url = panel.url {
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func copyToClipboard(session: TranscriptSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buildPlainText(session: session), forType: .string)
    }

    // MARK: - フォーマット変換

    static func buildMarkdown(session: TranscriptSession) -> String {
        let headerFmt = DateFormatter()
        headerFmt.dateStyle = .medium
        headerFmt.timeStyle = .short
        headerFmt.locale = Locale(identifier: "ja_JP")

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        var lines = ["# MTG \(headerFmt.string(from: session.startDate))", ""]

        for entry in session.entries where !entry.isPending && !entry.text.isEmpty {
            let name = session.speakers.first(where: { $0.id == entry.speakerId })?.displayName ?? "不明"
            let time = timeFmt.string(from: entry.timestamp)
            lines.append("**\(name)** \(time)")
            lines.append(entry.text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    static func buildPlainText(session: TranscriptSession) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        return session.entries
            .filter { !$0.isPending && !$0.text.isEmpty }
            .map { entry in
                let name = session.speakers.first(where: { $0.id == entry.speakerId })?.displayName ?? "不明"
                let time = timeFmt.string(from: entry.timestamp)
                return "[\(time) \(name)] \(entry.text)"
            }
            .joined(separator: "\n")
    }

    private static func filename(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        return "transcript-\(fmt.string(from: date)).md"
    }
}
