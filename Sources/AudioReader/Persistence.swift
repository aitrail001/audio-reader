import Foundation
#if canImport(AudioReaderDomain)
import AudioReaderDomain
#endif

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
    static var knownLemmasURL: URL { root.appendingPathComponent("lexicon.json") }
    static var studyActivityURL: URL { root.appendingPathComponent("study-activity.json") }
    static var settingsURL: URL { root.appendingPathComponent("settings.json") }
    static var glossesURL: URL { root.appendingPathComponent("glosses.json") }
    static var chapterTranslationCheckpointsURL: URL { root.appendingPathComponent("chapter-translation-checkpoints.json") }
    static var chapterSummariesURL: URL { root.appendingPathComponent("chapter-summaries.json") }
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
        saveVocabJSON(items)
    }

    static func saveVocabUpdates(_ updates: [VocabEntry], allItems: [VocabEntry]) {
        LibraryStore.shared.upsertVocab(updates)
        saveVocabJSON(allItems)
    }

    private static func saveVocabJSON(_ items: [VocabEntry]) {
        guard let data = try? JSONEncoder.iso.encode(items) else { return }
        try? data.write(to: vocabURL, options: .atomic)
    }

    static func loadKnownLemmas(from url: URL = knownLemmasURL) -> [KnownLemmaRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.iso.decode([KnownLemmaRecord].self, from: data)) ?? []
    }

    static func saveKnownLemmas(
        _ items: [KnownLemmaRecord],
        to url: URL = knownLemmasURL
    ) {
        guard let data = try? JSONEncoder.iso.encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func loadStudyActivityLog(from url: URL = studyActivityURL) -> StudyActivityLog {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return (try? JSONDecoder.iso.decode(StudyActivityLog.self, from: data)) ?? .empty
    }

    static func saveStudyActivityLog(
        _ log: StudyActivityLog,
        to url: URL = studyActivityURL
    ) {
        guard let data = try? JSONEncoder.iso.encode(log) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func loadSettings() -> AppSettings {
        let settings = loadSettings(from: settingsURL)
        if let data = try? Data(contentsOf: settingsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["qwenEffortPolicyVersion"] == nil {
            saveSettings(settings)
        }
        return settings
    }

    static func loadSettings(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    @discardableResult
    static func saveSettings(_ settings: AppSettings) -> Bool {
        saveSettings(settings, to: settingsURL)
    }

    @discardableResult
    static func saveSettings(_ settings: AppSettings, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(settings) else { return false }
        do {
            try data.write(to: url, options: .atomic)
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
        saveGlossesJSON(items)
    }

    static func saveGlossUpdates(_ updates: [GlossEntry], allItems: [GlossEntry]) {
        LibraryStore.shared.upsertGloss(updates)
        saveGlossesJSON(allItems)
    }

    private static func saveGlossesJSON(_ items: [GlossEntry]) {
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

    static func loadChapterSummaries(from url: URL = chapterSummariesURL) -> [ChapterSummaryRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.iso.decode([ChapterSummaryRecord].self, from: data)) ?? []
    }

    static func saveChapterSummaries(
        _ summaries: [ChapterSummaryRecord],
        to url: URL = chapterSummariesURL
    ) {
        guard let data = try? JSONEncoder.iso.encode(summaries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

struct AppSettings: Codable, Equatable {
    var libraryPath: String
    var playbackRate: Double
    var textSource: String
    var skipSeconds: Double
    var transcriptionLanguage: String
    var bookTranscriptionLanguages: [String: String]
    var readerLanguageLevel: String
    var targetLanguage: String
    var llmProvider: String
    var grokAuthentication: String
    var grokEndpoint: String
    var grokModel: String
    var grokEffort: String
    var qwenEndpoint: String
    var qwenModel: String
    var qwenThinking: Bool
    var qwenEffort: String
    var qwenEffortPolicyVersion: Int
    var openAIAuthentication: String
    var openAIEndpoint: String
    var openAIModel: String
    var openAIEffort: String
    var sentenceContextCount: Int
    var chapterTranslationBlockSize: Int
    var chatContextCount: Int
    var autoTranslate: Bool
    var playOnSelect: Bool
    var deepReadingMode: Bool
    var showStudyOverlay: Bool
    var vocabReviewPrompt: String
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
            transcriptionLanguage: TranscriptionLanguage.englishUS.rawValue,
            bookTranscriptionLanguages: [:],
            readerLanguageLevel: ReaderLanguageLevel.intermediate.rawValue,
            targetLanguage: StudyLanguage.zhHans.rawValue,
            llmProvider: LLMProvider.grok.rawValue,
            grokAuthentication: GrokAuthentication.grokBuild.rawValue,
            grokEndpoint: LLMProvider.grok.defaultEndpoint,
            grokModel: "grok-4.6",
            grokEffort: GrokEffort.low.rawValue,
            qwenEndpoint: LLMProvider.qwenCloud.defaultEndpoint,
            qwenModel: "qwen3.7-flash",
            qwenThinking: true,
            qwenEffort: QwenEffort.none.rawValue,
            qwenEffortPolicyVersion: 1,
            openAIAuthentication: OpenAIAuthentication.chatGPT.rawValue,
            openAIEndpoint: LLMProvider.openAI.defaultEndpoint,
            openAIModel: OpenAIModel.gpt56Luna.rawValue,
            openAIEffort: OpenAIEffort.medium.rawValue,
            sentenceContextCount: 2,
            chapterTranslationBlockSize: 5,
            chatContextCount: 3,
            autoTranslate: false,
            playOnSelect: true,
            deepReadingMode: false,
            showStudyOverlay: false,
            vocabReviewPrompt: VocabReviewPrompt.recognition.rawValue,
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
        transcriptionLanguage: String,
        bookTranscriptionLanguages: [String: String],
        readerLanguageLevel: String,
        targetLanguage: String,
        llmProvider: String,
        grokAuthentication: String,
        grokEndpoint: String,
        grokModel: String,
        grokEffort: String,
        qwenEndpoint: String,
        qwenModel: String,
        qwenThinking: Bool,
        qwenEffort: String,
        qwenEffortPolicyVersion: Int,
        openAIAuthentication: String,
        openAIEndpoint: String,
        openAIModel: String,
        openAIEffort: String,
        sentenceContextCount: Int,
        chapterTranslationBlockSize: Int,
        chatContextCount: Int,
        autoTranslate: Bool,
        playOnSelect: Bool,
        deepReadingMode: Bool,
        showStudyOverlay: Bool,
        vocabReviewPrompt: String,
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
        self.transcriptionLanguage = transcriptionLanguage
        self.bookTranscriptionLanguages = bookTranscriptionLanguages
        self.readerLanguageLevel = readerLanguageLevel
        self.targetLanguage = targetLanguage
        self.llmProvider = llmProvider
        self.grokAuthentication = grokAuthentication
        self.grokEndpoint = grokEndpoint
        self.grokModel = grokModel
        self.grokEffort = grokEffort
        self.qwenEndpoint = qwenEndpoint
        self.qwenModel = qwenModel
        self.qwenThinking = qwenThinking
        self.qwenEffort = qwenEffort
        self.qwenEffortPolicyVersion = qwenEffortPolicyVersion
        self.openAIAuthentication = openAIAuthentication
        self.openAIEndpoint = openAIEndpoint
        self.openAIModel = openAIModel
        self.openAIEffort = openAIEffort
        self.sentenceContextCount = sentenceContextCount
        self.chapterTranslationBlockSize = chapterTranslationBlockSize
        self.chatContextCount = chatContextCount
        self.autoTranslate = autoTranslate
        self.playOnSelect = playOnSelect
        self.deepReadingMode = deepReadingMode
        self.showStudyOverlay = showStudyOverlay
        self.vocabReviewPrompt = vocabReviewPrompt
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
        transcriptionLanguage = try c.decodeIfPresent(String.self, forKey: .transcriptionLanguage) ?? d.transcriptionLanguage
        bookTranscriptionLanguages = try c.decodeIfPresent([String: String].self, forKey: .bookTranscriptionLanguages) ?? d.bookTranscriptionLanguages
        readerLanguageLevel = try c.decodeIfPresent(String.self, forKey: .readerLanguageLevel) ?? d.readerLanguageLevel
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? d.targetLanguage
        llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider) ?? d.llmProvider
        grokAuthentication = try c.decodeIfPresent(String.self, forKey: .grokAuthentication) ?? d.grokAuthentication
        grokEndpoint = try c.decodeIfPresent(String.self, forKey: .grokEndpoint) ?? d.grokEndpoint
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
        openAIAuthentication = try c.decodeIfPresent(String.self, forKey: .openAIAuthentication) ?? d.openAIAuthentication
        openAIEndpoint = try c.decodeIfPresent(String.self, forKey: .openAIEndpoint) ?? d.openAIEndpoint
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? d.openAIModel
        openAIEffort = try c.decodeIfPresent(String.self, forKey: .openAIEffort) ?? d.openAIEffort
        sentenceContextCount = try c.decodeIfPresent(Int.self, forKey: .sentenceContextCount) ?? d.sentenceContextCount
        chapterTranslationBlockSize = try c.decodeIfPresent(Int.self, forKey: .chapterTranslationBlockSize) ?? d.chapterTranslationBlockSize
        chatContextCount = try c.decodeIfPresent(Int.self, forKey: .chatContextCount) ?? d.chatContextCount
        autoTranslate = try c.decodeIfPresent(Bool.self, forKey: .autoTranslate) ?? d.autoTranslate
        playOnSelect = try c.decodeIfPresent(Bool.self, forKey: .playOnSelect) ?? d.playOnSelect
        deepReadingMode = try c.decodeIfPresent(Bool.self, forKey: .deepReadingMode) ?? d.deepReadingMode
        showStudyOverlay = try c.decodeIfPresent(Bool.self, forKey: .showStudyOverlay) ?? d.showStudyOverlay
        vocabReviewPrompt = try c.decodeIfPresent(String.self, forKey: .vocabReviewPrompt) ?? d.vocabReviewPrompt
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

    func endpoint(for provider: LLMProvider) -> String {
        switch provider {
        case .grok: grokEndpoint
        case .qwenCloud: qwenEndpoint
        case .openAI: openAIEndpoint
        case .appleFoundation: ""
        }
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

struct PersistenceSettingsRepository: SettingsRepository {
    var url: URL

    init(url: URL = Persistence.settingsURL) {
        self.url = url
    }

    func loadSettings() throws -> StoredSettings {
        StoredSettings(Persistence.loadSettings(from: url))
    }

    func saveSettings(_ settings: StoredSettings) throws {
        var app = Persistence.loadSettings(from: url)
        app.apply(settings)
        guard Persistence.saveSettings(app, to: url) else {
            throw LocalStoreError.saveFailed
        }
    }
}

struct PersistenceKnownLemmaRepository: KnownLemmaRepository {
    var url: URL

    init(url: URL = Persistence.knownLemmasURL) {
        self.url = url
    }

    func loadKnownLemmas() throws -> [StoredKnownLemma] {
        Persistence.loadKnownLemmas(from: url).map(StoredKnownLemma.init)
    }

    func saveKnownLemmas(_ lemmas: [StoredKnownLemma]) throws {
        Persistence.saveKnownLemmas(lemmas.map(KnownLemmaRecord.init), to: url)
    }
}

extension StoredSettings {
    init(_ settings: AppSettings) {
        self.init(
            libraryPath: settings.libraryPath,
            playbackRate: settings.playbackRate,
            textSource: settings.textSource,
            skipSeconds: settings.skipSeconds,
            transcriptionLanguage: settings.transcriptionLanguage,
            readerLanguageLevel: settings.readerLanguageLevel,
            targetLanguage: settings.targetLanguage,
            sentenceContextCount: settings.sentenceContextCount,
            chapterTranslationBlockSize: settings.chapterTranslationBlockSize,
            chatContextCount: settings.chatContextCount,
            autoTranslate: settings.autoTranslate,
            playOnSelect: settings.playOnSelect,
            deepReadingMode: settings.deepReadingMode,
            showStudyOverlay: settings.showStudyOverlay,
            vocabReviewPrompt: settings.vocabReviewPrompt,
            appearance: settings.appearance,
            preferredDictionary: settings.preferredDictionary,
            lookupPanelWidth: settings.lookupPanelWidth,
            readerFontScale: settings.readerFontScale,
            readerFont: settings.readerFont,
            readerBold: settings.readerBold,
            readerLineSpacing: settings.readerLineSpacing,
            readerWordSpacing: settings.readerWordSpacing,
            readerMargin: settings.readerMargin
        )
    }
}

extension AppSettings {
    mutating func apply(_ stored: StoredSettings) {
        libraryPath = stored.libraryPath
        playbackRate = stored.playbackRate
        textSource = stored.textSource
        skipSeconds = stored.skipSeconds
        transcriptionLanguage = stored.transcriptionLanguage
        readerLanguageLevel = stored.readerLanguageLevel
        targetLanguage = stored.targetLanguage
        sentenceContextCount = stored.sentenceContextCount
        chapterTranslationBlockSize = stored.chapterTranslationBlockSize
        chatContextCount = stored.chatContextCount
        autoTranslate = stored.autoTranslate
        playOnSelect = stored.playOnSelect
        deepReadingMode = stored.deepReadingMode
        showStudyOverlay = stored.showStudyOverlay
        vocabReviewPrompt = stored.vocabReviewPrompt
        appearance = stored.appearance
        preferredDictionary = stored.preferredDictionary
        lookupPanelWidth = stored.lookupPanelWidth
        readerFontScale = stored.readerFontScale
        readerFont = stored.readerFont
        readerBold = stored.readerBold
        readerLineSpacing = stored.readerLineSpacing
        readerWordSpacing = stored.readerWordSpacing
        readerMargin = stored.readerMargin
    }
}

extension StoredKnownLemma {
    init(_ record: KnownLemmaRecord) {
        self.init(language: record.language, form: record.form, updatedAt: record.updatedAt)
    }
}

extension KnownLemmaRecord {
    init(_ stored: StoredKnownLemma) {
        self.init(language: stored.language, form: stored.form, updatedAt: stored.updatedAt)
    }
}
