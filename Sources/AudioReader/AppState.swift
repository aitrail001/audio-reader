import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif
#if canImport(AudioReaderNetworking)
import AudioReaderNetworking
#endif

@MainActor
@Observable
final class AppState {
    var settings: AppSettings
    var books: [Book] = []
    var selectedBookID: String?
    var selectedChapterID: String?
    var transcript: Transcript? {
        didSet {
            transcriptionLanguageMismatch = TranscriptionLanguageMismatchDetector.detect(in: transcript)
            refreshStudyIndex()
        }
    }
    var transcriptionLanguageMismatch: TranscriptionLanguageMismatch?
    var vocab: [VocabEntry] = [] {
        didSet { refreshStudyIndex() }
    }
    var knownLemmas: [KnownLemmaRecord] = [] {
        didSet { refreshStudyIndex() }
    }
    private(set) var studyIndex = StudyIndex.empty
    var chapterStudyPresentation: ChapterStudyPresentation?
    var shadowingSegment: TranscriptSegment?
    var chapterQuizSession: ChapterQuizSession?
    var studyActivityLog = StudyActivityLog.empty
    var appleIntelligenceAvailability: AppleIntelligenceAvailability = .unavailable("Not checked")
    var tab: AppTab = .library
    var textSource: TextSource = .spoken
    var player = PlayerEngine()

    var isScanning = false
    var libraryScanProgress: LibraryScanProgress?
    var readyChapterIDs: Set<String> = []
    var isTranscribing = false
    var isRecheckingEbook = false
    var transcriptionProgress: TranscriptionProgress?
    var transcriptionJobOrigin: BackgroundJobOrigin?
    var backgroundJobNavigationError: String?
    var errorMessage: String?
    var selectedWord: TranscriptWord?
    var definition: String?
    var dictionaryHits: [DictionaryHit] = []
    var selectedDictionaryName: String = ""
    var loopSentence = false
    private(set) var playingVocabEntryID: String?
    private(set) var deepReadingActiveSentenceID: String?
    private(set) var deepReadingPausedSentenceID: String?
    var glosses: [GlossEntry] = [] {
        didSet { chapterGlossGeneration &+= 1 }
    }
    var chapterTranslationCheckpoints: [ChapterTranslationCheckpoint] = []
    var isTranslating = false
    var translationError: String?
    var vocabularyNotice: String?
    var showSettings = false
    var account: AccountSession
    var credentialMigrationWarning: String?
    var codexLoginStatus = "Codex login status not checked"
    var isCheckingCodexLogin = false
    var grokModels = GrokModelCatalog.fallback
    var isLoadingGrokModels = false
    var grokModelsMessage: String?
    var qwenModels = QwenModelCatalog.fallback
    var isLoadingQwenModels = false
    var qwenModelsMessage: String?
    var openAIModels = OpenAIModelCatalog.fallback
    var isLoadingOpenAIModels = false
    var openAIModelsMessage: String?
    var showChapterAssistant = false
    var chapterTranslation: String?
    var chapterTranslationProgress: LibraryScanProgress?
    var chapterAcceptanceProgress: LibraryScanProgress?
    var chapterTranslationJobOrigin: BackgroundJobOrigin?
    var chapterSummary: ChapterSummaryRecord?
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
    @ObservationIgnored private var chapterSummaries: [ChapterSummaryRecord] = []
    @ObservationIgnored private var chapterChatsByChapterID: [String: [LLMChatMessage]] = [:]
    @ObservationIgnored private var chapterAssistantErrorsByChapterID: [String: String] = [:]
    @ObservationIgnored private var chapterAcceptanceID: UUID?
    @ObservationIgnored private var credentialMigrationSession = LegacyCredentialMigrationSession()
    @ObservationIgnored private let vocabularyRepository: any VocabularyRepository
    @ObservationIgnored private let knownLemmaRepository: any KnownLemmaRepository
    @ObservationIgnored private let usesLivePersistence: Bool

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
        let cursor = PlaybackCursor.resolve(segments: transcript.segments, time: player.currentTime)
        return (cursor.segment, cursor.word)
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

    var readerLanguageLevel: ReaderLanguageLevel {
        ReaderLanguageLevel(rawValue: settings.readerLanguageLevel) ?? .intermediate
    }

    var currentAudiobookLanguage: TranscriptionLanguage {
        if let transcript,
           let transcriptLanguage = TranscriptionLanguage.matching(localeIdentifier: transcript.locale) {
            return transcriptLanguage
        }
        return audiobookLanguage(for: selectedBook)
    }

    func audiobookLanguage(for book: Book?) -> TranscriptionLanguage {
        if let book,
           let rawValue = settings.bookTranscriptionLanguages[book.id],
           let language = TranscriptionLanguage(rawValue: rawValue) {
            return language
        }
        return TranscriptionLanguage(rawValue: settings.transcriptionLanguage) ?? .englishUS
    }

    func setAudiobookLanguage(_ language: TranscriptionLanguage, for book: Book) {
        settings.bookTranscriptionLanguages[book.id] = language.rawValue
        persistSettings()
        refreshStudyIndex()
    }

    func useSuggestedTranscriptionLanguage(_ language: TranscriptionLanguage) {
        guard let book = selectedBook else { return }
        setAudiobookLanguage(language, for: book)
        transcriptionLanguageMismatch = nil
        transcribeSelected(force: true)
    }

    func dismissTranscriptionLanguageMismatch() {
        transcriptionLanguageMismatch = nil
    }

    var llmProvider: LLMProvider {
        LLMProvider(rawValue: settings.llmProvider) ?? .grok
    }

    var selectedLLMModel: String {
        switch llmProvider {
        case .grok: settings.grokModel
        case .qwenCloud: settings.qwenModel
        case .openAI: settings.openAIModel
        case .appleFoundation: "Apple Intelligence"
        }
    }

