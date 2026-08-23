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
    static var chapterTranslationCheckpointsURL: URL { root.appendingPathComponent("chapter-translation-checkpoints.json") }
    static var importedBooksURL: URL {
#if os(iOS)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = documents.appendingPathComponent("ImportedBooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let legacy = root.appendingPathComponent("ImportedBooks", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: legacy,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                let destination = dir.appendingPathComponent(entry.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                try? FileManager.default.moveItem(at: entry, to: destination)
            }
        }
        return dir
#else
        let dir = root.appendingPathComponent("ImportedBooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
#endif
    }

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

    static func loadTranscript(for chapter: Chapter) -> Transcript? {
        let legacyAudioPath = chapter.startTime == nil ? chapter.audioPath : nil
        if let transcript = loadTranscript(chapterID: chapter.id, audioPath: legacyAudioPath),
           transcript.belongs(to: chapter) {
            return transcript
        }
        guard var recovered = loadAllTranscripts()
            .filter({ matchesPersistentMedia($0, chapter: chapter) })
            .max(by: { $0.createdAt < $1.createdAt })
        else { return nil }
        recovered.chapterID = chapter.id
        recovered.audioPath = chapter.audioPath
        recovered.chapterStart = chapter.startTime
        try? saveTranscript(recovered)
        return recovered
    }

    static func loadAllTranscripts() -> [Transcript] {
        LibraryStore.shared.loadAllTranscripts()
    }

    static func readyChapterIDs(in books: [Book], transcripts: [Transcript]) -> Set<String> {
        let byChapter = Dictionary(transcripts.map { ($0.chapterID, $0) }, uniquingKeysWith: { _, newest in newest })
        return Set(books.flatMap(\.chapters).compactMap { chapter in
            if let transcript = byChapter[chapter.id], transcript.belongs(to: chapter) {
                return chapter.id
            }
            return transcripts.contains(where: { matchesPersistentMedia($0, chapter: chapter) }) ? chapter.id : nil
        })
    }

    private static func matchesPersistentMedia(_ transcript: Transcript, chapter: Chapter) -> Bool {
        guard LibraryScanner.persistentPathIdentity(transcript.audioPath)
                == LibraryScanner.persistentPathIdentity(chapter.audioPath)
        else { return false }
        switch (transcript.chapterStart, chapter.startTime) {
        case (nil, nil):
            return true
        case let (saved?, current?):
            return abs(saved - current) < 0.01
        default:
            return false
        }
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
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["qwenEffortPolicyVersion"] == nil {
            saveSettings(settings)
        }
        return settings
    }

    @discardableResult
    static func saveSettings(_ settings: AppSettings) -> Bool {
        guard let data = try? JSONEncoder().encode(settings) else { return false }
        do {
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            return false
        }
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

    static func loadChapterTranslationCheckpoints() -> [ChapterTranslationCheckpoint] {
        guard let data = try? Data(contentsOf: chapterTranslationCheckpointsURL) else { return [] }
        return (try? JSONDecoder.iso.decode([ChapterTranslationCheckpoint].self, from: data)) ?? []
    }

    static func saveChapterTranslationCheckpoints(_ checkpoints: [ChapterTranslationCheckpoint]) {
        guard let data = try? JSONEncoder.iso.encode(checkpoints) else { return }
        try? data.write(to: chapterTranslationCheckpointsURL, options: .atomic)
    }
}

struct AppSettings: Codable, Equatable {
    var libraryPath: String
    var playbackRate: Double
    var textSource: String
    var skipSeconds: Double
    var targetLanguage: String
    var llmProvider: String
    var grokModel: String
    var grokEffort: String
    var qwenEndpoint: String
    var qwenModel: String
    var qwenThinking: Bool
    var qwenEffort: String
    var qwenEffortPolicyVersion: Int
    var sentenceContextCount: Int
    var chapterTranslationBlockSize: Int
    var chatContextCount: Int
    var autoTranslate: Bool
    var playOnSelect: Bool
    var appearance: String
    var preferredDictionary: String
    var lookupPanelWidth: Double
    var readerFontScale: Double
    var readerFont: String
    var readerBold: Bool
    var readerLineSpacing: Double
    var readerWordSpacing: Double
    var readerMargin: Double

    static var `default`: AppSettings {
        AppSettings(
            libraryPath: defaultLibraryPath,
            playbackRate: 1.0,
            textSource: TextSource.spoken.rawValue,
            skipSeconds: 5,
            targetLanguage: StudyLanguage.zhHans.rawValue,
            llmProvider: LLMProvider.grok.rawValue,
            grokModel: "grok-4.6",
            grokEffort: GrokEffort.low.rawValue,
            qwenEndpoint: LLMProvider.qwenCloud.defaultEndpoint,
            qwenModel: "qwen3.7-flash",
            qwenThinking: true,
            qwenEffort: QwenEffort.none.rawValue,
            qwenEffortPolicyVersion: 1,
            sentenceContextCount: 2,
            chapterTranslationBlockSize: 5,
            chatContextCount: 3,
            autoTranslate: false,
            playOnSelect: true,
            appearance: AppAppearance.dark.rawValue,
            preferredDictionary: "牛津英汉汉英词典",
            lookupPanelWidth: 420,
            readerFontScale: 1.0,
            readerFont: ReaderFontChoice.newYork.rawValue,
            readerBold: false,
            readerLineSpacing: 1.0,
            readerWordSpacing: 2.0,
            readerMargin: 32
        )
    }

