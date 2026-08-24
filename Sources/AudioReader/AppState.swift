import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class AppState {
    var settings: AppSettings
    var books: [Book] = []
    var selectedBookID: String?
    var selectedChapterID: String?
    var transcript: Transcript?
    var vocab: [VocabEntry] = []
    var tab: AppTab = .library
    var textSource: TextSource = .spoken
    var player = PlayerEngine()

    var isScanning = false
    var libraryScanProgress: LibraryScanProgress?
    var readyChapterIDs: Set<String> = []
    var isTranscribing = false
    var transcriptionProgress: TranscriptionProgress?
    var transcriptionJobOrigin: BackgroundJobOrigin?
    var backgroundJobNavigationError: String?
    var errorMessage: String?
    var selectedWord: TranscriptWord?
    var definition: String?
    var dictionaryHits: [DictionaryHit] = []
    var selectedDictionaryName: String = ""
    var loopSentence = false
    var glosses: [GlossEntry] = [] {
        didSet { chapterGlossGeneration &+= 1 }
    }
    var chapterTranslationCheckpoints: [ChapterTranslationCheckpoint] = []
    var isTranslating = false
    var translationError: String?
    var vocabularyNotice: String?
    var showSettings = false
    var apiKeyDraft = ""
    var qwenAPIKeyDraft = ""
    var qwenModels = QwenModelCatalog.fallback
    var isLoadingQwenModels = false
    var qwenModelsMessage: String?
    var showChapterAssistant = false
    var chapterTranslation: String?
    var chapterTranslationProgress: LibraryScanProgress?
    var chapterAcceptanceProgress: LibraryScanProgress?
    var chapterTranslationJobOrigin: BackgroundJobOrigin?
    var chapterSummary: String?
    var chapterChat: [LLMChatMessage] = []
    var isChapterAssistantWorking = false
    var chapterAssistantError: String?
    var chapterTranslationFailed = false
    private(set) var chapterTranslationStopRequested = false
    var focusedSegmentID: String?
    var focusedWordID: String?
    var scrollSegmentID: String?
    var revealToken: Int = 0

    private var transcriber = Transcriber()
    private var transcriptionTask: Task<Void, Never>?
    private var lastSentenceID: String?
    private var pendingReveal: PendingReveal?
    @ObservationIgnored private var chapterGlossGeneration = 0
    @ObservationIgnored private var chapterGlossIndexCache = ChapterGlossIndexCache()
    var llmJobQueue = BackgroundJobQueue(maxConcurrentPerKind: 2)
    @ObservationIgnored private var llmJobOperations: [UUID: @MainActor (UUID) async -> Void] = [:]
    @ObservationIgnored private var chapterTranslationStopRequests: Set<UUID> = []
    @ObservationIgnored private var chapterSummariesByChapterID: [String: String] = [:]
    @ObservationIgnored private var chapterChatsByChapterID: [String: [LLMChatMessage]] = [:]
    @ObservationIgnored private var chapterAssistantErrorsByChapterID: [String: String] = [:]
    @ObservationIgnored private var chapterAcceptanceID: UUID?

    var selectedBook: Book? {
        books.first { $0.id == selectedBookID }
    }

    var selectedChapter: Chapter? {
        selectedBook?.chapters.first { $0.id == selectedChapterID }
    }

    var backgroundJobs: [BackgroundJob] {
        var jobs: [BackgroundJob] = []
        if isTranscribing, let origin = transcriptionJobOrigin {
            jobs.append(BackgroundJob(
                kind: .transcription,
                bookID: origin.bookID,
                bookTitle: origin.bookTitle,
                chapterID: origin.chapterID,
                chapterTitle: origin.chapterTitle,
                stage: "Transcribing chapter",
                detail: transcriptionProgress?.message ?? "Starting…",
                fraction: transcriptionProgress?.fraction
            ))
        }
        jobs.append(contentsOf: llmJobQueue.jobs)
        if !llmJobQueue.jobs.contains(where: { $0.kind == .chapterTranslation }),
           isChapterAssistantWorking,
           let origin = chapterTranslationJobOrigin,
           let progress = chapterTranslationProgress {
            jobs.append(BackgroundJob(
                kind: .chapterTranslation,
                bookID: origin.bookID,
                bookTitle: origin.bookTitle,
                chapterID: origin.chapterID,
                chapterTitle: origin.chapterTitle,
                stage: progress.stage,
                detail: progress.detail,
                fraction: progress.fraction
            ))
        }
        return jobs
    }

    func isLLMJobActive(kind: BackgroundJob.Kind, targetID: String? = nil) -> Bool {
        llmJobQueue.jobs.contains {
            $0.kind == kind
                && $0.chapterID == selectedChapterID
                && (targetID == nil || $0.targetID == targetID)
        }
    }

    var selectedChapterTranslationJobState: BackgroundJob.State? {
        llmJobQueue.presentation(forChapterID: selectedChapterID).chapterTranslationState
    }

    var currentReaderPosition: (segment: TranscriptSegment?, word: TranscriptWord?) {
        guard let transcript else { return (nil, nil) }
        let t = player.currentTime
        guard let segment = transcript.segments.last(where: { t >= $0.start - 0.05 && t < $0.end + 0.12 })
            ?? transcript.segments.last(where: { t >= $0.start })
        else { return (nil, nil) }
        let word = segment.words.last(where: { t >= $0.start && t < $0.end + 0.02 })
            ?? segment.words.last(where: { t >= $0.start })
        return (segment, word)
    }

    var currentSegment: TranscriptSegment? {
        currentReaderPosition.segment
    }

    var currentWord: TranscriptWord? {
        currentReaderPosition.word
    }

    var studyLanguage: StudyLanguage {
        StudyLanguage(rawValue: settings.targetLanguage) ?? .zhHans
    }

    var llmProvider: LLMProvider {
        LLMProvider(rawValue: settings.llmProvider) ?? .grok
    }

    var selectedLLMModel: String {
        llmProvider == .qwenCloud ? settings.qwenModel : settings.grokModel
    }

    var qwenTextModels: [LLMModelInfo] {
        var models = qwenModels.filter(\.supportsText)
        if !models.contains(where: { $0.id == settings.qwenModel }) {
            models.append(.init(id: settings.qwenModel, brand: "Custom", capabilities: "Custom model ID", supportsText: true))
        }
        return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    var selectedQwenEfforts: [QwenEffort] {
        QwenRequestPolicy.supportedEfforts(model: settings.qwenModel)
    }

    var qwenSupportsThinkingToggle: Bool {
        QwenRequestPolicy.supportsThinkingToggle(model: settings.qwenModel)
    }

    func normalizeSelectedQwenEffort() {
        let supported = selectedQwenEfforts
        guard !supported.isEmpty,
              !supported.contains(where: { $0.rawValue == settings.qwenEffort })
        else { return }
        settings.qwenEffort = supported.contains(.none) ? QwenEffort.none.rawValue : supported[0].rawValue
        persistSettings()
    }

    var currentSentenceGloss: GlossEntry? {
        guard let segment = currentSegment else { return nil }
        return sentenceGloss(for: segment)
    }

    func sentenceGloss(for segment: TranscriptSegment) -> GlossEntry? {
        sentenceGlossIndex(language: settings.targetLanguage).gloss(source: segment.displayText)
    }

    var selectedWordGloss: GlossEntry? {
        guard let word = selectedWord else { return nil }
        return lookupGloss(
            kind: .word,
            source: DictionaryLookup.headword(word.text),
            context: currentSegment?.displayText
        )
    }

    var acceptedSentences: [GlossEntry] {
        glosses.filter { $0.kind == .sentence && $0.status == .accepted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var selectedChapterTranslationCheckpoint: ChapterTranslationCheckpoint? {
        guard let chapterID = selectedChapterID else { return nil }
        let id = ChapterTranslationCheckpoint.makeID(chapterID: chapterID, language: settings.targetLanguage)
        return chapterTranslationCheckpoints.first { $0.id == id }
    }

    func transcribedChapterCount(in book: Book) -> Int {
        book.chapters.lazy.filter { self.readyChapterIDs.contains($0.id) }.count
    }

    init() {
        settings = Persistence.loadSettings()
#if os(iOS)
        // iOS data-container UUIDs can change after reinstalling an app, so a
        // persisted absolute Documents path must never drive library scanning.
        settings.libraryPath = Persistence.importedBooksURL.path
#endif
        vocab = Persistence.loadVocab().map { entry in
            var copy = entry
            copy.sanitizeDictionaryFields()
            return copy
        }
        glosses = Persistence.loadGlosses()
        chapterTranslationCheckpoints = Persistence.loadChapterTranslationCheckpoints()
        apiKeyDraft = APIKeyStore.savedFileKey() ?? ""
        qwenAPIKeyDraft = QwenAPIKeyStore.savedFileKey() ?? ""
        selectedDictionaryName = settings.preferredDictionary
        if let raw = TextSource(rawValue: settings.textSource) {
            textSource = raw
        }
        player.rate = Float(settings.playbackRate)
        importGlossesIntoVocab()
        if vocab.contains(where: { DictionaryLookup.looksLikeMarkup($0.definition ?? "") }) {
            Persistence.saveVocab(vocab)
        }
    }

    func boot() async {
        await rescan()
        if let first = books.first {
            selectedBookID = first.id
            selectedChapterID = first.chapters.first?.id
        }
        if llmProvider == .qwenCloud {
            Task { await self.refreshQwenModels() }
        }
    }

    func rescan() async {
        isScanning = true
        libraryScanProgress = .init(
            stage: "Scanning library",
            detail: "Finding audiobook folders and files…",
            completed: 0,
            total: 0
        )
        defer {
            isScanning = false
            libraryScanProgress = nil
        }
        let root: URL
#if os(iOS)
        root = Persistence.importedBooksURL
#else
        root = URL(fileURLWithPath: settings.libraryPath)
#endif
        let scanned = await Task.detached(priority: .userInitiated) {
            LibraryScanner.scan(root: root)
        }.value
        libraryScanProgress = .init(
            stage: "Preparing covers",
            detail: "Loading cover artwork for \(scanned.count) books…",
            completed: 0,
            total: scanned.count
        )
        let coverPaths = scanned.compactMap(\.coverPath)
        await Task.detached(priority: .utility) {
            CoverImageCache.shared.preload(paths: coverPaths)
        }.value
        books = scanned
        let transcripts = await Task.detached(priority: .utility) {
            Persistence.loadAllTranscripts()
        }.value
        readyChapterIDs = Persistence.readyChapterIDs(in: scanned, transcripts: transcripts)

        libraryScanProgress = .init(
            stage: "Reading chapter information",
            detail: "0 of \(scanned.count) books complete",
            completed: 0,
            total: scanned.count
        )
        var completed = 0
        await withTaskGroup(of: (Int, Book).self) { group in
            for (index, book) in scanned.enumerated() {
                group.addTask {
                    (index, await LibraryScanner.loadDurations(for: book))
                }
            }
            for await (index, updated) in group {
                if index < books.count, books[index].id == updated.id {
                    books[index] = updated
                }
                completed += 1
                libraryScanProgress = .init(
                    stage: "Reading chapter information",
                    detail: "\(completed) of \(scanned.count) books complete",
                    completed: completed,
                    total: scanned.count
                )
            }
        }
        readyChapterIDs = Persistence.readyChapterIDs(in: books, transcripts: transcripts)
    }

    func open(chapter: Chapter, in book: Book, autoplay: Bool) {
        selectedBookID = book.id
        selectedChapterID = chapter.id
        tab = .player
        player.load(path: chapter.audioPath, startTime: chapter.audioStart, duration: chapter.duration)
        player.rate = Float(settings.playbackRate)
        transcript = Persistence.loadTranscript(for: chapter)
        chapterTranslation = nil
        chapterSummary = chapterSummariesByChapterID[chapter.id]
        chapterChat = chapterChatsByChapterID[chapter.id] ?? []
        chapterAssistantError = chapterAssistantErrorsByChapterID[chapter.id]
        chapterTranslationFailed = false
        restoreChapterTranslationMessage()
        refreshLLMBusyState()
        if pendingReveal == nil {
            selectedWord = nil
            definition = nil
            dictionaryHits = []
            focusedSegmentID = nil
            focusedWordID = nil
            scrollSegmentID = nil
        }
        if autoplay { player.play() }
        if let pending = pendingReveal, transcript != nil {
            applyReveal(pending)
            pendingReveal = nil
        }
    }

    @discardableResult
    func openBackgroundJob(_ job: BackgroundJob) -> Bool {
        backgroundJobNavigationError = nil
        guard let book = backgroundJobBook(for: job.origin) else {
            backgroundJobNavigationError = "Could not find “\(job.bookTitle)” in the library. It may have been moved or deleted."
            return false
        }
        guard let chapter = backgroundJobChapter(for: job.origin, in: book) else {
            backgroundJobNavigationError = "Could not find “\(job.chapterTitle)” in “\(book.title)”. It may have been moved or deleted."
            return false
        }
        player.pause()
        open(chapter: chapter, in: book, autoplay: false)
        return true
    }

    private func backgroundJobBook(for origin: BackgroundJobOrigin) -> Book? {
        if let bookID = origin.bookID, !bookID.isEmpty {
            return books.first { $0.id == bookID }
        }
        let matches = books.filter {
            $0.title.caseInsensitiveCompare(origin.bookTitle) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func backgroundJobChapter(for origin: BackgroundJobOrigin, in book: Book) -> Chapter? {
        if let chapterID = origin.chapterID, !chapterID.isEmpty {
            return book.chapters.first { $0.id == chapterID }
        }
        let matches = book.chapters.filter {
            $0.title.caseInsensitiveCompare(origin.chapterTitle) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    var canOpenPreviousChapter: Bool {
        adjacentChapter(offset: -1) != nil
    }

    var canOpenNextChapter: Bool {
        adjacentChapter(offset: 1) != nil
    }

    func openPreviousChapter() {
        openAdjacentChapter(offset: -1)
    }

    func openNextChapter() {
        openAdjacentChapter(offset: 1)
    }

    private func openAdjacentChapter(offset: Int) {
        guard let book = selectedBook, let chapter = adjacentChapter(offset: offset) else { return }
        open(chapter: chapter, in: book, autoplay: player.isPlaying)
    }

    private func adjacentChapter(offset: Int) -> Chapter? {
        guard let book = selectedBook,
              let selectedChapterID,
              let index = book.chapters.firstIndex(where: { $0.id == selectedChapterID })
        else { return nil }
        let destination = index + offset
        guard book.chapters.indices.contains(destination) else { return nil }
        return book.chapters[destination]
    }

    func transcribeSelected(force: Bool = false) {
        guard let book = selectedBook, let chapter = selectedChapter else { return }
        if !force, let existing = Persistence.loadTranscript(for: chapter) {
            transcript = existing
            return
        }
        transcriptionTask?.cancel()
        isTranscribing = true
        transcriptionJobOrigin = BackgroundJobOrigin(
            bookID: book.id,
            bookTitle: book.title,
            chapterID: chapter.id,
            chapterTitle: chapter.title
        )
        transcriptionProgress = .init(fraction: 0, message: "Starting…")
        errorMessage = nil
        let transcriber = self.transcriber
        transcriptionTask = Task {
            do {
                let result = try await transcriber.transcribe(
                    chapter: chapter,
                    ebookPath: book.ebookPath,
                    progress: { [weak self] p in
                        Task { @MainActor in
                            self?.transcriptionProgress = p
                        }
                    },
                    checkpoint: { [weak self] locale, segments in
                        await self?.commitTranscript(
                            chapter: chapter,
                            locale: locale,
                            segments: segments,
                            aligned: false
                        )
                    }
                )
                self.commitTranscript(
                    chapter: chapter,
                    locale: result.locale,
                    segments: result.segments,
                    aligned: result.ebookAligned
                )
            } catch is CancellationError {
                // ignore
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isTranscribing = false
            self.transcriptionProgress = nil
            self.transcriptionJobOrigin = nil
        }
    }

    @discardableResult
    private func commitTranscript(
        chapter: Chapter,
        locale: String,
        segments: [TranscriptSegment],
        aligned: Bool
    ) -> Bool {
        let transcript = Transcript(
            chapterID: chapter.id,
            audioPath: chapter.audioPath,
            chapterStart: chapter.startTime,
            createdAt: Date(),
            locale: locale,
            segments: segments,
            source: "SpeechAnalyzer",
            ebookAligned: aligned
        )
        do {
            try Persistence.saveTranscript(transcript)
            readyChapterIDs.insert(chapter.id)
            if selectedChapterID == chapter.id {
                self.transcript = transcript
                if let pending = pendingReveal {
                    applyReveal(pending)
                    pendingReveal = nil
                }
            }
            return true
        } catch {
            errorMessage = "Could not save transcript: \(error.localizedDescription)"
            if selectedChapterID == chapter.id {
                self.transcript = transcript
            }
            return false
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        Task { await transcriber.cancel() }
        isTranscribing = false
        transcriptionProgress = nil
        transcriptionJobOrigin = nil
    }

    func togglePlay() {
        guard selectedChapter != nil else { return }
        if transcript == nil, !isTranscribing {
            transcribeSelected()
        }
        player.toggle()
    }

    func skipSentence(direction: Int) {
        guard let transcript, let current = currentSegment else {
            player.skip(seconds: Double(direction) * settings.skipSeconds)
            return
        }
        guard let idx = transcript.segments.firstIndex(of: current) else { return }
        if direction < 0 {
            if player.currentTime - current.start > 1.0 {
                player.seek(current.start)
            } else if idx > 0 {
                player.seek(transcript.segments[idx - 1].start)
            } else {
                player.seek(0)
            }
        } else {
            if idx + 1 < transcript.segments.count {
                player.seek(transcript.segments[idx + 1].start)
            }
        }
    }

    func replaySentence() {
        if let current = currentSegment {
            player.seek(current.start)
            player.play()
        }
    }

    func tickLoop() {
        guard loopSentence, let current = currentSegment else { return }
        if player.currentTime >= current.end - 0.04 {
            player.seek(current.start)
            player.play()
        }
    }

    func isInVocabulary(word: TranscriptWord) -> Bool {
        guard let chapter = selectedChapter else { return false }
        let head = DictionaryLookup.headword(word.text)
        guard !head.isEmpty else { return false }
        return vocab.contains {
            $0.word.caseInsensitiveCompare(head) == .orderedSame
                && $0.chapterID == chapter.id
                && $0.category == .word
                && abs($0.timestamp - word.start) < 0.4
        }
    }

    func addVocab(word: TranscriptWord, segment: TranscriptSegment) {
        guard let book = selectedBook, let chapter = selectedChapter else {
            vocabularyNotice = "Choose a book and chapter before adding vocabulary."
            return
        }
        let head = DictionaryLookup.headword(word.text)
        guard !head.isEmpty else {
            vocabularyNotice = "This selection cannot be added to vocabulary."
            return
        }
        if isInVocabulary(word: word) {
            vocabularyNotice = "“\(head)” is already in your vocabulary."
            return
        }
        let gloss = lookupGloss(kind: .word, source: head, context: segment.displayText)
        let accepted = gloss?.status == .accepted ? gloss : lookupGloss(kind: .word, source: head, context: nil)
        let dict = selectedDictionaryHit ?? dictionaryHits.first
        let entry = VocabEntry(
            id: UUID().uuidString,
            word: head,
            category: .word,
            definition: DictionaryLookup.plainPreview(from: dict?.preview ?? definition ?? dict?.html ?? ""),
            dictionaryName: dict?.name,
            dictionaryHTML: DictionaryLookup.optionalDisplayHTML(dict?.html),
            translation: (accepted?.status == .accepted ? accepted?.text : nil) ?? (gloss?.status == .accepted ? gloss?.text : nil),
            translationLanguage: accepted?.language ?? gloss?.language,
            translationModel: accepted?.model ?? gloss?.model,
            context: segment.displayText,
            spokenText: segment.spokenText,
            ebookText: segment.ebookText,
            bookID: book.id,
            bookTitle: book.title,
            chapterID: chapter.id,
            chapterTitle: chapter.title,
            segmentID: segment.id,
            wordID: word.id,
            timestamp: word.start,
            addedAt: Date()
        )
        vocab.insert(entry, at: 0)
        Persistence.saveVocab(vocab)
        vocabularyNotice = "Added “\(head)” to your vocabulary."
    }

    func removeVocab(_ entry: VocabEntry) {
        vocab.removeAll { $0.id == entry.id }
        Persistence.saveVocab(vocab)
    }

    @discardableResult
    func jumpToVocab(_ entry: VocabEntry) -> Bool {
        pendingReveal = PendingReveal(
            kind: entry.category == .sentence ? .sentence : .word,
            timestamp: entry.timestamp,
            segmentID: entry.segmentID,
            wordID: entry.wordID,
            wordText: entry.category == .sentence ? nil : entry.word,
            sentenceText: entry.context
        )
        guard let located = locate(bookID: entry.bookID, bookTitle: entry.bookTitle, chapterID: entry.chapterID, chapterTitle: entry.chapterTitle) else {
            errorMessage = "Could not find “\(entry.bookTitle)” in the library."
            pendingReveal = nil
            return false
        }
        tab = .player
        open(chapter: located.chapter, in: located.book, autoplay: false)
        return true
    }

    func jumpToGloss(_ entry: GlossEntry) {
        pendingReveal = PendingReveal(
            kind: entry.kind == .sentence ? .sentence : .word,
            timestamp: entry.timestamp ?? 0,
            segmentID: nil,
            wordID: nil,
            wordText: entry.kind == .word ? entry.source : nil,
            sentenceText: entry.kind == .sentence ? entry.source : entry.context
        )
        guard let located = locate(bookID: entry.bookID, bookTitle: entry.bookTitle, chapterID: entry.chapterID, chapterTitle: entry.chapterTitle) else {
            errorMessage = "Could not find that passage in the library."
            pendingReveal = nil
            return
        }
        tab = .player
        open(chapter: located.chapter, in: located.book, autoplay: false)
    }

    func inspect(word: TranscriptWord) {
        showChapterAssistant = false
        selectedWord = word
        translationError = nil
        dictionaryHits = []
        definition = nil
        let preferred = settings.preferredDictionary
        let text = word.text
        let wordID = word.id
        Task.detached(priority: .userInitiated) {
            let hits = DictionaryLookup.lookup(text, preferredName: preferred)
            await MainActor.run {
                guard self.selectedWord?.id == wordID else { return }
                self.dictionaryHits = hits
                if hits.contains(where: { $0.name == preferred }) {
                    self.selectedDictionaryName = preferred
                } else {
                    self.selectedDictionaryName = hits.first?.name ?? preferred
                }
                let hit = hits.first(where: { $0.name == self.selectedDictionaryName }) ?? hits.first
                self.definition = hit.map { DictionaryLookup.plainPreview(from: $0.preview.isEmpty ? $0.html : $0.preview) }
            }
        }
    }

    var selectedDictionaryHit: DictionaryHit? {
        dictionaryHits.first { $0.name == selectedDictionaryName } ?? dictionaryHits.first
    }

    func persistSettings() {
        settings.playbackRate = Double(player.rate)
        settings.textSource = textSource.rawValue
        Persistence.saveSettings(settings)
    }

    func refreshQwenModels() async {
        let models = await retrieveQwenModels(baseURL: settings.qwenEndpoint, apiKey: nil)
        guard let models else { return }
        let selectable = models.filter(\.supportsText)
        if !selectable.contains(where: { $0.id == settings.qwenModel }),
           let replacement = selectable.first(where: { $0.id == "qwen3.8-max" }) ?? selectable.first {
            settings.qwenModel = replacement.id
            persistSettings()
        }
    }

    @discardableResult
    func retrieveQwenModels(baseURL: String, apiKey: String?) async -> [LLMModelInfo]? {
        qwenModels = QwenModelCatalog.fallback
        let supplied = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supplied?.isEmpty == false || QwenAPIKeyStore.isConfigured else {
            qwenModelsMessage = "Using the built-in model catalog until a DashScope key is configured."
            return nil
        }
        isLoadingQwenModels = true
        qwenModelsMessage = nil
        defer { isLoadingQwenModels = false }
        do {
            let discovered = try await GrokClient.shared.qwenModels(baseURL: baseURL, apiKey: apiKey)
            qwenModels = QwenModelCatalog.discovered(discovered)
            qwenModelsMessage = "Loaded \(discovered.count) models from QwenCloud."
            return qwenModels
        } catch {
            qwenModelsMessage = "Model discovery failed; using the built-in catalog. \(error.localizedDescription)"
            return nil
        }
    }

    func lookupGloss(kind: GlossKind, source: String, context: String?) -> GlossEntry? {
        let id = GlossEntry.makeID(kind: kind, language: settings.targetLanguage, source: source, context: context)
        if let hit = glosses.first(where: { $0.id == id }), hit.status != .rejected {
            return hit
        }
        return glosses.first {
            $0.kind == kind
            && $0.language == settings.targetLanguage
            && $0.status != .rejected
            && GlossEntry.normalize($0.source) == GlossEntry.normalize(source)
        }
    }

    func translateCurrentSentence() {
        guard let segment = currentSegment else { return }
        translate(kind: .sentence, source: segment.displayText, context: nil, timestamp: segment.start, segment: segment, targetID: segment.id)
    }

    func retranslateCurrentSentence() {
        guard let segment = currentSegment else { return }
        retranslateSentence(segment)
    }

    func retranslateSentence(_ segment: TranscriptSegment) {
        translate(kind: .sentence, source: segment.displayText, context: nil, timestamp: segment.start, segment: segment, targetID: segment.id, force: true)
    }

    func translateSelectedWord() {
        guard let word = selectedWord else { return }
        let head = DictionaryLookup.headword(word.text)
        translate(
            kind: .word,
            source: head,
            context: currentSegment?.displayText,
            timestamp: word.start,
            segment: currentSegment,
            targetID: word.id
        )
    }

    func retranslateSelectedWord() {
        guard let word = selectedWord else { return }
        let head = DictionaryLookup.headword(word.text)
        translate(
            kind: .word,
            source: head,
            context: currentSegment?.displayText,
            timestamp: word.start,
            segment: currentSegment,
            targetID: word.id,
            force: true
        )
    }

    func ensureAutoTranslation() {
        guard settings.autoTranslate else { return }
        guard currentSentenceGloss == nil, currentSegment != nil else { return }
        translateCurrentSentence()
    }

    func acceptGloss(_ entry: GlossEntry) {
        var copy = entry
        copy.status = .accepted
        copy.decidedAt = Date()
        copy.replacedText = nil
        copy.replacedModel = nil
        saveGloss(copy)
        refreshSelectedChapterTranslationStatus()
    }

    func rejectGloss(_ entry: GlossEntry) {
        if let replacedText = entry.replacedText, let replacedModel = entry.replacedModel {
            var restored = entry
            restored.text = replacedText
            restored.model = replacedModel
            restored.status = .accepted
            restored.decidedAt = Date()
            restored.replacedText = nil
            restored.replacedModel = nil
            saveGloss(restored)
            refreshSelectedChapterTranslationStatus()
            return
        }
        var copy = entry
        copy.status = .rejected
        copy.decidedAt = Date()
        saveGloss(copy)
        let source = GlossEntry.normalize(entry.source)
        vocab.removeAll {
            GlossEntry.normalize($0.context) == source
            || (entry.kind == .word && $0.category == .word && $0.word.caseInsensitiveCompare(entry.source) == .orderedSame && $0.translation == entry.text)
        }
        Persistence.saveVocab(vocab)
        refreshSelectedChapterTranslationStatus()
    }

    func retryGloss(_ entry: GlossEntry) {
        if entry.kind == .sentence {
            retranslateCurrentSentence()
        } else {
            retranslateSelectedWord()
        }
    }

    private func selectedOrigin() -> BackgroundJobOrigin {
        BackgroundJobOrigin(
            bookID: selectedBook?.id,
            bookTitle: selectedBook?.title ?? "Unknown book",
            chapterID: selectedChapter?.id ?? transcript?.chapterID,
            chapterTitle: selectedChapter?.title ?? "Unknown chapter"
        )
    }

    private func isSelected(_ origin: BackgroundJobOrigin) -> Bool {
        guard let chapterID = origin.chapterID else { return false }
        return selectedChapterID == chapterID
    }

    private func enqueueLLMJob(
        id: UUID = UUID(),
        kind: BackgroundJob.Kind,
        origin: BackgroundJobOrigin,
        targetID: String? = nil,
        stage: String? = nil,
        detail: String? = nil,
        operation: @escaping @MainActor (UUID) async -> Void
    ) {
        llmJobOperations[id] = operation
        let job = llmJobQueue.enqueue(
            id: id,
            kind: kind,
            origin: origin,
            targetID: targetID,
            stage: stage,
            detail: detail
        )
        refreshLLMBusyState()
        if job.state == .running {
            launchLLMJob(id)
        }
    }

    private func launchLLMJob(_ id: UUID) {
        guard let operation = llmJobOperations[id] else { return }
        Task {
            await operation(id)
            let promotedID = llmJobQueue.finish(id: id)
            llmJobOperations[id] = nil
            chapterTranslationStopRequests.remove(id)
            refreshLLMBusyState()
            if let promotedID {
                launchLLMJob(promotedID)
            }
        }
    }

    private func updateLLMJob(
        id: UUID,
        stage: String,
        detail: String,
        completed: Int? = nil,
        total: Int? = nil
    ) {
        let fraction = completed.flatMap { completed in
            total.flatMap { $0 > 0 ? Double(completed) / Double($0) : nil }
        }
        llmJobQueue.update(id: id, stage: stage, detail: detail, fraction: fraction)
        guard let job = llmJobQueue.jobs.first(where: { $0.id == id }), isSelected(job.origin) else { return }
        if job.kind == .chapterTranslation, let completed, let total {
            chapterTranslationProgress = LibraryScanProgress(
                stage: stage,
                detail: detail,
                completed: completed,
                total: total
            )
            chapterTranslationJobOrigin = job.origin
        }
    }

    func refreshLLMBusyState() {
        let presentation = llmJobQueue.presentation(forChapterID: selectedChapterID)
        isTranslating = presentation.isTranslating
        isChapterAssistantWorking = presentation.isChapterAssistantWorking
        restoreSelectedChapterJobPresentation()
    }

    private func restoreSelectedChapterJobPresentation() {
        guard let chapterID = selectedChapterID else {
            chapterTranslationProgress = nil
            chapterTranslationJobOrigin = nil
            chapterTranslationStopRequested = false
            return
        }
        let job = llmJobQueue.jobs.first {
            $0.kind == .chapterTranslation && $0.chapterID == chapterID
        }
        chapterTranslationJobOrigin = job?.origin
        chapterTranslationStopRequested = job.map { chapterTranslationStopRequests.contains($0.id) } ?? false
        if let job {
            let fraction = job.fraction
            chapterTranslationProgress = LibraryScanProgress(
                stage: job.stage,
                detail: job.detail,
                completed: fraction.map { Int(($0 * 1_000).rounded()) } ?? 0,
                total: fraction == nil ? 0 : 1_000
            )
        } else {
            chapterTranslationProgress = nil
        }
    }

    func prepareGlossReplacement(
        force: Bool,
        kind: GlossKind,
        source: String,
        context: String?
    ) -> GlossEntry? {
        guard force else { return nil }
        return lookupGloss(kind: kind, source: source, context: context)
    }

    private func translate(
        kind: GlossKind,
        source: String,
        context: String?,
        timestamp: TimeInterval,
        segment: TranscriptSegment?,
        targetID: String,
        force: Bool = false
    ) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = GlossEntry.makeID(kind: kind, language: settings.targetLanguage, source: trimmed, context: context)
        let replaced = prepareGlossReplacement(
            force: force,
            kind: kind,
            source: trimmed,
            context: context
        )
        let provider = llmProvider
        let isConfigured = provider == .grok ? APIKeyStore.isConfigured : QwenAPIKeyStore.isConfigured
        guard isConfigured else {
            translationError = LLMError.noAPIKey(provider).localizedDescription
            showSettings = true
            return
        }
        if !force,
           let existing = lookupGloss(kind: kind, source: trimmed, context: context),
           existing.status == .accepted || existing.status == .pending {
            return
        }
        translationError = nil
        let language = studyLanguage
        let model = selectedLLMModel
        let baseURL = provider == .qwenCloud ? settings.qwenEndpoint : provider.defaultEndpoint
        let effort = provider == .qwenCloud ? settings.qwenEffort : settings.grokEffort
        let enableThinking = settings.qwenThinking
        let book = selectedBook
        let chapter = selectedChapter
        let origin = selectedOrigin()
        let jobKind: BackgroundJob.Kind = kind == .sentence ? .sentenceTranslation : .wordTranslation
        guard !llmJobQueue.jobs.contains(where: {
            $0.kind == jobKind && $0.chapterID == origin.chapterID && $0.targetID == targetID
        }) else { return }
        let metadata = bookMetadata(book: book, chapter: chapter)
        let capturedTranscript = transcript
        let system: String
        let user: String
        if kind == .sentence {
            system = """
            You are a literary translator and English-learning tutor.
            Work in \(language.promptName).

            Output exactly this layout, nothing before or after it:

            译文：
            <natural translation of the whole sentence; keep names; audiobook register; 1–2 sentences>

            短语：
            • <English phrase or idiom from THIS sentence> — <how it is used here, in \(language.promptName)>
            • <next phrase> — <meaning in this sentence>

            Rules:
            - Pull out collocations, phrasal verbs, idioms, and set phrases (e.g. "have trouble doing", "in trouble", "ask for trouble").
            - Explain the sense in *this* sentence, not a generic dictionary dump.
            - Skip ordinary single words unless they are part of a phrase.
            - If there is nothing worth noting, write: 短语：无
            - No quotes around the translation. No grammar lecture.
            """
            user = """
            \(metadata)

            Passage context (translate only the TARGET sentence):
            \(segment.map { neighboringContext(around: $0, in: capturedTranscript, radius: settings.sentenceContextCount) } ?? "TARGET: \(trimmed)")
            """
        } else {
            system = """
            You are an English-learning tutor.
            Apple Dictionary already lists every sense of the word. Do NOT repeat that list.
            Your only job is the meaning of this word (or the phrase it sits in) as used in THIS sentence.

            Work in \(language.promptName).

            Output exactly this layout, nothing before or after it:

            本句释义：
            <part of speech in this sentence> — <short meaning here, in \(language.promptName)>
            <if it is part of a phrase/idiom, name the phrase and what it means here>

            例句：
            • <new English sentence using THIS same sense, not some other meaning>
              <translation of that example>
            • <second new example, same sense>
              <translation>

            Rules:
            - Pick the one sense that fits the given sentence. Ignore other dictionary senses.
            - Examples must be substitutable for that sense (e.g. if the sentence uses "trouble" = difficulty/problem, do not give examples about "don't trouble yourself" or medical "heart trouble" unless that is the sentence sense).
            - Keep examples short and natural.
            - No extra commentary.
            """
            user = "Word: \(trimmed)\nSentence: \(context ?? trimmed)"
        }
        enqueueLLMJob(
            kind: jobKind,
            origin: origin,
            targetID: targetID,
            detail: "Requesting \(model)…"
        ) { _ in
            do {
                let text = try await GrokClient.shared.complete(
                    provider: provider,
                    system: system,
                    user: user,
                    baseURL: baseURL,
                    model: model,
                    effort: effort,
                    enableThinking: enableThinking
                )
                let entry = GlossEntry(
                    id: id,
                    kind: kind,
                    language: language.rawValue,
                    source: trimmed,
                    context: context,
                    text: text,
                    status: .pending,
                    model: model,
                    bookID: book?.id,
                    bookTitle: book?.title,
                    chapterID: chapter?.id,
                    chapterTitle: chapter?.title,
                    timestamp: timestamp,
                    createdAt: Date(),
                    decidedAt: nil,
                    replacedText: replaced?.status == .accepted ? replaced?.text : nil,
                    replacedModel: replaced?.status == .accepted ? replaced?.model : nil
                )
                self.saveGloss(entry)
            } catch {
                if let replaced {
                    self.saveGloss(replaced)
                }
                if self.isSelected(origin) {
                    self.translationError = error.localizedDescription
                }
            }
        }
    }

    func translateChapter(mode: ChapterTranslationMode = .untranslatedOnly) {
        guard let transcript, !transcript.segments.isEmpty else {
            chapterAssistantError = "Transcribe this chapter before translating it."
            return
        }
        let language = studyLanguage
        let resumedMode = mode == .continueFromCheckpoint
            ? selectedChapterTranslationCheckpoint?.mode ?? .untranslatedOnly
            : mode
        let startIndex: Int
        if mode == .continueFromCheckpoint {
            startIndex = min(max(0, selectedChapterTranslationCheckpoint?.nextSegmentIndex ?? 0), transcript.segments.count)
        } else {
            startIndex = 0
        }
        let indexedSegments = transcript.segments.enumerated().filter { index, segment in
            guard index >= startIndex else { return false }
            return resumedMode == .retranslateAll || sentenceGloss(for: segment, language: language.rawValue) == nil
        }
        let pendingSegments = indexedSegments.map(\.element)
        guard !pendingSegments.isEmpty else {
            refreshSelectedChapterTranslationStatus()
            chapterTranslation = selectedChapterTranslationCheckpoint?.status == .allAccepted
                ? "All chapter translations are accepted. You can retranslate the whole chapter."
                : "Every sentence has a translation and is ready for review."
            return
        }
        let provider = llmProvider
        let configured = provider == .grok ? APIKeyStore.isConfigured : QwenAPIKeyStore.isConfigured
        guard configured else {
            chapterAssistantError = LLMError.noAPIKey(provider).localizedDescription
            showSettings = true
            return
        }
        let blocks = ChapterTranslationBatch.blocks(pendingSegments, size: settings.chapterTranslationBlockSize)
        let total = pendingSegments.count
        let model = selectedLLMModel
        let baseURL = provider == .qwenCloud ? settings.qwenEndpoint : provider.defaultEndpoint
        let effort = provider == .qwenCloud ? settings.qwenEffort : settings.grokEffort
        let enableThinking = settings.qwenThinking
        let book = selectedBook
        let chapter = selectedChapter
        let checkpointChapterID = chapter?.id ?? transcript.chapterID
        let origin = selectedOrigin()
        guard !llmJobQueue.jobs.contains(where: {
            $0.kind == .chapterTranslation && $0.chapterID == checkpointChapterID
        }) else { return }
        let jobID = UUID()
        let metadata = bookMetadata(book: book, chapter: chapter)
        if isSelected(origin) {
            chapterTranslationJobOrigin = origin
            chapterTranslationStopRequested = false
            chapterAssistantError = nil
            chapterTranslation = nil
            chapterTranslationFailed = false
            chapterTranslationProgress = .init(
                stage: "Translating chapter",
                detail: "0 of \(total) sentence drafts ready",
                completed: 0,
                total: total
            )
        }
        saveTranslationCheckpoint(
            chapterID: checkpointChapterID,
            language: language.rawValue,
            mode: resumedMode,
            nextSegmentIndex: startIndex,
            total: transcript.segments.count,
            status: .inProgress
        )

        enqueueLLMJob(
            id: jobID,
            kind: .chapterTranslation,
            origin: origin,
            stage: "Translating chapter",
            detail: "0 of \(total) sentence drafts ready"
        ) { jobID in
            var completed = 0
            var stoppedAfterBlock = false
            var jobFailed = false
            for block in blocks {
                var remaining = block
                var lastIssue = ChapterTranslationBatchError.missingSentences.localizedDescription
                for attempt in 1...ChapterTranslationBatch.maximumAttempts where !remaining.isEmpty {
                    let system = """
                    You are a literary translator and English-learning tutor. Translate each target sentence into \(language.promptName).
                    Use every sentence in this block as context, but return exactly one result per supplied sentence.
                    Preserve names, dialogue, tone, and meaning. For each sentence, identify useful collocations, phrasal verbs, idioms, and set phrases and explain how they are used here.

                    Return valid JSON only, as an object with this exact shape:
                    {"translations":[{"id":"the supplied sentence id","translation":"natural translation","phrases":[{"source":"English phrase","explanation":"contextual meaning in \(language.promptName)"}]}]}
                    Use an empty phrases array when nothing is worth noting. Do not add markdown fences or commentary.
                    """
                    let numbered = block.enumerated().map { index, segment in
                        "\(index + 1). id=\(segment.id)\n\(segment.displayText)"
                    }.joined(separator: "\n\n")
                    let targetIDs = remaining.map(\.id).joined(separator: ", ")
                    let user = "\(metadata)\n\nContext block:\n\(numbered)\n\nTranslate only these target IDs: \(targetIDs)"
                    let stopRequested = self.chapterTranslationStopRequests.contains(jobID)
                    self.updateLLMJob(
                        id: jobID,
                        stage: "Translating chapter",
                        detail: stopRequested
                            ? "Stop requested · finishing the current block"
                            : "\(completed) of \(total) drafts ready · attempt \(attempt) of \(ChapterTranslationBatch.maximumAttempts)",
                        completed: completed,
                        total: total
                    )
                    do {
                        let raw = try await GrokClient.shared.completeStructuredJSON(
                            provider: provider,
                            system: system,
                            user: user,
                            baseURL: baseURL,
                            model: model,
                            effort: effort,
                            enableThinking: enableThinking
                        )
                        let parsed = try ChapterTranslationBatch.parseAvailable(
                            raw,
                            expectedIDs: remaining.map(\.id)
                        )
                        var completedEntries: [GlossEntry] = []
                        completedEntries.reserveCapacity(parsed.results.count)
                        for result in parsed.results {
                            guard let segment = remaining.first(where: { $0.id == result.id }) else { continue }
                            let existing = self.sentenceGloss(for: segment, language: language.rawValue)
                            completedEntries.append(GlossEntry(
                                id: GlossEntry.makeID(kind: .sentence, language: language.rawValue, source: segment.displayText, context: nil),
                                kind: .sentence,
                                language: language.rawValue,
                                source: segment.displayText,
                                context: nil,
                                text: result.glossText,
                                status: .pending,
                                model: model,
                                bookID: book?.id,
                                bookTitle: book?.title,
                                chapterID: chapter?.id,
                                chapterTitle: chapter?.title,
                                timestamp: segment.start,
                                createdAt: Date(),
                                decidedAt: nil,
                                replacedText: resumedMode == .retranslateAll && existing?.status == .accepted ? existing?.text : nil,
                                replacedModel: resumedMode == .retranslateAll && existing?.status == .accepted ? existing?.model : nil
                            ))
                        }
                        self.saveGlosses(completedEntries)
                        completed += completedEntries.count
                        let missing = Set(parsed.missingIDs)
                        remaining.removeAll { !missing.contains($0.id) }
                        if !remaining.isEmpty {
                            lastIssue = ChapterTranslationBatchError.missingSentences.localizedDescription
                        }
                    } catch {
                        lastIssue = error.localizedDescription
                    }
                    if !remaining.isEmpty, attempt < ChapterTranslationBatch.maximumAttempts {
                        try? await Task.sleep(for: .milliseconds(500 * attempt))
                    }
                }
                if !remaining.isEmpty {
                    jobFailed = true
                    let nextIndex = transcript.segments.firstIndex { $0.id == remaining[0].id } ?? startIndex
                    self.saveTranslationCheckpoint(chapterID: checkpointChapterID, language: language.rawValue, mode: resumedMode, nextSegmentIndex: nextIndex, total: transcript.segments.count, status: .inProgress)
                    if self.isSelected(origin) {
                        self.chapterTranslationFailed = true
                        self.chapterAssistantError = "Translation paused after \(ChapterTranslationBatch.maximumAttempts) attempts. \(remaining.count) sentence(s) in this block still need translation. Last issue: \(lastIssue)"
                        self.chapterTranslation = "\(completed) finished sentence draft(s) were checkpointed. Retry resumes with the remaining sentences only."
                    }
                    break
                }
                let nextIndex = (block.compactMap { item in
                    transcript.segments.firstIndex { $0.id == item.id }
                }.max() ?? startIndex) + 1
                self.saveTranslationCheckpoint(chapterID: checkpointChapterID, language: language.rawValue, mode: resumedMode, nextSegmentIndex: nextIndex, total: transcript.segments.count, status: .inProgress)
                if self.chapterTranslationStopRequests.contains(jobID) {
                    stoppedAfterBlock = true
                    if self.isSelected(origin) {
                        self.chapterTranslation = "Stopped after the current block. \(completed) sentence draft(s) are saved, and Continue from last stop resumes at the next block."
                    }
                    break
                }
            }
            if !jobFailed, !stoppedAfterBlock {
                if self.isSelected(origin) {
                    self.chapterTranslation = "\(completed) sentence drafts are ready for review in the chapter text."
                }
                self.refreshChapterTranslationStatus(chapterID: checkpointChapterID, language: language.rawValue, transcript: transcript)
            }
            if self.isSelected(origin) {
                self.chapterTranslationStopRequested = false
                self.chapterTranslationProgress = nil
                self.chapterTranslationJobOrigin = nil
            }
        }
    }

    func requestChapterTranslationStop() {
        guard let progress = chapterTranslationProgress else { return }
        if let chapterID = selectedChapterID,
           let job = llmJobQueue.jobs.first(where: {
               $0.kind == .chapterTranslation && $0.chapterID == chapterID
           }) {
            guard job.state == .running else { return }
            chapterTranslationStopRequests.insert(job.id)
            chapterTranslationStopRequested = true
            updateLLMJob(
                id: job.id,
                stage: progress.stage,
                detail: "Stop requested · finishing the current block",
                completed: progress.completed,
                total: progress.total
            )
            return
        }

        // Compatibility for an already-running pre-queue translation restored
        // from older state during this process lifetime.
        chapterTranslationStopRequested = true
        chapterTranslationProgress = .init(
            stage: progress.stage,
            detail: "Stop requested · finishing the current block",
            completed: progress.completed,
            total: progress.total
        )
    }

    var pendingChapterSentenceGlosses: [GlossEntry] {
        guard let book = selectedBook, let chapter = selectedChapter else { return [] }
        return GlossBatch.pendingSentences(
            in: glosses,
            bookID: book.id,
            legacyBookID: LibraryScanner.legacyAbsolutePathID(for: book),
            chapterID: chapter.id,
            legacyChapterID: LibraryScanner.legacyAbsolutePathID(for: chapter),
            language: settings.targetLanguage,
            currentSentenceSources: transcript?.segments.map(\.displayText) ?? []
        )
    }

    func acceptAllChapterTranslations() {
        let entries = pendingChapterSentenceGlosses
        guard !entries.isEmpty, chapterAcceptanceProgress == nil else { return }
        let accepted = GlossBatch.accepting(entries)
        let operationID = UUID()
        chapterAcceptanceID = operationID
        chapterAcceptanceProgress = .init(
            stage: "Accepting translations",
            detail: "Preparing \(accepted.count) sentence translation(s)…",
            completed: 0,
            total: accepted.count
        )
        glosses = GlossBatch.merging(accepted, into: glosses)

        let vocabSnapshot = vocab
        let acceptedChapterID = selectedChapterID
        let acceptedTranscript = transcript
        let acceptedLanguage = settings.targetLanguage
        let segments = acceptedTranscript?.segments ?? []
        let defaults = chapterAcceptanceDefaults
        let preferredDictionary = settings.preferredDictionary
        Task {
            await Task.yield()
            let result = await Task.detached(priority: .userInitiated) {
                ChapterAcceptanceBatch.prepare(
                    glosses: accepted,
                    vocab: vocabSnapshot,
                    segments: segments,
                    defaults: defaults,
                    definitionResolver: { phrase in
                        DictionaryLookup.lookup(phrase, preferredName: preferredDictionary).first
                    },
                    progress: { completed, total in
                        Task { @MainActor [weak self] in
                            guard self?.chapterAcceptanceID == operationID else { return }
                            self?.chapterAcceptanceProgress = .init(
                                stage: "Accepting translations",
                                detail: "Prepared \(completed) of \(total) sentence translation(s)",
                                completed: completed,
                                total: total
                            )
                        }
                    }
                )
            }.value
            guard chapterAcceptanceID == operationID else { return }

            mergeVocabUpserts(result.upserts, orderedAs: result.vocab)
            chapterAcceptanceProgress = .init(
                stage: "Saving translations",
                detail: "Writing vocabulary and translation updates…",
                completed: accepted.count,
                total: accepted.count
            )
            let glossSnapshot = glosses
            let updatedVocabSnapshot = vocab
            await Task.detached(priority: .utility) {
                Persistence.saveGlossUpdates(accepted, allItems: glossSnapshot)
                Persistence.saveVocabUpdates(result.upserts, allItems: updatedVocabSnapshot)
            }.value
            guard chapterAcceptanceID == operationID else { return }

            if let acceptedChapterID, let acceptedTranscript {
                refreshChapterTranslationStatus(
                    chapterID: acceptedChapterID,
                    language: acceptedLanguage,
                    transcript: acceptedTranscript
                )
            }
            if selectedChapterID == acceptedChapterID {
                if chapterTranslationFailed {
                    chapterTranslationFailed = false
                    chapterAssistantError = nil
                    chapterTranslation = "Accepted \(entries.count) completed sentence draft(s). Use Translate chapter to resume the untranslated remainder."
                } else {
                    chapterTranslation = "All chapter sentence translations were accepted."
                }
            }
            chapterAcceptanceProgress = nil
            chapterAcceptanceID = nil
        }
    }

    private func saveTranslationCheckpoint(
        chapterID: String,
        language: String,
        mode: ChapterTranslationMode? = nil,
        nextSegmentIndex: Int,
        total: Int,
        status: ChapterTranslationStatus
    ) {
        let id = ChapterTranslationCheckpoint.makeID(chapterID: chapterID, language: language)
        let previous = chapterTranslationCheckpoints.first { $0.id == id }
        let checkpoint = ChapterTranslationCheckpoint(
            chapterID: chapterID,
            language: language,
            mode: mode ?? previous?.mode ?? .untranslatedOnly,
            nextSegmentIndex: nextSegmentIndex,
            totalSentences: total,
            status: status,
            updatedAt: Date()
        )
        if let index = chapterTranslationCheckpoints.firstIndex(where: { $0.id == checkpoint.id }) {
            chapterTranslationCheckpoints[index] = checkpoint
        } else {
            chapterTranslationCheckpoints.append(checkpoint)
        }
        Persistence.saveChapterTranslationCheckpoints(chapterTranslationCheckpoints)
    }

    private func refreshSelectedChapterTranslationStatus() {
        guard let transcript, !transcript.segments.isEmpty, let chapterID = selectedChapterID else { return }
        refreshChapterTranslationStatus(chapterID: chapterID, language: settings.targetLanguage, transcript: transcript)
    }

    private func refreshChapterTranslationStatus(chapterID: String, language: String, transcript: Transcript) {
        let index = ChapterGlossIndex(glosses: glosses, language: language)
        let entries = transcript.segments.compactMap { index.gloss(source: $0.displayText) }
        let status: ChapterTranslationStatus
        if entries.count == transcript.segments.count, entries.allSatisfy({ $0.status == .accepted }) {
            status = .allAccepted
        } else if entries.count == transcript.segments.count {
            status = .awaitingReview
        } else {
            status = .inProgress
        }
        let nextIndex = transcript.segments.firstIndex { index.gloss(source: $0.displayText) == nil } ?? transcript.segments.count
        saveTranslationCheckpoint(chapterID: chapterID, language: language, nextSegmentIndex: nextIndex, total: transcript.segments.count, status: status)
    }

    private func sentenceGloss(for segment: TranscriptSegment, language: String) -> GlossEntry? {
        sentenceGlossIndex(language: language).gloss(source: segment.displayText)
    }

    private func sentenceGlossIndex(language: String) -> ChapterGlossIndex {
        chapterGlossIndexCache.index(
            glosses: glosses,
            generation: chapterGlossGeneration,
            language: language
        )
    }

    private func restoreChapterTranslationMessage() {
        guard let checkpoint = selectedChapterTranslationCheckpoint else { return }
        switch checkpoint.status {
        case .inProgress:
            chapterTranslation = "Chapter translation stopped after sentence \(min(checkpoint.nextSegmentIndex, checkpoint.totalSentences)) of \(checkpoint.totalSentences). Continue from the saved checkpoint or translate only missing sentences."
        case .awaitingReview:
            chapterTranslation = "All sentence translations are ready for review. Accept or reject them individually, or accept all."
        case .allAccepted:
            chapterTranslation = "All chapter translations are accepted. You can retranslate the whole chapter."
        }
    }

    func summarizeChapter() {
        guard let transcript, !transcript.segments.isEmpty else {
            chapterAssistantError = "Transcribe this chapter before summarising it."
            return
        }
        let origin = selectedOrigin()
        guard !llmJobQueue.jobs.contains(where: {
            $0.kind == .chapterSummary && $0.chapterID == origin.chapterID
        }) else { return }
        let system = """
        Summarise this audiobook chapter in \(studyLanguage.promptName).
        Cover the main events or arguments, important characters or ideas, and themes. Use concise headings and bullet points.
        Do not invent details outside the supplied chapter.
        """
        let metadata = bookMetadata(book: selectedBook, chapter: selectedChapter)
        enqueueChapterAssistant(
            kind: .chapterSummary,
            origin: origin,
            system: system,
            user: fullChapterInput(transcript, metadata: metadata)
        ) { summary in
            guard let chapterID = origin.chapterID else { return }
            self.chapterSummariesByChapterID[chapterID] = summary
            if self.isSelected(origin) {
                self.chapterSummary = summary
            }
        }
    }

    func sendChapterChat(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard let transcript else {
            chapterAssistantError = "Transcribe this chapter before chatting about it."
            return
        }
        let origin = selectedOrigin()
        guard let chapterID = origin.chapterID else { return }
        let message = LLMChatMessage(role: .user, text: question)
        chapterChat.append(message)
        chapterChatsByChapterID[chapterID] = chapterChat
        let history = chapterChat.suffix(10).map {
            "\($0.role.rawValue.uppercased()): \($0.text)"
        }.joined(separator: "\n\n")
        let targetID = focusedSegmentID ?? currentSegment?.id
        let context = targetID
            .flatMap { id in transcript.segments.first(where: { $0.id == id }) }
            .map { neighboringContext(around: $0, in: transcript, radius: settings.chatContextCount) }
            ?? "No current sentence."
        let system = """
        You are a reading companion. Answer in \(studyLanguage.promptName) unless the reader asks for another language.
        Ground the answer in the supplied book and nearby chapter passage. Clearly say when the context is insufficient.
        """
        let user = """
        \(bookMetadata(book: selectedBook, chapter: selectedChapter))

        Nearby reading context:
        \(context)

        Conversation:
        \(history)
        """
        enqueueChapterAssistant(
            kind: .chapterChat,
            origin: origin,
            targetID: message.id.uuidString,
            system: system,
            user: user
        ) { answer in
            var messages = self.chapterChatsByChapterID[chapterID] ?? []
            messages.append(.init(role: .assistant, text: answer))
            self.chapterChatsByChapterID[chapterID] = messages
            if self.isSelected(origin) {
                self.chapterChat = messages
            }
        }
    }

    private func enqueueChapterAssistant(
        kind: BackgroundJob.Kind,
        origin: BackgroundJobOrigin,
        targetID: String? = nil,
        system: String,
        user: String,
        completion: @escaping @MainActor (String) -> Void
    ) {
        let provider = llmProvider
        let configured = provider == .grok ? APIKeyStore.isConfigured : QwenAPIKeyStore.isConfigured
        guard configured else {
            chapterAssistantError = LLMError.noAPIKey(provider).localizedDescription
            showSettings = true
            return
        }
        let baseURL = provider == .qwenCloud ? settings.qwenEndpoint : provider.defaultEndpoint
        let model = selectedLLMModel
        let effort = provider == .qwenCloud ? settings.qwenEffort : settings.grokEffort
        let enableThinking = settings.qwenThinking
        if let chapterID = origin.chapterID {
            chapterAssistantErrorsByChapterID[chapterID] = nil
        }
        if isSelected(origin) {
            chapterAssistantError = nil
        }
        enqueueLLMJob(
            kind: kind,
            origin: origin,
            targetID: targetID,
            detail: "Requesting \(model)…"
        ) { _ in
            do {
                let result = try await GrokClient.shared.complete(
                    provider: provider,
                    system: system,
                    user: user,
                    baseURL: baseURL,
                    model: model,
                    effort: effort,
                    enableThinking: enableThinking
                )
                completion(result)
            } catch {
                if let chapterID = origin.chapterID {
                    self.chapterAssistantErrorsByChapterID[chapterID] = error.localizedDescription
                }
                if self.isSelected(origin) {
                    self.chapterAssistantError = error.localizedDescription
                }
            }
        }
    }

    private func bookMetadata(book: Book?, chapter: Chapter?) -> String {
        let title = book?.title ?? "Unknown book"
        let author = book?.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chapter = chapter?.title ?? "Unknown chapter"
        return "Book: \(title)\nAuthor: \(author?.isEmpty == false ? author! : "Unknown")\nChapter: \(chapter)"
    }

    private func neighboringContext(around segment: TranscriptSegment, in transcript: Transcript?, radius: Int) -> String {
        guard let segments = transcript?.segments,
              let index = segments.firstIndex(where: { $0.id == segment.id })
        else { return "TARGET: \(segment.displayText)" }
        let lower = max(0, index - max(0, radius))
        let upper = min(segments.count - 1, index + max(0, radius))
        return (lower...upper).map { i in
            let marker = i == index ? "TARGET" : (i < index ? "PREVIOUS" : "NEXT")
            return "\(marker) \(i + 1): \(segments[i].displayText)"
        }.joined(separator: "\n")
    }

    private func fullChapterInput(_ transcript: Transcript, metadata: String) -> String {
        let text = transcript.segments.enumerated().map { "\($0.offset + 1). \($0.element.displayText)" }.joined(separator: "\n")
        return "\(metadata)\n\nComplete chapter transcript:\n\(text)"
    }

    private func saveGloss(_ entry: GlossEntry) {
        saveGlosses([entry])
    }

    private func saveGlosses(_ entries: [GlossEntry]) {
        guard !entries.isEmpty else { return }
        glosses = GlossBatch.merging(entries, into: glosses)
        Persistence.saveGlosses(glosses)
        var vocabularyChanged = false
        for entry in entries where entry.status == .accepted {
            let changed = autoreleasepool {
                captureAccepted(entry, persist: false)
            }
            vocabularyChanged = vocabularyChanged || changed
        }
        if vocabularyChanged {
            Persistence.saveVocab(vocab)
        }
    }

    func importGlossesIntoVocab() {
        let keep = glosses.filter { $0.status == .accepted }
        guard !keep.isEmpty else { return }
        let result = ChapterAcceptanceBatch.prepare(
            glosses: keep,
            vocab: vocab,
            segments: transcript?.segments ?? [],
            defaults: chapterAcceptanceDefaults
        )
        guard !result.upserts.isEmpty else { return }
        vocab = result.vocab
        Persistence.saveVocabUpdates(result.upserts, allItems: vocab)
    }

    private var chapterAcceptanceDefaults: ChapterAcceptanceBatch.Defaults {
        ChapterAcceptanceBatch.Defaults(
            bookID: selectedBookID ?? "",
            bookTitle: selectedBook?.title ?? "",
            chapterID: selectedChapterID ?? "",
            chapterTitle: selectedChapter?.title ?? "",
            timestamp: currentSegment?.start ?? 0,
            segment: currentSegment,
            wordID: selectedWord?.id
        )
    }

    private func mergeVocabUpserts(_ updates: [VocabEntry], orderedAs prepared: [VocabEntry]) {
        guard !updates.isEmpty else { return }
        let updateIDs = Set(updates.map(\.id))
        var currentIDs = Set(vocab.map(\.id))
        for update in updates {
            if let index = vocab.firstIndex(where: { $0.id == update.id }) {
                vocab[index] = update
            }
        }
        let additions = prepared.filter { updateIDs.contains($0.id) && currentIDs.insert($0.id).inserted }
        vocab.insert(contentsOf: additions, at: 0)
    }

    @discardableResult
    private func captureAccepted(_ gloss: GlossEntry, persist: Bool = true) -> Bool {
        let bookID = gloss.bookID ?? selectedBookID ?? ""
        let bookTitle = gloss.bookTitle ?? selectedBook?.title ?? ""
        let chapterID = gloss.chapterID ?? selectedChapterID ?? ""
        let chapterTitle = gloss.chapterTitle ?? selectedChapter?.title ?? ""
        let timestamp = gloss.timestamp ?? currentSegment?.start ?? 0
        let segment = transcript?.segments.first {
            GlossEntry.normalize($0.displayText) == GlossEntry.normalize(gloss.source)
        } ?? currentSegment
        let original = gloss.context ?? gloss.source
        let dict = selectedDictionaryHit ?? dictionaryHits.first
        var changed = false

        if gloss.kind == .word {
            if let idx = vocab.firstIndex(where: {
                $0.category == .word
                && $0.word.caseInsensitiveCompare(gloss.source) == .orderedSame
                && (chapterID.isEmpty || $0.chapterID == chapterID)
            }) {
                if vocab[idx].translation != gloss.text || vocab[idx].translationModel != gloss.model {
                    vocab[idx].translation = gloss.text
                    vocab[idx].translationLanguage = gloss.language
                    vocab[idx].translationModel = gloss.model
                    changed = true
                }
                if vocab[idx].definition == nil || DictionaryLookup.looksLikeMarkup(vocab[idx].definition ?? "") {
                    vocab[idx].definition = dict.map { DictionaryLookup.plainPreview(from: $0.preview) }
                    vocab[idx].dictionaryName = dict?.name
                    vocab[idx].dictionaryHTML = DictionaryLookup.optionalDisplayHTML(dict?.html)
                    vocab[idx].sanitizeDictionaryFields()
                    changed = true
                }
            } else {
                vocab.insert(
                    VocabEntry(
                        id: UUID().uuidString,
                        word: gloss.source,
                        category: .word,
                        definition: dict.map { DictionaryLookup.plainPreview(from: $0.preview) },
                        dictionaryName: dict?.name,
                        dictionaryHTML: DictionaryLookup.optionalDisplayHTML(dict?.html),
                        translation: gloss.text,
                        translationLanguage: gloss.language,
                        translationModel: gloss.model,
                        context: original,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.ebookText,
                        bookID: bookID,
                        bookTitle: bookTitle,
                        chapterID: chapterID,
                        chapterTitle: chapterTitle,
                        segmentID: segment?.id,
                        wordID: selectedWord?.id,
                        timestamp: timestamp,
                        addedAt: Date()
                    ),
                    at: 0
                )
                changed = true
            }
        } else {
            if let idx = vocab.firstIndex(where: {
                $0.category == .sentence
                && GlossEntry.normalize($0.context) == GlossEntry.normalize(gloss.source)
                && (chapterID.isEmpty || $0.chapterID == chapterID || $0.chapterID.isEmpty)
            }) {
                vocab[idx].translation = gloss.text
                vocab[idx].translationLanguage = gloss.language
                vocab[idx].translationModel = gloss.model
                changed = true
            } else {
                vocab.insert(
                    VocabEntry(
                        id: UUID().uuidString,
                        word: String(gloss.source.prefix(80)),
                        category: .sentence,
                        definition: nil,
                        translation: gloss.text,
                        translationLanguage: gloss.language,
                        translationModel: gloss.model,
                        context: gloss.source,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.ebookText,
                        bookID: bookID,
                        bookTitle: bookTitle,
                        chapterID: chapterID,
                        chapterTitle: chapterTitle,
                        segmentID: segment?.id,
                        timestamp: timestamp,
                        addedAt: Date()
                    ),
                    at: 0
                )
                changed = true
            }
            for phrase in GlossPhrases.extract(from: gloss.text) {
                if vocab.contains(where: {
                    $0.category == .phrase
                    && $0.word.caseInsensitiveCompare(phrase.phrase) == .orderedSame
                    && GlossEntry.normalize($0.context) == GlossEntry.normalize(gloss.source)
                }) { continue }
                let hits = DictionaryLookup.lookup(phrase.phrase, preferredName: settings.preferredDictionary)
                let hit = hits.first
                vocab.insert(
                    VocabEntry(
                        id: UUID().uuidString,
                        word: phrase.phrase,
                        category: .phrase,
                        definition: hit.map { DictionaryLookup.plainPreview(from: $0.preview) },
                        dictionaryName: hit?.name,
                        dictionaryHTML: DictionaryLookup.optionalDisplayHTML(hit?.html),
                        translation: phrase.meaning,
                        translationLanguage: gloss.language,
                        translationModel: gloss.model,
                        context: gloss.source,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.ebookText,
                        bookID: bookID,
                        bookTitle: bookTitle,
                        chapterID: chapterID,
                        chapterTitle: chapterTitle,
                        segmentID: segment?.id,
                        timestamp: timestamp,
                        addedAt: Date()
                    ),
                    at: 0
                )
                changed = true
            }
        }
        if persist, changed {
            Persistence.saveVocab(vocab)
        }
        return changed
    }

    private func locate(
        bookID: String?,
        bookTitle: String?,
        chapterID: String?,
        chapterTitle: String?
    ) -> (book: Book, chapter: Chapter)? {
        var book: Book?
        if let bookID {
            book = books.first { $0.id == bookID }
        }
        if book == nil, let bookTitle, !bookTitle.isEmpty {
            book = books.first { $0.title.caseInsensitiveCompare(bookTitle) == .orderedSame }
                ?? books.first {
                    $0.title.localizedCaseInsensitiveContains(bookTitle)
                    || bookTitle.localizedCaseInsensitiveContains($0.title)
                }
        }
        guard let book else { return nil }
        let chapter = book.chapters.first { $0.id == chapterID }
            ?? book.chapters.first { $0.title == chapterTitle }
            ?? book.chapters.first { ch in
                guard let chapterTitle else { return false }
                return ch.title.localizedCaseInsensitiveContains(chapterTitle)
            }
            ?? book.chapters.first
        guard let chapter else { return nil }
        return (book, chapter)
    }

    private func applyReveal(_ reveal: PendingReveal) {
        guard let transcript else { return }
        guard let segment = findSegment(in: transcript, reveal: reveal) else { return }
        let word = reveal.kind == .word ? findWord(in: segment, reveal: reveal) : nil
        let time = (word?.start ?? segment.start) + 0.02
        player.seek(time)
        focusedSegmentID = segment.id
        focusedWordID = word?.id
        scrollSegmentID = segment.id
        revealToken += 1
        if let word {
            if textSource == .original {
                textSource = .dual
                persistSettings()
            }
            inspect(word: word)
        } else {
            selectedWord = nil
            dictionaryHits = []
        }
    }

    private func findSegment(in transcript: Transcript, reveal: PendingReveal) -> TranscriptSegment? {
        if let id = reveal.segmentID {
            if let hit = transcript.segments.first(where: { $0.id == id }) { return hit }
        }
        let t = reveal.timestamp
        if t > 0 {
            if let hit = transcript.segments.first(where: { t >= $0.start - 0.02 && t < $0.end + 0.05 }) {
                return hit
            }
        }
        if let sentence = reveal.sentenceText, !sentence.isEmpty {
            let needle = GlossEntry.normalize(sentence)
            if let hit = transcript.segments.first(where: {
                GlossEntry.normalize($0.displayText) == needle
                || GlossEntry.normalize($0.spokenText) == needle
                || GlossEntry.normalize($0.ebookText ?? "").contains(needle)
                || needle.contains(GlossEntry.normalize($0.spokenText))
            }) {
                return hit
            }
        }
        if t > 0 {
            return transcript.segments.min(by: { abs($0.start - t) < abs($1.start - t) })
        }
        return nil
    }

    private func findWord(in segment: TranscriptSegment, reveal: PendingReveal) -> TranscriptWord? {
        if let id = reveal.wordID, let hit = segment.words.first(where: { $0.id == id }) {
            return hit
        }
        if let text = reveal.wordText {
            let head = DictionaryLookup.headword(text).lowercased()
            let matches = segment.words.filter {
                DictionaryLookup.headword($0.text).lowercased() == head
            }
            if matches.count == 1 { return matches[0] }
            if let closest = matches.min(by: { abs($0.start - reveal.timestamp) < abs($1.start - reveal.timestamp) }) {
                return closest
            }
        }
        if reveal.timestamp > 0 {
            return segment.words.min(by: { abs($0.start - reveal.timestamp) < abs($1.start - reveal.timestamp) })
        }
        return segment.words.first
    }

    func chooseLibrary() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.libraryPath)
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder that contains your audiobook + ebook collections."
        if panel.runModal() == .OK, let url = panel.url {
            settings.libraryPath = url.path
            persistSettings()
            Task { await rescan() }
        }
#else
        errorMessage = "Use Import on iPad to choose audiobook files or a folder."
#endif
    }
}

private struct PendingReveal {
    var kind: TextRevealKind
    var timestamp: TimeInterval
    var segmentID: String?
    var wordID: String?
    var wordText: String?
    var sentenceText: String?
}