    var openAIAuthentication: OpenAIAuthentication {
        OpenAIAuthentication(rawValue: settings.openAIAuthentication) ?? .chatGPT
    }

    var grokAuthentication: GrokAuthentication {
        GrokAuthentication(rawValue: settings.grokAuthentication) ?? .grokBuild
    }

    var selectedLLMConnection: LLMConnectionChoice {
        get { LLMConnectionChoice.selected(in: settings) }
        set { newValue.apply(to: &settings) }
    }

    var selectedLLMEffort: String {
        switch llmProvider {
        case .grok: settings.grokEffort
        case .qwenCloud: settings.qwenEffort
        case .openAI: settings.openAIEffort
        case .appleFoundation: ""
        }
    }

    var vocabReviewPrompt: VocabReviewPrompt {
        get { VocabReviewPrompt(rawValue: settings.vocabReviewPrompt) ?? .recognition }
        set {
            settings.vocabReviewPrompt = newValue.rawValue
            persistSettings()
        }
    }

    var studyLexiconLanguage: String {
        StudyTokenIndex.languageKey(for: currentAudiobookLanguage)
    }

    var chapterCoverage: ChapterCoverage { studyIndex.coverage }

    var chapterStudyItems: [ChapterStudyItem] { studyIndex.priming }

    func refreshStudyIndex() {
        studyIndex = StudyIndex.build(
            segments: transcript?.segments ?? [],
            language: studyLexiconLanguage,
            vocab: vocab,
            knownRecords: knownLemmas
        )
    }

    func presentChapterStudyList() {
        refreshStudyIndex()
        chapterStudyPresentation = ChapterStudyPresentation(
            id: selectedChapterID ?? transcript?.chapterID ?? "chapter",
            chapterTitle: selectedChapter?.title ?? "Chapter words",
            coverage: studyIndex.coverage,
            items: studyIndex.priming,
            hasTranscript: transcript != nil
        )
    }

    func presentShadowing(for segment: TranscriptSegment? = nil) {
        let target = segment
            ?? transcript?.segments.first(where: { $0.id == focusedSegmentID })
            ?? currentSegment
        shadowingSegment = target
        if target != nil {
            player.pause()
        }
    }

    func presentChapterQuiz() {
        guard let transcript, !transcript.segments.isEmpty else { return }
        let quiz = ChapterQuizBuilder.build(
            segments: transcript.segments,
            language: studyLexiconLanguage
        )
        guard !quiz.questions.isEmpty else { return }
        chapterQuizSession = ChapterQuizSession(quiz: quiz)
    }

    func recordStudyActivity(now: Date = Date()) {
        studyActivityLog = studyActivityLog.recording(on: now)
        guard usesLivePersistence else { return }
        Persistence.saveStudyActivityLog(studyActivityLog)
    }

    func refreshAppleIntelligenceAvailability() {
        appleIntelligenceAvailability = AppleIntelligenceAvailability.current()
    }

    func familiarity(for word: TranscriptWord) -> WordFamiliarity {
        studyIndex.familiarity(for: word.text)
    }

    func isMarkedKnown(_ word: TranscriptWord) -> Bool {
        guard let lemma = StudyLemma.make(language: studyLexiconLanguage, surface: word.text) else { return false }
        return studyIndex.known.contains(lemma)
    }

    func markKnown(lemma: StudyLemma, known: Bool) {
        knownLemmas = known
            ? KnownLemmaStore.upsert(lemma, into: knownLemmas)
            : KnownLemmaStore.remove(lemma, from: knownLemmas)
        persistKnownLemmas()
        if chapterStudyPresentation != nil {
            chapterStudyPresentation = ChapterStudyPresentation(
                id: selectedChapterID ?? transcript?.chapterID ?? chapterStudyPresentation?.id ?? "chapter",
                chapterTitle: selectedChapter?.title ?? chapterStudyPresentation?.chapterTitle ?? "Chapter words",
                coverage: studyIndex.coverage,
                items: studyIndex.priming,
                hasTranscript: transcript != nil
            )
        }
    }

    func markKnown(_ word: TranscriptWord, known: Bool) {
        guard let lemma = StudyLemma.make(language: studyLexiconLanguage, surface: word.text) else { return }
        markKnown(lemma: lemma, known: known)
    }

    func markSelectedWordKnown(_ known: Bool = true) {
        guard let word = selectedWord else { return }
        markKnown(word, known: known)
    }

    func llmConfigurationError(for provider: LLMProvider) -> LLMError? {
        switch provider {
        case .grok:
            grokAuthentication == .grokBuild
                ? (GrokBuildCredentialProvider.load() == nil ? .grokBuildNotLoggedIn : nil)
                : (APIKeyStore.isConfigured ? nil : .noAPIKey(provider))
        case .qwenCloud:
            QwenAPIKeyStore.isConfigured ? nil : .noAPIKey(provider)
        case .appleFoundation:
            appleIntelligenceConfigurationError()
        case .openAI:
            openAIAuthentication == .chatGPT
                ? (CodexCLIClient.isAvailable ? nil : .codexUnavailable)
                : (OpenAIAPIKeyStore.isConfigured ? nil : .noAPIKey(provider))
        }
    }

    private func appleIntelligenceConfigurationError() -> LLMError? {
        let availability = AppleIntelligenceAvailability.current()
        appleIntelligenceAvailability = availability
        guard availability.isReady else {
            return .appleIntelligenceUnavailable(availability.userMessage)
        }
        return nil
    }

    func refreshCodexLoginStatus() async {
        isCheckingCodexLogin = true
        codexLoginStatus = await CodexCLIClient.shared.loginStatus()
        isCheckingCodexLogin = false
    }