    private static var defaultLibraryPath: String {
#if os(macOS)
        "/Users/johnsonzhang/Documents/books"
#else
        Persistence.importedBooksURL.path
#endif
    }

    init(
        libraryPath: String,
        playbackRate: Double,
        textSource: String,
        skipSeconds: Double,
        targetLanguage: String,
        llmProvider: String,
        grokModel: String,
        grokEffort: String,
        qwenEndpoint: String,
        qwenModel: String,
        qwenThinking: Bool,
        qwenEffort: String,
        qwenEffortPolicyVersion: Int,
        sentenceContextCount: Int,
        chapterTranslationBlockSize: Int,
        chatContextCount: Int,
        autoTranslate: Bool,
        playOnSelect: Bool,
        appearance: String,
        preferredDictionary: String,
        lookupPanelWidth: Double,
        readerFontScale: Double,
        readerFont: String,
        readerBold: Bool,
        readerLineSpacing: Double,
        readerWordSpacing: Double,
        readerMargin: Double
    ) {
        self.libraryPath = libraryPath
        self.playbackRate = playbackRate
        self.textSource = textSource
        self.skipSeconds = skipSeconds
        self.targetLanguage = targetLanguage
        self.llmProvider = llmProvider
        self.grokModel = grokModel
        self.grokEffort = grokEffort
        self.qwenEndpoint = qwenEndpoint
        self.qwenModel = qwenModel
        self.qwenThinking = qwenThinking
        self.qwenEffort = qwenEffort
        self.qwenEffortPolicyVersion = qwenEffortPolicyVersion
        self.sentenceContextCount = sentenceContextCount
        self.chapterTranslationBlockSize = chapterTranslationBlockSize
        self.chatContextCount = chatContextCount
        self.autoTranslate = autoTranslate
        self.playOnSelect = playOnSelect
        self.appearance = appearance
        self.preferredDictionary = preferredDictionary
        self.lookupPanelWidth = lookupPanelWidth
        self.readerFontScale = readerFontScale
        self.readerFont = readerFont
        self.readerBold = readerBold
        self.readerLineSpacing = readerLineSpacing
        self.readerWordSpacing = readerWordSpacing
        self.readerMargin = readerMargin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        libraryPath = try c.decodeIfPresent(String.self, forKey: .libraryPath) ?? d.libraryPath
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? d.playbackRate
        textSource = try c.decodeIfPresent(String.self, forKey: .textSource) ?? d.textSource
        skipSeconds = try c.decodeIfPresent(Double.self, forKey: .skipSeconds) ?? d.skipSeconds
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? d.targetLanguage
        llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider) ?? d.llmProvider
        grokModel = try c.decodeIfPresent(String.self, forKey: .grokModel) ?? d.grokModel
        grokEffort = try c.decodeIfPresent(String.self, forKey: .grokEffort) ?? d.grokEffort
        qwenEndpoint = try c.decodeIfPresent(String.self, forKey: .qwenEndpoint) ?? d.qwenEndpoint
        qwenModel = try c.decodeIfPresent(String.self, forKey: .qwenModel) ?? d.qwenModel
        qwenThinking = try c.decodeIfPresent(Bool.self, forKey: .qwenThinking) ?? d.qwenThinking
        let savedEffortPolicyVersion = try c.decodeIfPresent(Int.self, forKey: .qwenEffortPolicyVersion) ?? 0
        qwenEffort = savedEffortPolicyVersion >= 1
            ? (try c.decodeIfPresent(String.self, forKey: .qwenEffort) ?? d.qwenEffort)
            : QwenEffort.none.rawValue
        qwenEffortPolicyVersion = 1
        sentenceContextCount = try c.decodeIfPresent(Int.self, forKey: .sentenceContextCount) ?? d.sentenceContextCount
        chapterTranslationBlockSize = try c.decodeIfPresent(Int.self, forKey: .chapterTranslationBlockSize) ?? d.chapterTranslationBlockSize
        chatContextCount = try c.decodeIfPresent(Int.self, forKey: .chatContextCount) ?? d.chatContextCount
        autoTranslate = try c.decodeIfPresent(Bool.self, forKey: .autoTranslate) ?? d.autoTranslate
        playOnSelect = try c.decodeIfPresent(Bool.self, forKey: .playOnSelect) ?? d.playOnSelect
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        preferredDictionary = try c.decodeIfPresent(String.self, forKey: .preferredDictionary) ?? d.preferredDictionary
        lookupPanelWidth = try c.decodeIfPresent(Double.self, forKey: .lookupPanelWidth) ?? d.lookupPanelWidth
        readerFontScale = try c.decodeIfPresent(Double.self, forKey: .readerFontScale) ?? d.readerFontScale
        readerFont = try c.decodeIfPresent(String.self, forKey: .readerFont) ?? d.readerFont
        readerBold = try c.decodeIfPresent(Bool.self, forKey: .readerBold) ?? d.readerBold
        readerLineSpacing = try c.decodeIfPresent(Double.self, forKey: .readerLineSpacing) ?? d.readerLineSpacing
        readerWordSpacing = try c.decodeIfPresent(Double.self, forKey: .readerWordSpacing) ?? d.readerWordSpacing
        readerMargin = try c.decodeIfPresent(Double.self, forKey: .readerMargin) ?? d.readerMargin
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
