import Foundation

enum StepStatus: Codable, Equatable {
    case idle, running, done
    case failed(String)
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

enum RecordingPhase: String, Codable { case recording, finished }

struct ActionItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var owner: String?
    var due: String?
    var sourceRef: String?   // transcript timestamp such as "03:12"
    var done = false
}

/// Stored as metadata.json next to the audio; never contains audio or transcript text.
struct RecordingMetadata: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval = 0
    var phase: RecordingPhase = .recording
    var transcript: StepStatus = .idle
    var summary: StepStatus = .idle
    var needsRecovery = false
    var rawTracksRemoved = false
    var droppedBuffers = 0
    var note: String?
    var language: String?
    var legacySource: String?
    var actionItems: [ActionItem] = []
    var actionItemsEdited = false
    var meeting: MeetingLink?   // optional so metadata written before calendar linking still decodes

    var statusLabel: String {
        if phase == .recording { return "Interrupted" }
        if needsRecovery { return "Needs recovery" }
        switch (transcript, summary) {
        case (.running, _): return "Transcribing…"
        case (.failed, _): return "Transcription failed"
        case (_, .running): return "Summarizing…"
        case (_, .failed): return "Summary failed"
        case (.done, .done): return "Ready"
        case (.done, _): return "Transcribed"
        default: return "Audio only"
        }
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(max(0, t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}