    var qwenTextModels: [LLMModelInfo] {
        selectableModels(qwenModels, selectedID: settings.qwenModel)
    }

    var grokTextModels: [LLMModelInfo] {
        selectableModels(grokModels, selectedID: settings.grokModel)
    }

    var openAITextModels: [LLMModelInfo] {
        selectableModels(openAIModels, selectedID: settings.openAIModel)
    }

    var selectedGrokEfforts: [GrokEffort] {
        GrokRequestPolicy.supportedEfforts(model: settings.grokModel)
    }

    var selectedOpenAIEfforts: [OpenAIEffort] {
        if openAIAuthentication == .chatGPT { return OpenAIEffort.allCases }
        return OpenAIRequestPolicy.supportedAPIEfforts(model: settings.openAIModel)
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

    func normalizeSelectedGrokEffort() {
        let supported = selectedGrokEfforts
        guard !supported.isEmpty,
              !supported.contains(where: { $0.rawValue == settings.grokEffort })
        else { return }
        settings.grokEffort = supported.contains(.medium) ? GrokEffort.medium.rawValue : supported[0].rawValue
        persistSettings()
    }

    func normalizeSelectedOpenAIEffort() {
        let supported = selectedOpenAIEfforts
        guard !supported.isEmpty,
              !supported.contains(where: { $0.rawValue == settings.openAIEffort })
        else { return }
        settings.openAIEffort = supported.contains(.medium) ? OpenAIEffort.medium.rawValue : supported[0].rawValue
        persistSettings()
    }

    private func selectableModels(_ models: [LLMModelInfo], selectedID: String) -> [LLMModelInfo] {
        var selectable = models.filter(\.supportsText)
        if !selectable.contains(where: { $0.id == selectedID }) {
            selectable.append(.init(id: selectedID, brand: "Custom", capabilities: "Custom model ID", supportsText: true))
        }
        return selectable.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
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

    var currentBookIsMissingEbook: Bool {
        selectedBook != nil && selectedBook?.ebookPath == nil
    }

    var currentEbookAlignment: EPUBAlignmentAssessment? {
        guard selectedBook?.ebookPath != nil else { return nil }
        if let assessment = transcript?.ebookAlignment { return assessment }
        if transcript == nil {
            return EPUBAlignmentAssessment(
                status: .uncertain,
                reason: "This EPUB has not been validated. Transcribe a chapter to check it before EPUB text is used.",
                metrics: .empty
            )
        }
        return EPUBAlignmentAssessment(
            status: .uncertain,
            reason: "This saved transcript predates document-level EPUB validation. Re-transcribe to assess it safely.",
            metrics: .empty
        )
    }

    var canUseCurrentEbookAnyway: Bool {
        guard let transcript,
              transcript.ebookAlignment != nil,
              transcript.ebookUseOverride != true
        else { return false }
        return transcript.alignmentStatus != .trusted
            && transcript.alignmentStatus != .unprocessable
    }

    func useCurrentEbookAnyway() {
        guard var transcript, let book = selectedBook, let ebookPath = book.ebookPath else { return }
        guard transcript.alignmentStatus != .unprocessable else {
            errorMessage = "This EPUB has no readable text. Replace it before using EPUB wording."
            return
        }
        if transcript.alignmentStatus == .wrongBookLikely,
           !transcript.segments.contains(where: { $0.individualEbookMatchTrusted == true }) {
            let spokenOnly = transcript.segments.map { segment -> TranscriptSegment in
                var copy = segment
                copy.ebookText = nil
                copy.alignmentScore = nil
                copy.individualEbookMatchTrusted = nil
                copy.documentEbookUseAllowed = nil
                return copy
            }
            let result = Aligner.align(
                segments: spokenOnly,
                document: EPUBParser.document(from: ebookPath),
                expectedMetadata: .init(title: book.title, author: book.author),
                continueAfterWrongBookPreflight: true
            )
            transcript.segments = result.segments
            transcript.ebookAlignment = result.assessment
        }
        transcript.allowEbookTextAnyway()
        guard transcript.ebookAligned else {
            errorMessage = "No sufficiently strong sentence matches were found in this EPUB."
            return
        }
        do {
            try Persistence.saveTranscript(transcript)
            self.transcript = transcript
        } catch {
            errorMessage = "Could not save the EPUB override: \(error.localizedDescription)"
        }
    }

    func recheckCurrentEbookAlignment() async {
        guard !isRecheckingEbook,
              let book = selectedBook,
              let ebookPath = book.ebookPath,
              var saved = transcript
        else { return }

        isRecheckingEbook = true
        defer { isRecheckingEbook = false }
        errorMessage = nil

        let spokenOnly = saved.segments.map { segment -> TranscriptSegment in
            var copy = segment
            copy.ebookText = nil
            copy.alignmentScore = nil
            copy.individualEbookMatchTrusted = nil
            copy.documentEbookUseAllowed = false
            return copy
        }
        let expectedMetadata = EPUBBookMetadata(title: book.title, author: book.author)
        let result = await Task.detached(priority: .userInitiated) {
            Aligner.align(
                segments: spokenOnly,
                document: EPUBParser.document(from: ebookPath),
                expectedMetadata: expectedMetadata
            )
        }.value

        saved.segments = result.segments
        saved.ebookAlignment = result.assessment
        saved.ebookUseOverride = false
        saved.ebookAligned = result.segments.contains { $0.trustedEbookText != nil }
        do {
            try Persistence.saveTranscript(saved)
            if selectedChapterID == saved.chapterID {
                transcript = saved
            }
        } catch {
            errorMessage = "Could not save the updated EPUB alignment: \(error.localizedDescription)"
        }
    }

    func replaceCurrentEbook(with source: URL) throws {
        guard let book = selectedBook else { return }
        guard AudiobookImportService.isReadableEbook(source) else {
            throw AudiobookImportError.invalidEbook
        }
        let replacement = try AudiobookImportService.stageEbookReplacement(
            source,
            in: URL(fileURLWithPath: book.folderPath, isDirectory: true)
        )
        let assessment = EPUBAlignmentAssessment(
            status: .uncertain,
            reason: "The EPUB changed. Select Recheck EPUB to validate it against the saved transcript.",
            metrics: .empty
        )
        let originals = book.chapters.compactMap { Persistence.loadTranscript(for: $0) }
        var invalidated: [Transcript] = []
        do {
            for original in originals {
                var saved = original
                invalidateEbookText(in: &saved, assessment: assessment)
                try Persistence.saveTranscript(saved)
                invalidated.append(saved)
            }
            replacement.commit()
        } catch {
            var rollbackFailures: [String] = []
            do {
                try replacement.rollback()
            } catch {
                rollbackFailures.append("file rollback failed: \(error.localizedDescription)")
            }
            for original in originals {
                do {
                    try Persistence.saveTranscript(original)
                } catch {
                    rollbackFailures.append(
                        "transcript \(original.chapterID) rollback failed: \(error.localizedDescription)"
                    )
                }
            }
            if let current = originals.first(where: { $0.chapterID == transcript?.chapterID }) {
                transcript = current
            }
            if !rollbackFailures.isEmpty {
                throw AudiobookImportError.replacementRollbackFailed(
                    rollbackFailures.joined(separator: "; ")
                )
            }
            throw error
        }
        if let current = invalidated.first(where: { $0.chapterID == transcript?.chapterID }) {
            transcript = current
        }
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index].ebookPath = replacement.destination.path
        }
    }

