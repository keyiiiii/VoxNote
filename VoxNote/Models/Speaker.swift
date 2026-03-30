import Foundation
import SwiftUI

struct Speaker: Identifiable, Codable {
    let id: UUID
    let label: String
    var customName: String?
    let colorHex: String

    var displayName: String {
        customName ?? "話者\(label)"
    }

    static let colors = ["#007AFF", "#FF3B30", "#34C759", "#FF9500", "#AF52DE", "#5856D6"]
    static let labels = ["A", "B", "C", "D", "E", "F", "G", "H"]

    init(index: Int) {
        self.id = UUID()
        self.label = Speaker.labels[min(index, Speaker.labels.count - 1)]
        self.colorHex = Speaker.colors[index % Speaker.colors.count]
    }
}

extension Color {
    init?(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: sanitized).scanHexInt64(&rgb) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
