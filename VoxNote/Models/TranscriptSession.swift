import Foundation

struct TranscriptSession: Codable {
    let id: UUID
    let startDate: Date
    var entries: [TranscriptEntry]
    var speakers: [Speaker]

    init() {
        self.id = UUID()
        self.startDate = Date()
        self.entries = []
        self.speakers = []
    }
}