    private func invalidateEbookText(
        in transcript: inout Transcript,
        assessment: EPUBAlignmentAssessment
    ) {
        transcript.ebookAligned = false
        transcript.ebookUseOverride = false
        transcript.ebookAlignment = assessment
        for index in transcript.segments.indices {
            transcript.segments[index].ebookText = nil
            transcript.segments[index].alignmentScore = nil
            transcript.segments[index].individualEbookMatchTrusted = nil
            transcript.segments[index].documentEbookUseAllowed = nil
        }
    }

    init(composition: AppComposition = .live, account: AccountSession? = nil) {
        vocabularyRepository = composition.vocabulary
        knownLemmaRepository = composition.knownLemmas
        usesLivePersistence = composition.usesLivePersistence
        if let account {
            self.account = account
        } else if usesLivePersistence {
            self.account = AccountSession.live()
        } else {
            self.account = AccountSession.isolated()
        }
        if usesLivePersistence {
            settings = Persistence.loadSettings()
#if os(iOS)
            // iOS data-container UUIDs can change after reinstalling an app, so a
            // persisted absolute Documents path must never drive library scanning.
            settings.libraryPath = Persistence.importedBooksURL.path
            settings.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue
            settings.grokAuthentication = GrokAuthentication.apiKey.rawValue
            if let normalizedDictionary = DictionaryLookup.recommendedName(
                language: StudyLanguage(rawValue: settings.targetLanguage) ?? .zhHans,
                installedNames: DictionaryLookup.installedNames()
            ), settings.preferredDictionary != normalizedDictionary {
                settings.preferredDictionary = normalizedDictionary
                Persistence.saveSettings(settings)
            }
#endif
        } else {
            settings = .default
        }
        vocab = ((try? vocabularyRepository.loadVocabulary()) ?? []).map { stored in
            var copy = VocabEntry(stored)
            copy.sanitizeDictionaryFields()
            return copy
        }
        knownLemmas = ((try? knownLemmaRepository.loadKnownLemmas()) ?? []).map(KnownLemmaRecord.init)
        appleIntelligenceAvailability = AppleIntelligenceAvailability.current()
        if usesLivePersistence {
            studyActivityLog = Persistence.loadStudyActivityLog()
            glosses = Persistence.loadGlosses()
            chapterTranslationCheckpoints = Persistence.loadChapterTranslationCheckpoints()
            chapterSummaries = Persistence.loadChapterSummaries()
        }
        selectedDictionaryName = settings.preferredDictionary
        if let raw = TextSource(rawValue: settings.textSource) {
            textSource = raw
        }
        player.rate = Float(settings.playbackRate)
        guard usesLivePersistence else { return }
        importGlossesIntoVocab()
        if vocab.contains(where: { DictionaryLookup.looksLikeMarkup($0.definition ?? "") }) {
            persistVocabulary()
        }
        migrateLegacyProviderCredentials()
    }

    func boot() async {
        await account.restore()
        await rescan()
        if let first = books.first {
            selectedBookID = first.id
            selectedChapterID = first.chapters.first?.id
        }
        if llmProvider == .openAI, openAIAuthentication == .chatGPT {
            Task { await self.refreshCodexLoginStatus() }
        }
    }

