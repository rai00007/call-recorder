import Foundation

/// UserDefaults-backed preferences. Defaults match the previous hard-coded behavior.
final class AppSettings: ObservableObject {
    private let d: UserDefaults
    @Published var storagePath: String { didSet { d.set(storagePath, forKey: "storagePath") } }
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var ollamaURL: String { didSet { d.set(ollamaURL, forKey: "ollamaURL") } }
    @Published var ollamaModel: String { didSet { d.set(ollamaModel, forKey: "ollamaModel") } }
    @Published var autoSummarize: Bool { didSet { d.set(autoSummarize, forKey: "autoSummarize") } }
    @Published var consentAcknowledged: Bool { didSet { d.set(consentAcknowledged, forKey: "consent") } }
    @Published var meetingPromptsEnabled: Bool { didSet { d.set(meetingPromptsEnabled, forKey: "meetingPrompts") } }
    @Published var askAboutRawTracks: Bool { didSet { d.set(askAboutRawTracks, forKey: "askRaw") } }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallRecorder/Recordings")
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        let env = ProcessInfo.processInfo.environment
        storagePath = defaults.string(forKey: "storagePath") ?? ""
        language = defaults.string(forKey: "language") ?? "en-US"
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? env["OLLAMA_HOST_URL"] ?? "http://localhost:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? env["CALLREC_MODEL"] ?? "qwen2.5:3b"
        autoSummarize = defaults.object(forKey: "autoSummarize") as? Bool ?? true
        consentAcknowledged = defaults.bool(forKey: "consent")
        askAboutRawTracks = defaults.bool(forKey: "askRaw")
        meetingPromptsEnabled = defaults.bool(forKey: "meetingPrompts")
    }

    var storageURL: URL { storagePath.isEmpty ? Self.defaultRoot : URL(fileURLWithPath: storagePath) }
    var ollamaBaseURL: URL { URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")! }
}
