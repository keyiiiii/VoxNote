import Foundation

struct TranscriptEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var speakerId: UUID
    let timestamp: Date
    var text: String
    var isPending: Bool

    init(speakerId: UUID, text: String = "", isPending: Bool = false) {
        self.id = UUID()
        self.speakerId = speakerId
        self.timestamp = Date()
        self.text = text
        self.isPending = isPending
    }
}