    func migrateLegacyProviderCredentials() {
        var results: [LegacyCredentialMigrationResult]?
        credentialMigrationSession.runOnce {
            results = APIKeyStore.migrateLegacyCredential()
                + QwenAPIKeyStore.migrateLegacyCredential()
                + OpenAIAPIKeyStore.migrateLegacyCredential()
        }
        if let results {
            credentialMigrationWarning = results.contains(.failed)
                ? "An older saved API key could not be moved to the encrypted local vault. AudioReader will not use the older copy; re-enter the key in API settings."
                : nil
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
        migrateVocabularySourceLanguages()
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

    private func migrateVocabularySourceLanguages() {
        let migrated = VocabSourceLanguageMigration.migrated(vocab, books: books) { book in
            StudyTokenIndex.languageKey(for: audiobookLanguage(for: book))
        }
        guard migrated != vocab else { return }
        vocab = migrated
        persistVocabulary()
        refreshStudyIndex()
    }

    func open(chapter: Chapter, in book: Book, autoplay: Bool) {
        selectedBookID = book.id
        selectedChapterID = chapter.id
        tab = .player
        player.load(path: chapter.audioPath, startTime: chapter.audioStart, duration: chapter.duration)
        deepReadingActiveSentenceID = nil
        deepReadingPausedSentenceID = nil
        player.rate = Float(settings.playbackRate)
        transcript = Persistence.loadTranscript(for: chapter)
        chapterTranslation = nil
        chapterSummary = chapterSummaries.first {
            $0.id == ChapterSummaryRecord.makeID(
                chapterID: chapter.id,
                language: settings.targetLanguage
            ) && $0.status != .rejected
        }
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
                    expectedMetadata: .init(title: book.title, author: book.author),
                    language: audiobookLanguage(for: book),
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
                    aligned: result.ebookAligned,
                    ebookAlignment: result.ebookAlignment
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
        aligned: Bool,
        ebookAlignment: EPUBAlignmentAssessment? = nil
    ) -> Bool {
        let transcript = Transcript(
            chapterID: chapter.id,
            audioPath: chapter.audioPath,
            chapterStart: chapter.startTime,
            createdAt: Date(),
            locale: locale,
            segments: segments,
            source: "SpeechAnalyzer",
            ebookAligned: aligned,
            ebookAlignment: ebookAlignment
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
        if player.isPlaying {
            player.pause()
        } else if settings.deepReadingMode, deepReadingPausedSentenceID != nil {
            continueDeepReading()
        } else {
            armDeepReadingSentence()
            player.play()
        }
    }

    func skipSentence(direction: Int) {
        guard let transcript, let current = currentSegment else {
            player.skip(seconds: Double(direction) * settings.skipSeconds)
            resetDeepReadingAfterSeek()
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
        resetDeepReadingAfterSeek()
    }

    func replaySentence() {
        if let current = currentSegment {
            player.seek(current.start)
            armDeepReadingSentence(current)
            player.play()
        }
    }

    var canContinueDeepReading: Bool {
        guard settings.deepReadingMode,
              let transcript,
              let sentenceID = deepReadingPausedSentenceID,
              let index = transcript.segments.firstIndex(where: { $0.id == sentenceID })
        else { return false }
        return transcript.segments.indices.contains(index + 1)
    }

    var isDeepReadingPaused: Bool {
        settings.deepReadingMode && deepReadingPausedSentenceID != nil
    }

    func setDeepReadingMode(_ enabled: Bool) {
        guard settings.deepReadingMode != enabled else { return }
        settings.deepReadingMode = enabled
        if enabled {
            loopSentence = false
            if player.isPlaying { armDeepReadingSentence() }
        } else {
            deepReadingActiveSentenceID = nil
            deepReadingPausedSentenceID = nil
        }
        persistSettings()
    }

    func setSentenceLoop(_ enabled: Bool) {
        loopSentence = enabled
        if enabled, settings.deepReadingMode {
            setDeepReadingMode(false)
        }
    }

    func seekToSentence(_ sentence: TranscriptSegment, time: TimeInterval, autoplay: Bool) {
        player.seek(time)
        armDeepReadingSentence(sentence)
        if autoplay, !player.isPlaying { player.play() }
    }

    func seekPlayback(to time: TimeInterval) {
        player.seek(time)
        resetDeepReadingAfterSeek()
    }

    func skipPlayback(seconds: TimeInterval) {
        player.skip(seconds: seconds)
        resetDeepReadingAfterSeek()
    }

    func continueDeepReading() {
        guard settings.deepReadingMode,
              let transcript,
              let sentenceID = deepReadingPausedSentenceID,
              let index = transcript.segments.firstIndex(where: { $0.id == sentenceID }),
              transcript.segments.indices.contains(index + 1)
        else { return }
        let next = transcript.segments[index + 1]
        player.seek(next.start)
        armDeepReadingSentence(next)
        player.play()
    }

    func tickPlaybackModes() {
        if loopSentence, let current = currentSegment,
           player.currentTime >= current.end - 0.04 {
            player.seek(current.start)
            player.play()
            return
        }
        guard settings.deepReadingMode, player.isPlaying, let transcript else { return }
        if deepReadingActiveSentenceID == nil {
            armDeepReadingSentence()
        }
        guard let sentenceID = deepReadingActiveSentenceID,
              let sentence = transcript.segments.first(where: { $0.id == sentenceID }),
              player.currentTime >= sentence.end - 0.04
        else { return }
        player.pause()
        player.seek(max(sentence.start, sentence.end - 0.06))
        deepReadingActiveSentenceID = nil
        deepReadingPausedSentenceID = sentence.id
    }

    private func armDeepReadingSentence(_ sentence: TranscriptSegment? = nil) {
        guard settings.deepReadingMode, let sentence = sentence ?? currentSegment else {
            deepReadingActiveSentenceID = nil
            deepReadingPausedSentenceID = nil
            return
        }
        deepReadingActiveSentenceID = sentence.id
        deepReadingPausedSentenceID = nil
    }

    private func resetDeepReadingAfterSeek() {
        deepReadingPausedSentenceID = nil
        if settings.deepReadingMode, player.isPlaying {
            armDeepReadingSentence()
        } else {
            deepReadingActiveSentenceID = nil
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
            sourceLanguage: StudyTokenIndex.languageKey(for: audiobookLanguage(for: book)),
            context: segment.displayText,
            spokenText: segment.spokenText,
            ebookText: segment.trustedEbookText,
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
        persistVocabulary()
        vocabularyNotice = "Added “\(head)” to your vocabulary."
    }

    func removeVocab(_ entry: VocabEntry) {
        vocab.removeAll { $0.id == entry.id }
        persistVocabulary()
    }

    func setVocabularyLearnList(_ entryID: String, included: Bool) {
        guard let index = vocab.firstIndex(where: { $0.id == entryID }) else { return }
        vocab[index].isInLearnList = included
        persistVocabularyUpdates([vocab[index]])
    }

    func reviewVocabulary(
        _ entryID: String,
        quality: VocabReviewQuality,
        at date: Date = Date()
    ) {
        guard let index = vocab.firstIndex(where: { $0.id == entryID }) else { return }
        vocab[index] = VocabReviewScheduler.applying(quality, to: vocab[index], at: date)
        persistVocabularyUpdates([vocab[index]])
    }

    func canPlayVocabSentence(_ entry: VocabEntry) -> Bool {
        locate(
            bookID: entry.bookID,
            bookTitle: entry.bookTitle,
            chapterID: entry.chapterID,
            chapterTitle: entry.chapterTitle
        ) != nil
    }

    @discardableResult
    func playVocabSentence(_ entry: VocabEntry) -> Bool {
        guard let located = locate(
            bookID: entry.bookID,
            bookTitle: entry.bookTitle,
            chapterID: entry.chapterID,
            chapterTitle: entry.chapterTitle
        ) else {
            errorMessage = "Could not find “\(entry.bookTitle)” in the library."
            return false
        }
        let transcript = Persistence.loadTranscript(for: located.chapter)
        let bounds = VocabSentencePlayback.bounds(for: entry, transcript: transcript)
        if player.loadedPath != located.chapter.audioPath {
            player.load(
                path: located.chapter.audioPath,
                startTime: located.chapter.audioStart,
                duration: located.chapter.duration
            )
        }
        playingVocabEntryID = entry.id
        player.playClip(from: bounds.start, to: bounds.end)
        if let playbackError = player.playbackError {
            errorMessage = playbackError
            playingVocabEntryID = nil
            return false
        }
        return true
    }

    func toggleVocabSentencePlayback(_ entry: VocabEntry) {
        if playingVocabEntryID == entry.id, player.isPlaying {
            stopVocabSentencePlayback()
            return
        }
        _ = playVocabSentence(entry)
    }

    func stopVocabSentencePlayback() {
        guard playingVocabEntryID != nil else { return }
        player.pause()
        playingVocabEntryID = nil
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
        let language = studyLanguage
        let text = word.text
        let wordID = word.id
        Task.detached(priority: .userInitiated) {
            let hits = DictionaryLookup.lookup(text, preferredName: preferred, language: language)
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
        guard usesLivePersistence else { return }
        Persistence.saveSettings(settings)
    }

    private func persistKnownLemmas() {
        try? knownLemmaRepository.saveKnownLemmas(knownLemmas.map(StoredKnownLemma.init))
    }

    private func persistVocabulary() {
        try? vocabularyRepository.saveVocabulary(vocab.map(StoredVocabularyOccurrence.init))
    }

    private func persistVocabularyUpdates(_ updates: [VocabEntry]) {
        try? vocabularyRepository.upsertVocabulary(updates.map(StoredVocabularyOccurrence.init))
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

    func refreshGrokModels() async {
        guard let models = await retrieveGrokModels(baseURL: settings.grokEndpoint, apiKey: nil) else { return }
        if let replacement = preferredModel(in: models, current: settings.grokModel, preferred: "grok-4.6") {
            settings.grokModel = replacement
        }
        normalizeSelectedGrokEffort()
        persistSettings()
    }

    @discardableResult
    func retrieveGrokModels(baseURL: String, apiKey: String?) async -> [LLMModelInfo]? {
        grokModels = GrokModelCatalog.fallback
        let supplied = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supplied?.isEmpty == false || APIKeyStore.isConfigured else {
            grokModelsMessage = "Using the built-in xAI model catalog until an API key is configured."
            return nil
        }
        isLoadingGrokModels = true
        grokModelsMessage = nil
        defer { isLoadingGrokModels = false }
        do {
            let discovered = try await GrokClient.shared.providerModels(provider: .grok, baseURL: baseURL, apiKey: apiKey)
            let compatible = GrokModelCatalog.discovered(discovered)
            guard !compatible.isEmpty else {
                grokModelsMessage = "xAI returned no compatible language models; using the built-in catalog."
                return nil
            }
            grokModels = compatible
            grokModelsMessage = "Loaded \(compatible.count) language models from xAI."
            return grokModels
        } catch {
            grokModelsMessage = "Model discovery failed; using the built-in catalog. \(error.localizedDescription)"
            return nil
        }
    }

    func refreshOpenAIModels() async {
        guard let models = await retrieveOpenAIModels(baseURL: settings.openAIEndpoint, apiKey: nil) else { return }
        if let replacement = preferredModel(in: models, current: settings.openAIModel, preferred: "gpt-5.6-luna") {
            settings.openAIModel = replacement
        }
        normalizeSelectedOpenAIEffort()
        persistSettings()
    }

    @discardableResult
    func retrieveOpenAIModels(baseURL: String, apiKey: String?) async -> [LLMModelInfo]? {
        openAIModels = OpenAIModelCatalog.fallback
        let supplied = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supplied?.isEmpty == false || OpenAIAPIKeyStore.isConfigured else {
            openAIModelsMessage = "Using the built-in OpenAI model catalog until an API key is configured."
            return nil
        }
        isLoadingOpenAIModels = true
        openAIModelsMessage = nil
        defer { isLoadingOpenAIModels = false }
        do {
            let discovered = try await GrokClient.shared.providerModels(provider: .openAI, baseURL: baseURL, apiKey: apiKey)
            let compatible = OpenAIModelCatalog.discovered(discovered)
            guard !compatible.isEmpty else {
                openAIModelsMessage = "OpenAI returned no compatible text models; using the built-in catalog."
                return nil
            }
            openAIModels = compatible
            openAIModelsMessage = "Loaded \(compatible.count) text models from OpenAI."
            return openAIModels
        } catch {
            openAIModelsMessage = "Model discovery failed; using the built-in catalog. \(error.localizedDescription)"
            return nil
        }
    }

    private func preferredModel(in models: [LLMModelInfo]?, current: String, preferred: String) -> String? {
        guard let selectable = models?.filter(\.supportsText),
              !selectable.contains(where: { $0.id == current })
        else { return nil }
        return selectable.first(where: { $0.id == preferred })?.id ?? selectable.first?.id
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
        persistVocabulary()
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
        if let configurationError = llmConfigurationError(for: provider) {
            translationError = configurationError.localizedDescription
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
        let sourceLanguage = currentAudiobookLanguage
        let readerLevel = readerLanguageLevel
        let model = selectedLLMModel
        let baseURL = settings.endpoint(for: provider)
        let effort = selectedLLMEffort
        let enableThinking = settings.qwenThinking
        let sentenceContextCount = settings.sentenceContextCount
        let openAIAuthentication = self.openAIAuthentication
        let grokAuthentication = self.grokAuthentication
        let book = selectedBook
        let chapter = selectedChapter
        let origin = selectedOrigin()
        let jobKind: BackgroundJob.Kind = kind == .sentence ? .sentenceTranslation : .wordTranslation
        guard !llmJobQueue.jobs.contains(where: {
            $0.kind == jobKind && $0.chapterID == origin.chapterID && $0.targetID == targetID
        }) else { return }
        let metadata = bookMetadata(book: book, chapter: chapter)
        let capturedTranscript = transcript
        let prompt: LLMTaskPrompt
        if kind == .sentence {
            let translationContext = segment.map {
                ReadingAssistantPrompt.sentenceContext(
                    around: [$0],
                    in: capturedTranscript,
                    radius: sentenceContextCount
                )
            } ?? "TARGET id=\(targetID): \(trimmed)"
            prompt = ReadingAssistantPrompt.sentenceTranslation(
                language: language,
                sourceLanguage: sourceLanguage,
                readerLevel: readerLevel,
                metadata: metadata,
                context: translationContext,
                targetIDs: [targetID]
            )
        } else {
            prompt = LLMTaskPrompt(
                system: ReadingAssistantPrompt.word(
                    language: language,
                    sourceLanguage: sourceLanguage,
                    readerLevel: readerLevel
                ),
                user: "Word: \(trimmed)\nSentence: \(context ?? trimmed)"
            )
        }
        enqueueLLMJob(
            kind: jobKind,
            origin: origin,
            targetID: targetID,
            detail: "Requesting \(model)…"
        ) { _ in
            do {
                let text: String
                if kind == .sentence {
                    let raw = try await GrokClient.shared.completeStructuredJSON(
                        provider: provider,
                        system: prompt.system,
                        user: prompt.user,
                        baseURL: baseURL,
                        model: model,
                        effort: effort,
                        enableThinking: enableThinking,
                        grokAuthentication: grokAuthentication,
                        openAIAuthentication: openAIAuthentication
                    )
                    guard let result = try ChapterTranslationBatch.parse(
                        raw,
                        expectedIDs: [targetID]
                    ).first else {
                        throw ChapterTranslationBatchError.missingSentences
                    }
                    text = result.glossText
                } else {
                    text = try await GrokClient.shared.complete(
                        provider: provider,
                        system: prompt.system,
                        user: prompt.user,
                        baseURL: baseURL,
                        model: model,
                        effort: effort,
                        enableThinking: enableThinking,
                        grokAuthentication: grokAuthentication,
                        openAIAuthentication: openAIAuthentication
                    )
                }
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
        let sourceLanguage = currentAudiobookLanguage
        let readerLevel = readerLanguageLevel
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
        if let configurationError = llmConfigurationError(for: provider) {
            chapterAssistantError = configurationError.localizedDescription
            showSettings = true
            return
        }
        let blocks = ChapterTranslationBatch.blocks(
            pendingSegments,
            size: FoundationModelsPromptPolicy.chapterTranslationBlockSize(
                for: provider,
                requested: settings.chapterTranslationBlockSize
            )
        )
        let total = pendingSegments.count
        let model = selectedLLMModel
        let baseURL = settings.endpoint(for: provider)
        let effort = selectedLLMEffort
        let enableThinking = settings.qwenThinking
        let sentenceContextCount = settings.sentenceContextCount
        let openAIAuthentication = self.openAIAuthentication
        let grokAuthentication = self.grokAuthentication
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
                    let prompt = ReadingAssistantPrompt.sentenceTranslation(
                        language: language,
                        sourceLanguage: sourceLanguage,
                        readerLevel: readerLevel,
                        metadata: metadata,
                        context: ReadingAssistantPrompt.sentenceContext(
                            around: block,
                            in: transcript,
                            radius: sentenceContextCount
                        ),
                        targetIDs: remaining.map(\.id)
                    )
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
                            system: prompt.system,
                            user: prompt.user,
                            baseURL: baseURL,
                            model: model,
                            effort: effort,
                            enableThinking: enableThinking,
                            grokAuthentication: grokAuthentication,
                            openAIAuthentication: openAIAuthentication
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
                        DictionaryLookup.lookup(
                            phrase,
                            preferredName: preferredDictionary,
                            language: StudyLanguage(rawValue: acceptedLanguage) ?? .en
                        ).first
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
            let vocabulary = vocabularyRepository
            let storedVocabUpdates = result.upserts.map(StoredVocabularyOccurrence.init)
            let persistLiveGlosses = usesLivePersistence
            await Task.detached(priority: .utility) {
                if persistLiveGlosses {
                    Persistence.saveGlossUpdates(accepted, allItems: glossSnapshot)
                }
                try? vocabulary.upsertVocabulary(storedVocabUpdates)
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
        guard usesLivePersistence else { return }
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
        let system = ReadingAssistantPrompt.chapterSummary(
            language: studyLanguage,
            sourceLanguage: currentAudiobookLanguage,
            readerLevel: readerLanguageLevel
        )
        guard let chapterID = origin.chapterID else { return }
        let language = settings.targetLanguage
        let model = selectedLLMModel
        let existing = chapterSummaries.first {
            $0.id == ChapterSummaryRecord.makeID(chapterID: chapterID, language: language)
                && $0.status != .rejected
        }
        let metadata = bookMetadata(book: selectedBook, chapter: selectedChapter)
        enqueueChapterAssistant(
            kind: .chapterSummary,
            origin: origin,
            system: system,
            user: fullChapterInput(transcript, metadata: metadata)
        ) { summary in
            do {
                let presentation = try ChapterSummaryPresentation.parse(summary)
                let record = ChapterSummaryRecord.pending(
                    summary: presentation,
                    language: language,
                    model: model,
                    bookID: origin.bookID,
                    bookTitle: origin.bookTitle,
                    chapterID: chapterID,
                    chapterTitle: origin.chapterTitle,
                    replacing: existing
                )
                self.saveChapterSummary(record, origin: origin)
            } catch {
                self.chapterAssistantErrorsByChapterID[chapterID] = error.localizedDescription
                if self.isSelected(origin) {
                    self.chapterAssistantError = error.localizedDescription
                }
            }
        }
    }

    func acceptChapterSummary() {
        guard let chapterSummary, chapterSummary.status == .pending else { return }
        saveChapterSummary(chapterSummary.accept(at: Date()), origin: selectedOrigin())
    }

    func rejectChapterSummary() {
        guard let chapterSummary, chapterSummary.status == .pending else { return }
        let reviewed = chapterSummary.reject(at: Date())
        saveChapterSummary(reviewed, origin: selectedOrigin())
        if reviewed.status == .rejected {
            self.chapterSummary = nil
        }
    }

    private func saveChapterSummary(
        _ summary: ChapterSummaryRecord,
        origin: BackgroundJobOrigin
    ) {
        if let index = chapterSummaries.firstIndex(where: { $0.id == summary.id }) {
            chapterSummaries[index] = summary
        } else {
            chapterSummaries.append(summary)
        }
        if usesLivePersistence {
            Persistence.saveChapterSummaries(chapterSummaries)
        }
        if isSelected(origin) {
            chapterSummary = summary.status == .rejected ? nil : summary
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
        let system = ReadingAssistantPrompt.chapterChat(
            language: studyLanguage,
            sourceLanguage: currentAudiobookLanguage,
            readerLevel: readerLanguageLevel
        )
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
        if let configurationError = llmConfigurationError(for: provider) {
            chapterAssistantError = configurationError.localizedDescription
            showSettings = true
            return
        }
        let baseURL = settings.endpoint(for: provider)
        let model = selectedLLMModel
        let effort = selectedLLMEffort
        let enableThinking = settings.qwenThinking
        let openAIAuthentication = self.openAIAuthentication
        let grokAuthentication = self.grokAuthentication
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
                    enableThinking: enableThinking,
                    grokAuthentication: grokAuthentication,
                    openAIAuthentication: openAIAuthentication
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
        if usesLivePersistence {
            Persistence.saveGlosses(glosses)
        }
        var vocabularyChanged = false
        for entry in entries where entry.status == .accepted {
            let changed = autoreleasepool {
                captureAccepted(entry, persist: false)
            }
            vocabularyChanged = vocabularyChanged || changed
        }
        if vocabularyChanged {
            persistVocabulary()
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
        persistVocabularyUpdates(result.upserts)
    }

    private var chapterAcceptanceDefaults: ChapterAcceptanceBatch.Defaults {
        ChapterAcceptanceBatch.Defaults(
            bookID: selectedBookID ?? "",
            bookTitle: selectedBook?.title ?? "",
            chapterID: selectedChapterID ?? "",
            chapterTitle: selectedChapter?.title ?? "",
            timestamp: currentSegment?.start ?? 0,
            segment: currentSegment,
            wordID: selectedWord?.id,
            sourceLanguage: selectedBook.map {
                StudyTokenIndex.languageKey(for: audiobookLanguage(for: $0))
            }
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
        let sourceLanguage = selectedBook.map {
            StudyTokenIndex.languageKey(for: audiobookLanguage(for: $0))
        }
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
                if vocab[idx].sourceLanguage == nil, let sourceLanguage {
                    vocab[idx].sourceLanguage = sourceLanguage
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
                        sourceLanguage: sourceLanguage,
                        context: original,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.trustedEbookText,
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
                        sourceLanguage: sourceLanguage,
                        context: gloss.source,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.trustedEbookText,
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
                let hits = DictionaryLookup.lookup(
                    phrase.phrase,
                    preferredName: settings.preferredDictionary,
                    language: StudyLanguage(rawValue: gloss.language) ?? .en
                )
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
                        sourceLanguage: sourceLanguage,
                        context: gloss.source,
                        spokenText: segment?.spokenText,
                        ebookText: segment?.trustedEbookText,
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
            persistVocabulary()
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
                || GlossEntry.normalize($0.trustedEbookText ?? "").contains(needle)
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
