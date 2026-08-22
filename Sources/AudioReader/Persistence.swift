import Foundation

enum Persistence {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AudioReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var transcriptsDir: URL {
        let dir = root.appendingPathComponent("transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var vocabURL: URL { root.appendingPathComponent("vocab.json") }
    static var settingsURL: URL { root.appendingPathComponent("settings.json") }
    static var glossesURL: URL { root.appendingPathComponent("glosses.json") }

    static func transcriptURL(chapterID: String) -> URL {
        transcriptsDir.appendingPathComponent("\(safeFileName(chapterID)).json")
    }

    static func loadTranscriptJSON(chapterID: String, audioPath: String? = nil) -> Transcript? {
        if let transcript = decodeTranscript(at: transcriptURL(chapterID: chapterID)) {
            return transcript
        }
        guard let audioPath else { return nil }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: transcriptsDir,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for url in files where url.pathExtension.lowercased() == "json" {
            guard var transcript = decodeTranscript(at: url) else { continue }
            guard transcript.audioPath == audioPath else { continue }
            transcript.chapterID = chapterID
            return transcript
        }
        return nil
    }

    static func loadTranscript(chapterID: String, audioPath: String? = nil) -> Transcript? {
        LibraryStore.shared.loadTranscript(chapterID: chapterID, audioPath: audioPath)
    }

    static func saveTranscript(_ transcript: Transcript) throws {
        try LibraryStore.shared.saveTranscript(transcript)
        let data = try JSONEncoder.iso.encode(transcript)
        try data.write(to: transcriptURL(chapterID: transcript.chapterID), options: .atomic)
    }

    private static func decodeTranscript(at url: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(Transcript.self, from: data)
    }

    /// APFS file names must be ≤255 bytes and cannot include `/` or `:`.
    static func safeFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = filtered.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        let name = trimmed.isEmpty ? "chapter" : trimmed
        if name.utf8.count <= 80 { return name }
        return String(name.prefix(80))
    }

    static func loadVocabJSON() -> [VocabEntry] {
        guard let data = try? Data(contentsOf: vocabURL) else { return [] }
        return (try? JSONDecoder.iso.decode([VocabEntry].self, from: data)) ?? []
    }

    static func loadVocab() -> [VocabEntry] {
        let fromStore = LibraryStore.shared.loadVocab()
        if !fromStore.isEmpty { return fromStore }
        return loadVocabJSON()
    }

    static func saveVocab(_ items: [VocabEntry]) {
        LibraryStore.shared.replaceVocab(items)
        guard let data = try? JSONEncoder.iso.encode(items) else { return }
        try? data.write(to: vocabURL, options: .atomic)
    }

    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    static func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    static func loadGlossesJSON() -> [GlossEntry] {
        guard let data = try? Data(contentsOf: glossesURL) else { return [] }
        return (try? JSONDecoder.iso.decode([GlossEntry].self, from: data)) ?? []
    }

    static func loadGlosses() -> [GlossEntry] {
        let fromStore = LibraryStore.shared.loadGlosses()
        if !fromStore.isEmpty { return fromStore }
        return loadGlossesJSON()
    }

    static func saveGlosses(_ items: [GlossEntry]) {
        LibraryStore.shared.replaceGlosses(items)
        guard let data = try? JSONEncoder.iso.encode(items) else { return }
        try? data.write(to: glossesURL, options: .atomic)
    }
}

struct AppSettings: Codable, Equatable {
    var libraryPath: String
    var playbackRate: Double
    var textSource: String
    var skipSeconds: Double
    var targetLanguage: String
    var grokModel: String
    var grokEffort: String
    var autoTranslate: Bool
    var playOnSelect: Bool
    var appearance: String
    var preferredDictionary: String
    var lookupPanelWidth: Double
    var readerFontScale: Double

    static var `default`: AppSettings {
        AppSettings(
            libraryPath: "/Users/johnsonzhang/Documents/books",
            playbackRate: 1.0,
            textSource: TextSource.spoken.rawValue,
            skipSeconds: 5,
            targetLanguage: StudyLanguage.zhHans.rawValue,
            grokModel: "grok-4.6",
            grokEffort: GrokEffort.low.rawValue,
            autoTranslate: false,
            playOnSelect: true,
            appearance: AppAppearance.dark.rawValue,
            preferredDictionary: "牛津英汉汉英词典",
            lookupPanelWidth: 420,
            readerFontScale: 1.0
        )
    }

    init(
        libraryPath: String,
        playbackRate: Double,
        textSource: String,
        skipSeconds: Double,
        targetLanguage: String,
        grokModel: String,
        grokEffort: String,
        autoTranslate: Bool,
        playOnSelect: Bool,
        appearance: String,
        preferredDictionary: String,
        lookupPanelWidth: Double,
        readerFontScale: Double
    ) {
        self.libraryPath = libraryPath
        self.playbackRate = playbackRate
        self.textSource = textSource
        self.skipSeconds = skipSeconds
        self.targetLanguage = targetLanguage
        self.grokModel = grokModel
        self.grokEffort = grokEffort
        self.autoTranslate = autoTranslate
        self.playOnSelect = playOnSelect
        self.appearance = appearance
        self.preferredDictionary = preferredDictionary
        self.lookupPanelWidth = lookupPanelWidth
        self.readerFontScale = readerFontScale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        libraryPath = try c.decodeIfPresent(String.self, forKey: .libraryPath) ?? d.libraryPath
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? d.playbackRate
        textSource = try c.decodeIfPresent(String.self, forKey: .textSource) ?? d.textSource
        skipSeconds = try c.decodeIfPresent(Double.self, forKey: .skipSeconds) ?? d.skipSeconds
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? d.targetLanguage
        grokModel = try c.decodeIfPresent(String.self, forKey: .grokModel) ?? d.grokModel
        grokEffort = try c.decodeIfPresent(String.self, forKey: .grokEffort) ?? d.grokEffort
        autoTranslate = try c.decodeIfPresent(Bool.self, forKey: .autoTranslate) ?? d.autoTranslate
        playOnSelect = try c.decodeIfPresent(Bool.self, forKey: .playOnSelect) ?? d.playOnSelect
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        preferredDictionary = try c.decodeIfPresent(String.self, forKey: .preferredDictionary) ?? d.preferredDictionary
        lookupPanelWidth = try c.decodeIfPresent(Double.self, forKey: .lookupPanelWidth) ?? d.lookupPanelWidth
        readerFontScale = try c.decodeIfPresent(Double.self, forKey: .readerFontScale) ?? d.readerFontScale
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
