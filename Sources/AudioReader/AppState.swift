import Foundation
import OSLog
import SwiftUI
#if os(macOS)
import AppKit
#endif
#if canImport(AudioReaderNetworking)
import AudioReaderNetworking
#endif

struct PendingExternalEPUBDuplicate: Sendable {
    var url: URL
    var title: String
}

struct ChapterSummaryExecutionRequest: Sendable {
    var provider: LLMProvider
    var model: String
    var origin: BackgroundJobOrigin
    var system: String
    var user: String
    var refresh: Bool
    var targetID: String?
}

struct ChapterSummaryExecutionResult: Sendable {
    var text: String
    var identity: ProductChapterSummary?
}

@MainActor
protocol ChapterSummaryExecuting {
    func execute(_ request: ChapterSummaryExecutionRequest) async throws -> ChapterSummaryExecutionResult
}

@MainActor
protocol ChapterSummarySaving {
    func save(_ summary: ChapterSummaryRecord) throws
}

@MainActor
@Observable
final class AppState {
    private static let reviewLog = Logger(
        subsystem: "com.johnsonzhang.AudioReader",
        category: "vocabulary-review"
    )
    private static let vocabularyLog = Logger(
        subsystem: "com.johnsonzhang.AudioReader",
        category: "vocabulary-capture"
    )
    private static let assistantLog = Logger(
        subsystem: "com.johnsonzhang.AudioReader",
        category: "chapter-assistant"
    )

    var settings: AppSettings
    var books: [Book] = []
    var selectedBookID: String?
    var selectedChapterID: String?
    var transcript: Transcript? {
        didSet {
            transcriptionLanguageMismatch = TranscriptionLanguageMismatchDetector.detect(in: transcript)
            reloadResolvedTranscriptForCurrentChapter()
            refreshStudyIndex()
        }
    }
    var transcriptionLanguageMismatch: TranscriptionLanguageMismatch?
    private(set) var transcriptSegmentCount = 0
    var canLoadMoreTranscriptSegments: Bool {
        (transcript?.segments.count ?? 0) < transcriptSegmentCount
    }
    private(set) var presentedTranscript: Transcript?
    private(set) var transcriptOverlayStatuses: [String: TranscriptOverlayApplicationStatus] = [:]
    private(set) var retainedTranscriptOverlays: [StoredTranscriptOverlay] = []
    private(set) var transcriptOverlayConflictStates: [String: StoredTranscriptOverlayState] = [:]
    private(set) var readerProgressState: StoredReaderProgressState?
    private(set) var vocabularyLearningRevision: UInt = 0
    var vocab: [VocabEntry] = [] {
        didSet {
            vocabularyLearningRevision &+= 1
            if !suppressesVocabularyStudyIndexRefresh { refreshStudyIndex() }
        }
    }
    private(set) var vocabReviewEvents: [StoredReviewEvent] = [] {
        didSet { vocabularyLearningRevision &+= 1 }
    }
    var knownLemmas: [KnownLemmaRecord] = [] {
        didSet { refreshStudyIndex() }
    }
    private(set) var studyIndex = StudyIndex.empty
    var chapterStudyPresentation: ChapterStudyPresentation?
    var shadowingSegment: TranscriptSegment?
    var chapterQuizSession: ChapterQuizSession?
    var chapterQuizTitle = "Chapter quiz"
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
    var pendingExternalEPUBDuplicate: PendingExternalEPUBDuplicate?
    var selectedWord: TranscriptWord?
    var definition: String?
    var dictionaryHits: [DictionaryHit] = []
    var selectedDictionaryName: String = ""
    var loopSentence = false
    private(set) var playingVocabEntryID: String?
    private(set) var deepReadingActiveSentenceID: String?
    private(set) var deepReadingPausedSentenceID: String?
    private(set) var listenFirstReplayRevealedSegmentID: String?
    var isHeardQuizWorking = false
    var glosses: [GlossEntry] = [] {
        didSet { chapterGlossGeneration &+= 1 }
    }
    var chapterTranslationCheckpoints: [ChapterTranslationCheckpoint] = []
    var isTranslating = false
    var translationError: String?
    var vocabularyNotice: String?
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
    @ObservationIgnored private var suppressesVocabularyStudyIndexRefresh = false
#if DEBUG
    @ObservationIgnored private(set) var studyIndexRefreshCount = 0
#endif
    var llmJobQueue = BackgroundJobQueue(maxConcurrentPerKind: 2)
    @ObservationIgnored private var llmJobOperations: [UUID: @MainActor (UUID) async -> Void] = [:]
    @ObservationIgnored private let chapterSummaryExecutor: (any ChapterSummaryExecuting)?
    @ObservationIgnored private let chapterSummarySaver: (any ChapterSummarySaving)?
    @ObservationIgnored private var chapterTranslationStopRequests: Set<UUID> = []
    @ObservationIgnored private var managedHydrationKeys: Set<String> = []
    @ObservationIgnored private var chapterSummaries: [ChapterSummaryRecord] = []
    @ObservationIgnored private var chapterChatsByChapterID: [String: [LLMChatMessage]] = [:]
    @ObservationIgnored private var chapterAssistantErrorsByChapterID: [String: String] = [:]
    @ObservationIgnored private var chapterAcceptanceID: UUID?
    @ObservationIgnored private var credentialMigrationSession = LegacyCredentialMigrationSession()
    @ObservationIgnored private let vocabularyRepository: any VocabularyRepository
    @ObservationIgnored private let knownLemmaRepository: any KnownLemmaRepository
    @ObservationIgnored private let reviewEventRepository: any ReviewEventRepository
    @ObservationIgnored private let transcriptRepository: any TranscriptRepository
    @ObservationIgnored private let vocabularyCanonicalizationFallback: VocabularyCanonicalizationFallbackResolver?
    @ObservationIgnored private let usesLivePersistence: Bool
    /// Present only for an explicitly live composition; in-memory construction has no disk fallback.
    @ObservationIgnored private let liveDatabase: LocalSQLiteStore?
    @ObservationIgnored private var lastPersistedReaderSeconds: TimeInterval?
    @ObservationIgnored private var inMemoryTranscriptOverlays: [StoredTranscriptOverlay] = []

    var selectedBook: Book? {
        books.first { $0.id == selectedBookID }
    }

    var selectedChapter: Chapter? {
        selectedBook?.chapters.first { $0.id == selectedChapterID }
    }

    /// EPUB-only sections render as published text without overwriting the
    /// user's persisted preference for audio and aligned audio-plus-EPUB chapters.
    var readerTextSource: TextSource {
        guard selectedChapter?.ebookSectionIndex != nil,
              selectedChapter?.hasAudio == false
        else { return textSource }
        return .original
    }

    /// Keeps immutable transcript source separate from the one resolved view
    /// consumed by playback, lookup, assistance, vocabulary, and export.
    func reloadResolvedTranscriptForCurrentChapter(
        overlays: [StoredTranscriptOverlay]? = nil,
        chapterDuration: TimeInterval? = nil
    ) {
        guard let transcript else {
            presentedTranscript = nil
            transcriptOverlayStatuses = [:]
            retainedTranscriptOverlays = []
            transcriptOverlayConflictStates = [:]
            return
        }
        let selectedOverlays: [StoredTranscriptOverlay]
        if let overlays {
            selectedOverlays = overlays
        } else if let database = liveDatabase {
            selectedOverlays = Persistence.loadTranscriptOverlays(
                chapterID: transcript.chapterID,
                database: database
            )
        } else {
            selectedOverlays = inMemoryTranscriptOverlays.filter { $0.chapterID.rawValue == transcript.chapterID }
        }
        let resolved = TranscriptOverlayResolver.resolve(
            base: StoredTranscript(transcript),
            overlays: selectedOverlays,
            chapterDuration: chapterDuration ?? selectedChapter?.duration
        )
        presentedTranscript = Transcript(resolved)
        transcriptOverlayStatuses = resolved.statuses
        retainedTranscriptOverlays = resolved.retainedOverlays
        if let database = liveDatabase {
            transcriptOverlayConflictStates = Dictionary(uniqueKeysWithValues: selectedOverlays.compactMap { overlay in
                guard let state = Persistence.loadTranscriptOverlayState(
                    chapterID: overlay.chapterID.rawValue,
                    segmentID: overlay.segmentID,
                    database: database
                ), !state.conflicts.isEmpty else { return nil }
                return (overlay.segmentID, state)
            })
        } else {
            transcriptOverlayConflictStates = [:]
        }
    }

    func transcriptOverlay(for segmentID: String) -> StoredTranscriptOverlay? {
        retainedTranscriptOverlays.first { $0.segmentID == segmentID }
    }

    func transcriptOverlayChoices(for segmentID: String) -> [StoredTranscriptOverlayCandidate] {
        guard let state = transcriptOverlayConflictStates[segmentID] else { return [] }
        return [state.current] + state.conflicts
    }

    /// Promotes one device's candidate and clears its competing corrections;
    /// the immutable transcript stays untouched and the choice is resynchronized.
    func resolveTranscriptOverlayConflict(segmentID: String, choosing candidateID: String) throws {
        guard let chapterID = transcript?.chapterID ?? selectedChapterID,
              let database = liveDatabase else { return }
        _ = try Persistence.resolveTranscriptOverlay(
            chapterID: chapterID,
            segmentID: segmentID,
            choosing: candidateID,
            database: database
        )
        reloadResolvedTranscriptForCurrentChapter()
    }

    /// Saves one current correction against the immutable source fingerprint;
    /// callers must pass complete effective text and sentence bounds.
    func saveTranscriptCorrection(
        segmentID: String,
        text: String,
        start: TimeInterval,
        end: TimeInterval
    ) throws {
        guard let transcript,
              let baseSegment = transcript.segments.first(where: { $0.id == segmentID })
        else { throw TranscriptOverlaySaveError.invalid(.missingSegment) }
        let chapterID = ChapterID(rawValue: transcript.chapterID)
        let now = Date()
        let overlay = StoredTranscriptOverlay(
            id: StoredTranscriptOverlay.stableID(chapterID: chapterID, segmentID: segmentID),
            chapterID: chapterID,
            segmentID: segmentID,
            baseFingerprint: TranscriptOverlayResolver.baseFingerprint(for: StoredTranscriptSegment(baseSegment)),
            correctedText: text,
            correctedStart: start,
            correctedEnd: end,
            provenance: .init(
                deviceID: account.currentDeviceID ?? "local",
                actorID: account.profile?.id,
                createdAt: transcriptOverlay(for: segmentID)?.provenance.createdAt ?? now
            ),
            updatedAt: now
        )
        if let database = liveDatabase {
            try Persistence.saveTranscriptOverlay(
                overlay,
                base: transcript,
                chapterDuration: selectedChapter?.duration,
                database: database
            )
            glosses = Persistence.loadGlosses(database: database)
        } else {
            let resolution = TranscriptOverlayResolver.resolve(
                base: StoredTranscript(transcript),
                overlays: [overlay],
                chapterDuration: selectedChapter?.duration
            )
            switch resolution.statuses[overlay.id] {
            case .applied:
                inMemoryTranscriptOverlays.removeAll { $0.id == overlay.id }
                inMemoryTranscriptOverlays.append(overlay)
            case .staleBase:
                throw TranscriptOverlaySaveError.staleBase
            case .invalid(let error):
                throw TranscriptOverlaySaveError.invalid(error)
            default:
                throw TranscriptOverlaySaveError.invalid(.missingSegment)
            }
        }
        reloadResolvedTranscriptForCurrentChapter()
    }

    func restoreTranscriptCorrection(segmentID: String) throws {
        let chapterID = ChapterID(rawValue: transcript?.chapterID ?? selectedChapterID ?? "")
        let overlayID = StoredTranscriptOverlay.stableID(chapterID: chapterID, segmentID: segmentID)
        if let database = liveDatabase {
            try Persistence.restoreOriginalTranscriptSegment(overlayID: overlayID, database: database)
        } else {
            inMemoryTranscriptOverlays.removeAll { $0.id == overlayID }
        }
        reloadResolvedTranscriptForCurrentChapter()
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
        jobs.append(contentsOf: llmJobQueue.visibleJobs)
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
                && !$0.state.isTerminal
                && $0.chapterID == selectedChapterID
                && (targetID == nil || $0.targetID == targetID)
        }
    }

    var selectedChapterTranslationJobState: BackgroundJob.State? {
        llmJobQueue.presentation(forChapterID: selectedChapterID).chapterTranslationState
    }

    var selectedChapterSummaryJob: BackgroundJob? {
        selectedChapterID.flatMap {
            llmJobQueue.latestChapterSummary(chapterID: $0, language: settings.targetLanguage)
        }
    }

    var currentReaderPosition: (segment: TranscriptSegment?, word: TranscriptWord?) {
        guard let presentedTranscript else { return (nil, nil) }
        let cursor = PlaybackCursor.resolve(segments: presentedTranscript.segments, time: player.currentTime)
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

    /// User-facing assistant name. Managed Qwen's real model id lives on the Worker.
    var selectedLLMModel: String {
        switch llmProvider {
        case .managedQwen: "Managed Qwen"
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
        case .managedQwen: ""
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
#if DEBUG
        studyIndexRefreshCount += 1
#endif
        studyIndex = StudyIndex.build(
            segments: presentedTranscript?.segments ?? [],
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
            ?? presentedTranscript?.segments.first(where: { $0.id == focusedSegmentID })
            ?? currentSegment
        shadowingSegment = target
        if target != nil {
            player.pause()
        }
    }

    func presentChapterQuiz() {
        guard let transcript = presentedTranscript, !transcript.segments.isEmpty else { return }
        let quiz = ChapterQuizBuilder.build(
            segments: transcript.segments,
            language: studyLexiconLanguage
        )
        guard !quiz.questions.isEmpty else { return }
        chapterQuizTitle = "Chapter quiz"
        chapterQuizSession = ChapterQuizSession(quiz: quiz)
    }

    /// Requests an optional AI quiz over only the resolved sentences completed before the pause.
    func requestHeardQuiz() {
        guard !isHeardQuizWorking,
              let transcript = presentedTranscript,
              let pausedID = deepReadingPausedSentenceID,
              let passage = HeardPassage.recent(in: transcript, throughSegmentID: pausedID)
        else { return }
        let fallback = {
            HeardQuizResolver.resolve(
                response: "",
                passage: passage,
                language: self.studyLexiconLanguage
            )
        }
#if DEBUG
        // UI automation proves the interaction contract without depending on a provider or network.
        if UITestLaunchScenario.isRequested {
            let quiz = fallback()
            guard !quiz.questions.isEmpty else { return }
            chapterQuizTitle = "Quick quiz"
            chapterQuizSession = ChapterQuizSession(quiz: quiz)
            return
        }
#endif
        let task = ReadingAssistantPrompt.heardQuiz(
            passage: passage,
            language: studyLanguage,
            sourceLanguage: currentAudiobookLanguage,
            readerLevel: readerLanguageLevel
        )
        let origin = selectedOrigin()
        isHeardQuizWorking = true
        account.recordUsage(name: "ai.chat.requested", properties: ["feature": "heard_quiz"])
        enqueueChapterAssistant(
            kind: .chapterChat,
            origin: origin,
            targetID: "heard-quiz-\(pausedID)",
            system: task.system,
            user: "\(bookMetadata(book: selectedBook, chapter: selectedChapter))\n\n\(task.user)",
            structuredJSON: true,
            heardQuizSegments: passage.segments.map {
                ProductHeardSegment(id: $0.id, text: $0.displayText)
            },
            completion: { response, _ in
                self.isHeardQuizWorking = false
                let quiz = HeardQuizResolver.resolve(
                    response: response,
                    passage: passage,
                    language: self.studyLexiconLanguage
                )
                if !quiz.questions.isEmpty {
                    self.chapterQuizTitle = "Quick quiz"
                    self.chapterQuizSession = ChapterQuizSession(quiz: quiz)
                }
            },
            failure: {
                self.isHeardQuizWorking = false
                let quiz = fallback()
                if !quiz.questions.isEmpty {
                    self.chapterQuizTitle = "Quick quiz"
                    self.chapterQuizSession = ChapterQuizSession(quiz: quiz)
                }
            }
        )
    }

    func recordStudyActivity(now: Date = Date()) {
        studyActivityLog = studyActivityLog.recording(on: now)
        guard let database = liveDatabase else { return }
        Persistence.saveStudyActivityLog(studyActivityLog, database: database)
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
        account.recordUsage(
            name: "vocab.known_toggled",
            properties: ["known": known ? "true" : "false"]
        )
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
        case .managedQwen:
            account.mode.isSignedIn ? nil : .managedAccountRequired
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
        guard selectedChapter?.hasAudio != false else { return nil }
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
            try Persistence.saveTranscript(transcript, database: transcriptRepository)
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
            try Persistence.saveTranscript(saved, database: transcriptRepository)
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
        let originals = book.chapters.compactMap {
            Persistence.loadTranscript(for: $0, database: transcriptRepository)
        }
        var invalidated: [Transcript] = []
        do {
            for original in originals {
                var saved = original
                invalidateEbookText(in: &saved, assessment: assessment)
                try Persistence.saveTranscript(saved, database: transcriptRepository)
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
                    try Persistence.saveTranscript(original, database: transcriptRepository)
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
        if let chapter = selectedChapter,
           !chapter.hasAudio,
           let sectionIndex = chapter.ebookSectionIndex {
            transcript = EPUBParser.readerTranscript(
                from: replacement.destination.path,
                sectionIndex: sectionIndex,
                chapterID: chapter.id
            )
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

    init(composition: AppComposition = .inMemory(),
        account: AccountSession? = nil,
        chapterSummaryExecutor: (any ChapterSummaryExecuting)? = nil,
        chapterSummarySaver: (any ChapterSummarySaving)? = nil
    ) {
        self.chapterSummaryExecutor = chapterSummaryExecutor
        self.chapterSummarySaver = chapterSummarySaver
        vocabularyRepository = composition.vocabulary
        knownLemmaRepository = composition.knownLemmas
        reviewEventRepository = composition.reviewEvents
        transcriptRepository = composition.transcripts
        vocabularyCanonicalizationFallback = composition.canonicalizationFallback
        usesLivePersistence = composition.usesLivePersistence
        liveDatabase = composition.synchronizedStore
        if let account {
            self.account = account
        } else if usesLivePersistence {
            self.account = AccountSession.live()
        } else {
            self.account = AccountSession.isolated()
        }
        if usesLivePersistence {
            let database = composition.synchronizedStore!
            settings = Persistence.loadSettings(database: database)
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
                Persistence.saveSettings(settings, database: database)
            }
#endif
        } else {
            settings = .default
        }
        let loadedVocabulary = ((try? vocabularyRepository.loadVocabulary()) ?? []).map { stored in
            var copy = VocabEntry(stored)
            copy.sanitizeDictionaryFields()
            return copy
        }
        knownLemmas = ((try? knownLemmaRepository.loadKnownLemmas()) ?? []).map(KnownLemmaRecord.init)
        let loadedReviewEvents = (try? reviewEventRepository.loadReviewEvents()) ?? []
        let reviewedVocabulary = (try? reviewEventRepository.loadReviewVocabularySnapshot()) ?? nil
        let reviewReconciledVocabulary = VocabularyReviewHistoryReconciler.reconcile(
            entries: loadedVocabulary,
            events: loadedReviewEvents,
            authoritativeSchedules: reviewedVocabulary ?? []
        )
        vocab = VocabularySenseConfirmation.reconcile(reviewReconciledVocabulary)
        let senseRepairs = zip(reviewReconciledVocabulary, vocab)
            .compactMap { original, repaired in original == repaired ? nil : repaired }
        if !senseRepairs.isEmpty {
            try? vocabularyRepository.upsertVocabulary(senseRepairs.map(StoredVocabularyOccurrence.init))
            Self.vocabularyLog.info(
                "vocabulary_reconciliation message=vocabulary_reconciliation component=vocabulary-canonicalization outcome=repaired occurrences=\(senseRepairs.count, privacy: .public)"
            )
        }
        vocabReviewEvents = loadedReviewEvents
        appleIntelligenceAvailability = AppleIntelligenceAvailability.current()
        if usesLivePersistence, let database = liveDatabase {
            studyActivityLog = Persistence.loadStudyActivityLog(database: database)
            glosses = Persistence.loadGlosses(database: database)
            chapterTranslationCheckpoints = Persistence.loadChapterTranslationCheckpoints(database: database)
            chapterSummaries = Persistence.loadChapterSummaries(database: database)
        }
        selectedDictionaryName = settings.preferredDictionary
        if let raw = TextSource(rawValue: settings.textSource) {
            textSource = raw
        }
        player.rate = Float(settings.playbackRate)
        player.onTick = { [weak self] seconds in
            self?.handlePlayerTick(seconds)
        }
        self.account.onLearningDataApplied = { [weak self] in
            self?.reloadSyncedLearningData()
        }
        guard usesLivePersistence else { return }
        importGlossesIntoVocab()
        if vocab.contains(where: { DictionaryLookup.looksLikeMarkup($0.definition ?? "") }) {
            persistVocabulary()
        }
        migrateLegacyProviderCredentials()
        if ProcessInfo.processInfo.environment["AUDIOREADER_OPEN_SETTINGS"] == "1" {
            tab = .settings
        }
    }

    /// Local discovery commits before account restore so a sync publication
    /// cannot race a stale rescan into the observable catalog.
    func boot() async {
        await rescan()
        if selectedBookID == nil, let first = books.first {
            selectedBookID = first.id
            selectedChapterID = first.chapters.first?.id
        }
        await account.restore()
        reloadSyncedLearningData()
        if account.mode.isSignedIn {
            account.recordUsage(
                name: "app.ready",
                properties: [
                    "feature": "app",
                    "bookCount": "\(books.count)",
                    "readerLevel": settings.readerLanguageLevel,
                    "sourceLanguage": settings.transcriptionLanguage,
                    "targetLanguage": settings.targetLanguage
                ]
            )
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
        guard let database = liveDatabase else { return }
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
        let discovered = await Task.detached(priority: .userInitiated) {
            LibraryScanner.scan(root: root)
        }.value
        let scanned: [Book]
        do {
            scanned = try Persistence.filterSuppressedBooks(discovered, database: database)
        } catch {
            scanned = discovered
            errorMessage = "Deleted-library state could not be loaded: \(error.localizedDescription)"
        }
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
        readyChapterIDs = Persistence.readyChapterIDs(in: scanned, database: database)

        libraryScanProgress = .init(
            stage: "Reading chapter information",
            detail: "0 of \(scanned.count) books complete",
            completed: 0,
            total: scanned.count
        )
        var completed = 0
        await withTaskGroup(of: (Int, Book).self) { group in
            for (index, book) in scanned.enumerated() {
                group.addTask { @Sendable in
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
        do {
            books = try Persistence.reconcileScannedBooks(books, database: database)
        } catch {
            errorMessage = "Library metadata could not be saved: \(error.localizedDescription)"
        }
        readyChapterIDs = Persistence.readyChapterIDs(in: books, database: database)
    }

    /// Both platform shells use the same catalog/assets/outbox deletion path;
    /// the only platform distinction is the managed media root.
    func deleteBookFromLibrary(_ book: Book) throws {
        guard let database = liveDatabase else { return }
#if os(iOS)
        let mediaRoot = Persistence.importedBooksURL
#else
        let mediaRoot = URL(fileURLWithPath: settings.libraryPath, isDirectory: true)
#endif
        try Persistence.deleteBook(book, mediaRoot: mediaRoot, database: database)
        books.removeAll { $0.id == book.id }
        readyChapterIDs.subtract(book.chapters.map(\.id))
        if selectedBookID == book.id {
            cancelTranscription()
            player.tearDown()
            selectedBookID = books.first?.id
            selectedChapterID = books.first?.chapters.first?.id
            transcript = nil
            transcriptSegmentCount = 0
            tab = .library
        }
    }

    /// Handles the system document-open route used by Files and Apple Books
    /// exports; copying and EPUB validation stay off the main actor.
    func importExternalEPUB(_ url: URL) async {
        await performExternalEPUBImport(url, duplicatePolicy: .keepExisting)
    }

    func confirmExternalEPUBImport() async {
        guard let pending = pendingExternalEPUBDuplicate else { return }
        pendingExternalEPUBDuplicate = nil
        await performExternalEPUBImport(pending.url, duplicatePolicy: .confirmedReimport)
    }

    func cancelExternalEPUBImport() {
        guard pendingExternalEPUBDuplicate != nil else { return }
        pendingExternalEPUBDuplicate = nil
        account.recordUsage(
            name: "book_import.finished",
            properties: ["source": "open_url", "outcome": "duplicate_cancelled"]
        )
    }

    /// The open-URL route pauses after read-only identity inspection; only the
    /// confirmed path is allowed to create a second library folder.
    private func performExternalEPUBImport(
        _ url: URL,
        duplicatePolicy: AudiobookDuplicateImportPolicy
    ) async {
        guard LibraryScanner.ebookExt.contains(url.pathExtension.lowercased()) else {
            errorMessage = "AudioReader can open DRM-free EPUB documents."
            return
        }
        account.recordUsage(name: "book_import.started", properties: ["source": "open_url"])
        do {
            if case .keepExisting = duplicatePolicy {
                let preflight = try await Task.detached(priority: .userInitiated) {
                    try AudiobookImportService.preflightFiles([url])
                }.value
                if let duplicate = preflight.duplicates.first {
                    pendingExternalEPUBDuplicate = .init(url: url, title: duplicate.title)
                    account.recordUsage(
                        name: "book_import.finished",
                        properties: ["source": "open_url", "outcome": "confirmation_required"]
                    )
                    return
                }
            }
            let result = try await Task.detached(priority: .userInitiated) {
                try AudiobookImportService.importFiles([url], duplicatePolicy: duplicatePolicy)
            }.value
            await rescan()
            guard let book = books.first(where: {
                URL(fileURLWithPath: $0.folderPath).standardizedFileURL == result.folder.standardizedFileURL
            }) else {
                errorMessage = "The EPUB was imported, but the new library item could not be opened."
                return
            }
            _ = continueReading(book)
            account.recordUsage(
                name: "book_import.finished",
                properties: ["source": "open_url", "outcome": "success", "bookId": book.id]
            )
        } catch {
            errorMessage = error.localizedDescription
            account.recordUsage(
                name: "book_import.finished",
                properties: ["source": "open_url", "outcome": "failure"]
            )
        }
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
        persistCurrentReaderProgress(force: true)
        selectedBookID = book.id
        selectedChapterID = chapter.id
        tab = .player
        managedHydrationKeys.removeAll()
        account.recordUsage(
            name: "reading.chapter_opened",
            properties: ["bookId": book.id, "chapterId": chapter.id]
        )
        if chapter.hasAudio {
            player.load(path: chapter.audioPath, startTime: chapter.audioStart, duration: chapter.duration)
        } else {
            player.tearDown()
        }
        readerProgressState = liveDatabase.flatMap {
            Persistence.loadReaderProgress(bookID: book.id, database: $0)
        }
        lastPersistedReaderSeconds = nil
        deepReadingActiveSentenceID = nil
        deepReadingPausedSentenceID = nil
        player.rate = Float(settings.playbackRate)
        if chapter.hasAudio {
            if let database = liveDatabase {
                transcriptSegmentCount = Persistence.transcriptSegmentCount(
                    chapterID: chapter.id,
                    database: database
                )
                transcript = Persistence.loadTranscriptPage(
                    for: chapter,
                    range: 0..<Persistence.transcriptPageSize,
                    database: database
                )
            } else {
                transcript = Persistence.loadTranscript(for: chapter, database: transcriptRepository)
                transcriptSegmentCount = transcript?.segments.count ?? 0
            }
        } else if let ebookPath = book.ebookPath, let sectionIndex = chapter.ebookSectionIndex {
            transcript = EPUBParser.readerTranscript(
                from: ebookPath,
                sectionIndex: sectionIndex,
                chapterID: chapter.id
            )
            transcriptSegmentCount = transcript?.segments.count ?? 0
            readyChapterIDs.insert(chapter.id)
        } else {
            transcript = nil
            transcriptSegmentCount = 0
        }
        chapterTranslation = nil
        chapterSummary = chapterSummaries.first {
            $0.chapterID == chapter.id
                && $0.language == settings.targetLanguage
                && $0.status != .rejected
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
        if autoplay && chapter.hasAudio { player.play() }
        if let pending = pendingReveal, transcript != nil {
            applyReveal(pending)
            pendingReveal = nil
        }
        ensureCachedChapterSummary()
        ensureAutoTranslation()
    }

    /// Reader navigation grows the visible window one bounded SQLite page at a
    /// time; opening a large chapter never materializes the remaining segments.
    func loadMoreTranscriptSegments() {
        guard let database = liveDatabase,
              let chapter = selectedChapter,
              var current = transcript,
              current.segments.count < transcriptSegmentCount
        else { return }
        let start = current.segments.count
        let end = min(start + Persistence.transcriptPageSize, transcriptSegmentCount)
        guard let page = Persistence.loadTranscriptPage(
            for: chapter,
            range: start..<end,
            database: database
        ) else { return }
        current.segments.append(contentsOf: page.segments)
        transcript = current
    }

    /// Whole-chapter jobs may materialize the chapter, but only through the
    /// store's bounded page loader; the reader's visible transcript stays paged.
    func completeTranscriptForChapterAssistant() -> Transcript? {
        guard let database = liveDatabase,
              let chapter = selectedChapter,
              (presentedTranscript?.segments.count ?? 0) < transcriptSegmentCount,
              let complete = Persistence.loadCompleteTranscript(for: chapter, database: database)
        else { return presentedTranscript }
        return Transcript(Persistence.resolvedTranscript(
            complete,
            chapterDuration: chapter.duration,
            database: database
        ))
    }

    /// Contents and search navigation use the persisted chapter identity rather
    /// than a transient EPUB title, so resume and cross-device progress stay stable.
    @discardableResult
    func openEbookSection(at sectionIndex: Int, in book: Book, matching query: String? = nil) -> Bool {
        guard let chapter = book.chapters.first(where: { $0.ebookSectionIndex == sectionIndex }) else {
            return false
        }
        open(chapter: chapter, in: book, autoplay: false)
        if let query,
           !query.isEmpty,
           let match = transcript?.segments.first(where: {
               $0.displayText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
           }) {
            scrollSegmentID = match.id
            revealToken += 1
        }
        return true
    }

    /// Opens the exact chapter-relative account position when one exists.
    @discardableResult
    func continueReading(_ book: Book, autoplay: Bool = false) -> Bool {
        let stored = liveDatabase.flatMap {
            Persistence.loadReaderProgress(bookID: book.id, database: $0)
        }
        let chapter = stored.flatMap { progress in
            book.chapters.first { $0.id == progress.current.chapterID.rawValue }
        } ?? book.chapters.first(where: { $0.id == selectedChapterID }) ?? book.chapters.first
        guard let chapter else { return false }
        open(chapter: chapter, in: book, autoplay: false)
        readerProgressState = stored
        if let stored {
            player.seek(min(stored.current.relativeSeconds, chapter.duration ?? stored.current.relativeSeconds))
            lastPersistedReaderSeconds = stored.current.relativeSeconds
        }
        if autoplay { player.play() }
        return true
    }

    var readerProgressChoices: [StoredReaderProgress] {
        guard let readerProgressState else { return [] }
        return [readerProgressState.current] + readerProgressState.conflicts
    }

    func resolveReaderProgress(choosing candidateID: String) throws {
        guard let bookID = selectedBookID, let database = liveDatabase else { return }
        try Persistence.resolveReaderProgress(
            bookID: bookID,
            choosing: candidateID,
            database: database
        )
        readerProgressState = Persistence.loadReaderProgress(bookID: bookID, database: database)
        guard let selectedBook,
              let chosen = readerProgressState?.current,
              let chapter = selectedBook.chapters.first(where: { $0.id == chosen.chapterID.rawValue })
        else { return }
        open(chapter: chapter, in: selectedBook, autoplay: false)
        player.seek(min(chosen.relativeSeconds, chapter.duration ?? chosen.relativeSeconds))
    }

    /// Persists chapter-relative fractional seconds. Normal playback writes at
    /// most once per second; explicit pause/seek/navigation forces the latest value.
    func persistCurrentReaderProgress(force: Bool = false) {
        guard let database = liveDatabase,
              let book = selectedBook,
              let chapter = selectedChapter,
              player.currentTime.isFinite,
              player.currentTime >= 0
        else { return }
        if !force,
           let lastPersistedReaderSeconds,
           abs(lastPersistedReaderSeconds - player.currentTime) < 1 {
            return
        }
        let deviceID = account.currentDeviceID ?? "local"
        let revision = readerProgressState?.current.revision ?? 0
        let progress = StoredReaderProgress(
            id: "\(book.id):\(deviceID)",
            bookID: BookID(rawValue: book.id),
            chapterID: ChapterID(rawValue: chapter.id),
            relativeSeconds: player.currentTime,
            updatedAt: Date(),
            deviceID: deviceID,
            revision: revision
        )
        do {
            _ = try Persistence.saveReaderProgress(progress, database: database)
            readerProgressState = Persistence.loadReaderProgress(bookID: book.id, database: database)
            lastPersistedReaderSeconds = player.currentTime
        } catch {
            errorMessage = "Could not save reading position: \(error.localizedDescription)"
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
        guard chapter.hasAudio else {
            errorMessage = "This EPUB-only section has no audio to transcribe."
            return
        }
        if !force, let existing = Persistence.loadTranscript(for: chapter, database: transcriptRepository) {
            transcript = existing
            return
        }
        transcriptionTask?.cancel()
        isTranscribing = true
        account.recordUsage(name: "transcription.started", properties: ["chapterId": chapter.id])
        transcriptionJobOrigin = BackgroundJobOrigin(
            bookID: book.id,
            bookTitle: book.title,
            author: book.author ?? "",
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
            try Persistence.saveTranscript(transcript, database: transcriptRepository)
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
            persistCurrentReaderProgress(force: true)
        } else if settings.deepReadingMode, deepReadingPausedSentenceID != nil {
            continueDeepReading()
        } else {
            armDeepReadingSentence()
            player.play()
        }
    }

    func skipSentence(direction: Int) {
        guard let transcript = presentedTranscript, let current = currentSegment else {
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
        persistCurrentReaderProgress(force: true)
    }

    func replaySentence() {
        if let current = currentSegment {
            if settings.deepReadingMode {
                listenFirstReplayRevealedSegmentID = current.id
            }
            player.seek(current.start)
            armDeepReadingSentence(current)
            player.play()
        }
    }

    func revealListenFirstSentence(_ segmentID: String) {
        guard settings.deepReadingMode else { return }
        listenFirstReplayRevealedSegmentID = segmentID
    }

    var canContinueDeepReading: Bool {
        guard settings.deepReadingMode,
              let transcript = presentedTranscript,
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
            listenFirstReplayRevealedSegmentID = nil
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
        persistCurrentReaderProgress(force: true)
        if autoplay, !player.isPlaying { player.play() }
    }

    func seekPlayback(to time: TimeInterval) {
        player.seek(time)
        resetDeepReadingAfterSeek()
        persistCurrentReaderProgress(force: true)
    }

    func skipPlayback(seconds: TimeInterval) {
        player.skip(seconds: seconds)
        resetDeepReadingAfterSeek()
        persistCurrentReaderProgress(force: true)
    }

    func continueDeepReading() {
        guard settings.deepReadingMode,
              let transcript = presentedTranscript,
              let sentenceID = deepReadingPausedSentenceID,
              let index = transcript.segments.firstIndex(where: { $0.id == sentenceID }),
              transcript.segments.indices.contains(index + 1)
        else { return }
        let next = transcript.segments[index + 1]
        listenFirstReplayRevealedSegmentID = nil
        player.seek(next.start)
        armDeepReadingSentence(next)
        player.play()
        persistCurrentReaderProgress(force: true)
    }

    func tickPlaybackModes() {
        persistCurrentReaderProgress()
        if loopSentence, let current = currentSegment,
           player.currentTime >= current.end - 0.04 {
            player.seek(current.start)
            player.play()
            return
        }
        guard settings.deepReadingMode, player.isPlaying, let transcript = presentedTranscript else { return }
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
        persistCurrentReaderProgress(force: true)
    }

    /// PlayerEngine calls this independently of SwiftUI view lifetime.
    func handlePlayerTick(_ seconds: TimeInterval) {
        if abs(player.currentTime - seconds) > 0.001 {
            player.currentTime = seconds
        }
        tickPlaybackModes()
    }

    func flushReaderProgress() {
        persistCurrentReaderProgress(force: true)
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
        listenFirstReplayRevealedSegmentID = nil
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
        account.recordUsage(name: "vocab.added", properties: ["wordLength": "\(head.count)"])
        let gloss = lookupGloss(kind: .word, source: head, context: segment.displayText)
        let accepted = gloss?.status == .accepted ? gloss : lookupGloss(kind: .word, source: head, context: nil)
        let dict = selectedDictionaryHit ?? dictionaryHits.first
        let sourceLanguage = StudyTokenIndex.languageKey(for: audiobookLanguage(for: book))
        let canonicalization = VocabularyCanonicalizer.canonicalize(
            surfaceForm: head,
            context: segment.displayText,
            language: sourceLanguage
        )
        var entry = VocabEntry(
            id: UUID().uuidString,
            word: head,
            canonicalForm: canonicalization.canonicalForm,
            partOfSpeech: canonicalization.partOfSpeech,
            senseID: canonicalization.senseID,
            canonicalizationSource: canonicalization.source,
            canonicalizationConfidence: canonicalization.confidence,
            canonicalizationStatus: canonicalization.status,
            canonicalizationTraceID: canonicalization.traceID,
            captureSource: .explicitWord,
            reviewEligible: true,
            category: .word,
            definition: DictionaryLookup.plainPreview(from: dict?.preview ?? definition ?? dict?.html ?? ""),
            dictionaryName: dict?.name,
            dictionaryHTML: DictionaryLookup.optionalDisplayHTML(dict?.html),
            translation: (accepted?.status == .accepted ? accepted?.text : nil) ?? (gloss?.status == .accepted ? gloss?.text : nil),
            translationLanguage: accepted?.language ?? gloss?.language,
            translationModel: accepted?.model ?? gloss?.model,
            sourceLanguage: sourceLanguage,
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
        if let recurringSenseID = VocabularySenseConfirmation.recurringSenseID(for: entry, among: vocab) {
            entry.senseID = recurringSenseID
            entry.canonicalizationStatus = .confirmed
            Self.vocabularyLog.info(
                "vocabulary_canonicalization message=vocabulary_canonicalization component=vocabulary-capture outcome=confirmed_sense_reused"
            )
        }
        Self.vocabularyLog.info(
            "vocabulary_capture message=vocabulary_capture component=vocabulary-capture outcome=saved source=explicit_word canonicalizer=\(entry.canonicalizationSource.rawValue, privacy: .public) status=\(entry.canonicalizationStatus.rawValue, privacy: .public)"
        )
        vocab.insert(entry, at: 0)
        persistVocabulary()
        vocabularyNotice = "Added “\(head)” to your vocabulary."
        resolveVocabularyCanonicalizationFallback(
            entryID: entry.id,
            offline: canonicalization,
            surfaceForm: head,
            context: segment.displayText,
            language: sourceLanguage
        )
    }

    /// Ambiguous offline proposals remain isolated unless the bounded managed
    /// fallback returns a validated structured sense with trace provenance.
    private func resolveVocabularyCanonicalizationFallback(
        entryID: String,
        offline: VocabularyCanonicalization,
        surfaceForm: String,
        context: String,
        language: String
    ) {
        guard offline.status == .needsReview, let vocabularyCanonicalizationFallback else { return }
        Task { @MainActor [weak self] in
            let resolved = await vocabularyCanonicalizationFallback.resolve(
                offline: offline,
                surfaceForm: surfaceForm,
                context: context,
                language: language
            )
            guard resolved.status == .confirmed,
                  let self,
                  let index = self.vocab.firstIndex(where: { $0.id == entryID }),
                  self.vocab[index].canonicalizationStatus == .needsReview
            else { return }
            var updated = self.vocab[index]
            updated.canonicalForm = resolved.canonicalForm
            updated.partOfSpeech = resolved.partOfSpeech
            updated.senseID = VocabularySenseConfirmation.recurringSenseID(for: updated, among: self.vocab)
                ?? resolved.senseID
            updated.canonicalizationSource = resolved.source
            updated.canonicalizationConfidence = resolved.confidence
            updated.canonicalizationStatus = resolved.status
            updated.canonicalizationTraceID = resolved.traceID
            self.replaceVocabularyEntry(at: index, with: updated, refreshStudyIndex: false)
            self.persistVocabularyUpdates([updated])
            Self.vocabularyLog.info(
                "vocabulary_canonicalization message=vocabulary_canonicalization component=vocabulary-capture outcome=fallback_confirmed resource=\(entryID, privacy: .private(mask: .hash)) traceId=\(resolved.traceID ?? "", privacy: .private(mask: .hash))"
            )
        }
    }

    func removeVocab(_ entry: VocabEntry) {
        vocab.removeAll { $0.id == entry.id }
        try? vocabularyRepository.deleteVocabulary(id: VocabularyOccurrenceID(rawValue: entry.id))
    }

    func setVocabularyLearnList(_ entryID: String, included: Bool) {
        guard let index = vocab.firstIndex(where: { $0.id == entryID }) else { return }
        var updated = vocab[index]
        updated.isInLearnList = included
        replaceVocabularyEntry(at: index, with: updated, refreshStudyIndex: false)
        try? vocabularyRepository.updateVocabularyLearnList(
            id: VocabularyOccurrenceID(rawValue: entryID),
            included: included
        )
    }

    /// Suggestions and sentence annotations become scheduler-owned only after
    /// this explicit learner action; My list membership remains independent.
    func acceptVocabularyForReview(_ entryID: String) {
        guard let index = vocab.firstIndex(where: { $0.id == entryID }) else { return }
        var updated = vocab[index]
        updated.reviewEligible = true
        updated.captureSource = updated.category == .sentence ? .explicitSentence : .explicitPhrase
        replaceVocabularyEntry(at: index, with: updated, refreshStudyIndex: false)
        persistVocabularyUpdates([updated])
        Self.vocabularyLog.info(
            "vocabulary_eligibility message=vocabulary_eligibility component=vocabulary-capture outcome=accepted resource=\(entryID, privacy: .private(mask: .hash)) category=\(updated.category.rawValue, privacy: .public)"
        )
    }

    func confirmVocabularyMeaning(
        _ entryID: String,
        canonicalForm: String,
        partOfSpeech: VocabularyPartOfSpeech,
        choice: VocabularyMeaningChoice
    ) {
        guard let index = vocab.firstIndex(where: { $0.id == entryID }),
              !VocabularyCanonicalizer.normalizedForm(canonicalForm).isEmpty
        else { return }
        var updated = vocab[index]
        let mergeTarget = choice.occurrenceIDs
            .lazy
            .filter { $0 != entryID }
            .compactMap { targetID in self.vocab.first(where: { $0.id == targetID }) }
            .first
        let confirmedForm = mergeTarget?.studyForm ?? canonicalForm
        let confirmedPartOfSpeech = mergeTarget?.partOfSpeech ?? partOfSpeech
        let senseID = VocabularySenseConfirmation.resolvedSenseID(
            for: choice,
            entry: updated,
            canonicalForm: confirmedForm,
            partOfSpeech: confirmedPartOfSpeech
        )
        updated.confirmCanonicalForm(
            confirmedForm,
            partOfSpeech: confirmedPartOfSpeech,
            senseID: senseID
        )
        var candidateVocabulary = vocab
        candidateVocabulary[index] = updated
        let reconciled = VocabularySenseConfirmation.reconcile(candidateVocabulary)
        let changed = zip(vocab, reconciled).compactMap { original, repaired in
            original == repaired ? nil : repaired
        }
        vocab = reconciled
        persistVocabularyUpdates(changed)
        Self.vocabularyLog.info(
            "vocabulary_canonicalization message=vocabulary_canonicalization component=vocabulary-capture outcome=user_confirmed resource=\(entryID, privacy: .private(mask: .hash)) partOfSpeech=\(confirmedPartOfSpeech.rawValue, privacy: .public) merged=\(mergeTarget != nil, privacy: .public)"
        )
    }

    /// A split retains the shared schedule on this occurrence while assigning a new hidden identity.
    func separateVocabularyMeaning(_ entryID: String) {
        guard let index = vocab.firstIndex(where: { $0.id == entryID }) else { return }
        let card = VocabularyStudyCards.card(containing: entryID, in: vocab)
        var updated = vocab[index]
        if let card {
            updated = updated.applyingStudySchedule(card.schedule)
            updated.isInLearnList = card.isInLearnList
        }
        updated.confirmCanonicalForm(
            updated.studyForm,
            partOfSpeech: updated.partOfSpeech,
            senseID: VocabularySenseConfirmation.separatedSenseID(for: updated)
        )
        replaceVocabularyEntry(at: index, with: updated, refreshStudyIndex: false)
        persistVocabularyUpdates([updated])
        Self.vocabularyLog.info(
            "vocabulary_canonicalization message=vocabulary_canonicalization component=vocabulary-capture outcome=meaning_separated resource=\(entryID, privacy: .private(mask: .hash))"
        )
    }

    /// Keeps repository I/O off the main actor. The relational review event is
    /// the recovery source if the legacy vocabulary mirror cannot be updated.
    @discardableResult
    func reviewVocabulary(
        _ entryID: String,
        occurrenceID: String? = nil,
        quality: VocabReviewQuality,
        face: VocabReviewPrompt? = nil,
        at date: Date = Date()
    ) async -> Bool {
        guard let card = VocabularyStudyCards.card(containing: entryID, in: vocab),
              let selectedOccurrence = occurrenceID.flatMap(card.occurrence(id:)) ?? card.occurrences.first
        else { return false }
        let reviewedSchedule = VocabReviewScheduler.applying(quality, to: card.studyEntry, at: date)
        let reviewedOccurrences = card.occurrences.map { $0.applyingStudySchedule(from: reviewedSchedule) }
        let displayedFace = face ?? vocabReviewPrompt
        let event = StoredReviewEvent(
            id: ReviewEventID.generate(),
            vocabularyID: VocabularyOccurrenceID(rawValue: selectedOccurrence.id),
            cardID: card.id,
            face: displayedFace.rawValue,
            rating: quality.rawValue,
            reviewedAt: date
        )
        let saveStartedAt = Date()
        Self.reviewLog.info(
            "review_save_start message=review_save_start requestId=\(event.id.rawValue, privacy: .public) component=vocabulary-review outcome=started resource=\(card.id, privacy: .private(mask: .hash))"
        )
        let reviewRepository = reviewEventRepository
        let vocabularyRepository = vocabularyRepository
        let storedVocabulary = reviewedOccurrences.map(StoredVocabularyOccurrence.init)
        let reviewSchedules = storedVocabulary.map(StoredVocabularyReviewSchedule.init)
        do {
            let mirrorFailure = try await Task.detached(priority: .userInitiated) {
                try reviewRepository.appendReviewEvent(event, vocabularies: storedVocabulary)
                do {
                    try vocabularyRepository.updateVocabularyReviewSchedules(reviewSchedules)
                    return nil as String?
                } catch {
                    return String(describing: error)
                }
            }.value
            guard card.occurrenceIDs.contains(where: { id in vocab.contains { $0.id == id } }) else {
                Self.reviewLog.warning(
                    "review_save_finish message=review_save_finish requestId=\(event.id.rawValue, privacy: .public) component=vocabulary-review outcome=saved_card_removed"
                )
                return false
            }
            for reviewSchedule in reviewSchedules {
                guard let currentIndex = vocab.firstIndex(where: { $0.id == reviewSchedule.vocabularyID.rawValue }) else {
                    continue
                }
                let current = StoredVocabularyOccurrence(vocab[currentIndex])
                let merged = VocabEntry(reviewSchedule.merging(into: current))
                replaceVocabularyEntry(at: currentIndex, with: merged, refreshStudyIndex: false)
            }
            vocabReviewEvents.append(event)
            if let mirrorFailure {
                Self.reviewLog.warning(
                    "review_mirror_finish message=review_mirror_finish requestId=\(event.id.rawValue, privacy: .public) component=vocabulary-review outcome=recoverable_failure error=\(mirrorFailure, privacy: .private(mask: .hash))"
                )
            }
            account.recordUsage(
                name: "review.completed",
                properties: [
                    "feature": "review",
                    "rating": quality.rawValue,
                    "face": displayedFace.rawValue,
                    "readerLevel": settings.readerLanguageLevel,
                    "sourceLanguage": selectedOccurrence.sourceLanguage ?? settings.transcriptionLanguage,
                    "targetLanguage": settings.targetLanguage,
                    "contentId": AccountSyncApplicator.syncEntityID(selectedOccurrence.bookID, kind: "book")
                ]
            )
            Self.reviewLog.info(
                "review_save_finish message=review_save_finish requestId=\(event.id.rawValue, privacy: .public) component=vocabulary-review outcome=saved elapsedMs=\(Int(Date().timeIntervalSince(saveStartedAt) * 1_000), privacy: .public)"
            )
            return true
        } catch {
            Self.reviewLog.error(
                "review_save_finish message=review_save_finish requestId=\(event.id.rawValue, privacy: .public) component=vocabulary-review outcome=failed elapsedMs=\(Int(Date().timeIntervalSince(saveStartedAt) * 1_000), privacy: .public) error=\(String(describing: error), privacy: .private(mask: .hash))"
            )
            errorMessage = "The review could not be saved. This card is still due."
            return false
        }
    }

    /// Review scheduling and list membership do not change lexical familiarity,
    /// so those mutations must not rebuild every token in the presented chapter.
    private func replaceVocabularyEntry(
        at index: Int,
        with entry: VocabEntry,
        refreshStudyIndex: Bool
    ) {
        guard !refreshStudyIndex else {
            vocab[index] = entry
            return
        }
        suppressesVocabularyStudyIndexRefresh = true
        defer { suppressesVocabularyStudyIndexRefresh = false }
        vocab[index] = entry
    }

    func canPlayVocabSentence(_ entry: VocabEntry) -> Bool {
        locate(
            bookID: entry.bookID,
            bookTitle: entry.bookTitle,
            chapterID: entry.chapterID,
            chapterTitle: entry.chapterTitle
        )?.chapter.hasAudio == true
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
        guard located.chapter.hasAudio else {
            errorMessage = "This EPUB-only passage has no audio playback."
            return false
        }
        let transcript = Persistence.loadTranscript(for: located.chapter, database: transcriptRepository).map {
            guard let database = liveDatabase else { return $0 }
            return Transcript(Persistence.resolvedTranscript(
                $0,
                chapterDuration: located.chapter.duration,
                database: database
            ))
        }
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

    func presentSettings() {
        tab = .settings
    }

    func persistSettings() {
        settings.playbackRate = Double(player.rate)
        settings.textSource = textSource.rawValue
        guard let database = liveDatabase else { return }
        Persistence.saveSettings(settings, database: database)
    }

    func reloadSyncedLearningData() {
        guard usesLivePersistence else { return }
        guard let database = liveDatabase else { return }
        var loaded = Persistence.loadSettings(database: database)
#if os(iOS)
        loaded.libraryPath = Persistence.importedBooksURL.path
        loaded.openAIAuthentication = OpenAIAuthentication.apiKey.rawValue
        loaded.grokAuthentication = GrokAuthentication.apiKey.rawValue
#endif
        settings = loaded
        let loadedVocabulary = ((try? vocabularyRepository.loadVocabulary()) ?? []).map { stored in
            var copy = VocabEntry(stored)
            copy.sanitizeDictionaryFields()
            return copy
        }
        knownLemmas = ((try? knownLemmaRepository.loadKnownLemmas()) ?? []).map(KnownLemmaRecord.init)
        let loadedReviewEvents = (try? reviewEventRepository.loadReviewEvents()) ?? []
        let reviewedVocabulary = (try? reviewEventRepository.loadReviewVocabularySnapshot()) ?? nil
        let reviewReconciledVocabulary = VocabularyReviewHistoryReconciler.reconcile(
            entries: loadedVocabulary,
            events: loadedReviewEvents,
            authoritativeSchedules: reviewedVocabulary ?? []
        )
        vocab = VocabularySenseConfirmation.reconcile(reviewReconciledVocabulary)
        let senseRepairs = zip(reviewReconciledVocabulary, vocab)
            .compactMap { original, repaired in original == repaired ? nil : repaired }
        if !senseRepairs.isEmpty {
            try? vocabularyRepository.upsertVocabulary(senseRepairs.map(StoredVocabularyOccurrence.init))
            Self.vocabularyLog.info(
                "vocabulary_reconciliation message=vocabulary_reconciliation component=vocabulary-canonicalization outcome=repaired occurrences=\(senseRepairs.count, privacy: .public)"
            )
        }
        vocabReviewEvents = loadedReviewEvents
        if let synchronizedBooks = try? Persistence.loadCatalogBooks(database: database) {
            books = synchronizedBooks
            if let selectedBookID, !synchronizedBooks.contains(where: { $0.id == selectedBookID }) {
                self.selectedBookID = synchronizedBooks.first?.id
                selectedChapterID = synchronizedBooks.first?.chapters.first?.id
            } else if selectedBookID == nil {
                selectedBookID = synchronizedBooks.first?.id
                selectedChapterID = synchronizedBooks.first?.chapters.first?.id
            }
            readyChapterIDs = Persistence.readyChapterIDs(in: synchronizedBooks, database: database)
        }
        glosses = Persistence.loadGlosses(database: database)
        chapterTranslationCheckpoints = Persistence.loadChapterTranslationCheckpoints(database: database)
        chapterSummaries = Persistence.loadChapterSummaries(database: database)
        studyActivityLog = Persistence.loadStudyActivityLog(database: database)
        selectedDictionaryName = settings.preferredDictionary
        player.rate = Float(settings.playbackRate)
        refreshStudyIndex()
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
        translateSentence(segment)
    }

    func retranslateCurrentSentence() {
        guard let segment = currentSegment else { return }
        retranslateSentence(segment)
    }

    func translateSentence(_ segment: TranscriptSegment) {
        account.recordUsage(name: "ai.translation.requested", properties: ["kind": "sentence"])
        translateSentenceBlock(around: segment, forceIDs: [], generate: true)
    }

    func retranslateSentence(_ segment: TranscriptSegment) {
        translateSentenceBlock(around: segment, forceIDs: [segment.id], generate: true)
    }

    func translateSelectedWord() {
        guard let word = selectedWord else { return }
        account.recordUsage(name: "ai.translation.requested", properties: ["kind": "word"])
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
        guard let segment = currentSegment else { return }
        if llmProvider == .managedQwen {
            translateSentenceBlock(
                around: segment,
                forceIDs: [],
                generate: settings.autoTranslate,
                lookupOnly: true
            )
            return
        }
        guard settings.autoTranslate else { return }
        guard currentSentenceGloss == nil else { return }
        translateSentence(segment)
    }

    func acceptGloss(_ entry: GlossEntry) {
        var copy = entry
        copy.status = .accepted
        copy.decidedAt = Date()
        copy.replacedText = nil
        copy.replacedModel = nil
        if let database = liveDatabase {
            let prepared = ChapterAcceptanceBatch.prepare(
                glosses: [copy],
                vocab: vocab,
                segments: transcript?.segments ?? [],
                defaults: chapterAcceptanceDefaults
            )
            do {
                try Persistence.acceptGlosses([copy], vocabulary: prepared.upserts, database: database)
                glosses = GlossBatch.merging([copy], into: glosses)
                mergeVocabUpserts(prepared.upserts, orderedAs: prepared.vocab)
            } catch {
                errorMessage = "The translation decision could not be saved. Nothing was changed."
                return
            }
        } else {
            try? saveGloss(copy)
        }
        account.recordUsage(name: "ai.translation.accepted", properties: ["kind": entry.kind.rawValue])
        refreshSelectedChapterTranslationStatus()
    }

    /// User edits remain a reviewable private lifecycle state until explicitly accepted or rejected.
    func editGloss(_ entry: GlossEntry, text: String) {
        let editedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editedText.isEmpty else { return }
        var edited = entry
        edited.text = editedText
        edited.status = .edited
        edited.decidedAt = Date()
        do {
            try saveGloss(edited)
        } catch {
            errorMessage = "The translation edit could not be saved. Nothing was changed."
        }
    }

    func rejectGloss(_ entry: GlossEntry) {
        account.recordUsage(name: "ai.translation.rejected", properties: ["kind": entry.kind.rawValue])
        if let replacedText = entry.replacedText, let replacedModel = entry.replacedModel {
            var restored = entry
            restored.text = replacedText
            restored.model = replacedModel
            restored.status = .accepted
            restored.decidedAt = Date()
            restored.replacedText = nil
            restored.replacedModel = nil
            if let database = liveDatabase {
                do {
                    try Persistence.acceptGlosses([restored], vocabulary: [], database: database)
                    glosses = GlossBatch.merging([restored], into: glosses)
                } catch {
                    errorMessage = "The translation decision could not be saved. Nothing was changed."
                    return
                }
            } else {
                try? saveGloss(restored)
            }
            refreshSelectedChapterTranslationStatus()
            return
        }
        var copy = entry
        copy.status = .rejected
        copy.decidedAt = Date()
        let source = GlossEntry.normalize(entry.source)
        let derived = vocab.filter {
            ($0.captureSource == .acceptedSentenceTranslation || $0.captureSource == .automaticPhraseSuggestion)
                && $0.reviewCount == 0
                && GlossEntry.normalize($0.context) == source
        }
        if let database = liveDatabase {
            do {
                try Persistence.rejectGloss(copy, derivedVocabulary: derived, database: database)
                glosses = GlossBatch.merging([copy], into: glosses)
                let removed = Set(derived.map(\.id))
                vocab.removeAll { removed.contains($0.id) }
            } catch {
                errorMessage = "The translation decision could not be saved. Nothing was changed."
                return
            }
        } else {
            try? saveGloss(copy)
            vocab.removeAll { candidate in
                derived.contains(where: { $0.id == candidate.id })
            }
            persistVocabulary()
        }
        refreshSelectedChapterTranslationStatus()
    }

    func retryGloss(_ entry: GlossEntry) {
        if entry.kind == .sentence {
            // Retry the glossed sentence, not whatever is currently playing.
            let segment = transcript?.segments.first {
                GlossEntry.normalize($0.displayText) == GlossEntry.normalize(entry.source)
            }
            if let segment {
                retranslateSentence(segment)
            } else {
                retranslateCurrentSentence()
            }
        } else {
            retranslateSelectedWord()
        }
    }

    private func selectedOrigin() -> BackgroundJobOrigin {
        BackgroundJobOrigin(
            bookID: selectedBook?.id,
            bookTitle: selectedBook?.title ?? "Unknown book",
            author: selectedBook?.author ?? "",
            chapterID: selectedChapter?.id ?? transcript?.chapterID,
            chapterTitle: selectedChapter?.title ?? "Unknown chapter"
        )
    }

    private func isSelected(_ origin: BackgroundJobOrigin) -> Bool {
        guard let chapterID = origin.chapterID else { return false }
        return selectedChapterID == chapterID
    }

    @discardableResult
    private func enqueueLLMJob(
        id: UUID = UUID(),
        kind: BackgroundJob.Kind,
        origin: BackgroundJobOrigin,
        targetID: String? = nil,
        language: String? = nil,
        stage: String? = nil,
        detail: String? = nil,
        chapterSummaryPhase: ChapterSummaryProgress.Phase? = nil,
        operation: @escaping @MainActor (UUID) async -> Void
    ) -> BackgroundJob {
        llmJobOperations[id] = operation
        let job = llmJobQueue.enqueue(
            id: id,
            kind: kind,
            origin: origin,
            targetID: targetID,
            language: language,
            stage: stage,
            detail: detail,
            chapterSummaryPhase: chapterSummaryPhase
        )
        refreshLLMBusyState()
        if job.state == .running {
            launchLLMJob(id)
        }
        return job
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

    /// The queue owns both active and recent terminal summary metadata, so the
    /// Chapter AI panel and Background Jobs always render the same request UUID.
    func recordChapterSummaryProgress(
        _ progress: ChapterSummaryProgress,
        jobID: UUID,
        origin: BackgroundJobOrigin,
        language: String? = nil
    ) {
        guard let chapterID = origin.chapterID else { return }
        if progress.isTerminal {
            let state: BackgroundJob.State = switch progress.phase {
            case .completed: .completed
            case .failed: .failed
            case .cancelled: .cancelled
            case .queued, .preparing, .cacheOrRequest, .waitingForModel, .processing:
                preconditionFailure("A nonterminal phase cannot produce terminal job state")
            }
            if llmJobQueue.jobs.contains(where: { $0.id == jobID }) {
                llmJobQueue.markTerminal(
                    id: jobID,
                    state: state,
                    stage: progress.stage,
                    detail: progress.detail,
                    chapterSummaryPhase: progress.phase
                )
            } else {
                llmJobQueue.recordTerminal(BackgroundJob(
                    id: jobID,
                    kind: .chapterSummary,
                    state: state,
                    bookID: origin.bookID,
                    bookTitle: origin.bookTitle,
                    chapterID: chapterID,
                    chapterTitle: origin.chapterTitle,
                    language: language ?? settings.targetLanguage,
                    stage: progress.stage,
                    detail: progress.detail,
                    fraction: nil,
                    chapterSummaryPhase: progress.phase
                ))
            }
        } else {
            llmJobQueue.update(
                id: jobID,
                stage: progress.stage,
                detail: progress.detail,
                fraction: progress.fraction,
                chapterSummaryPhase: progress.phase
            )
        }
        refreshLLMBusyState()
        Self.assistantLog.info(
            "message=chapter_summary_progress requestId=\(jobID.uuidString, privacy: .public) component=chapter-summary outcome=\(progress.phase.rawValue, privacy: .public) resource=\(chapterID, privacy: .private(mask: .hash))"
        )
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

    private func chapterTranslationBlockSize(for provider: LLMProvider) -> Int {
        FoundationModelsPromptPolicy.chapterTranslationBlockSize(
            for: provider,
            requested: settings.chapterTranslationBlockSize
        )
    }

    private func alignedSentenceBlock(
        around segment: TranscriptSegment,
        in transcript: Transcript
    ) -> [TranscriptSegment] {
        ChapterTranslationBatch.alignedBlock(
            containing: segment,
            in: transcript.segments,
            size: chapterTranslationBlockSize(for: llmProvider)
        )
    }

    private func neighborsOutside(
        block: [TranscriptSegment],
        in transcript: Transcript,
        radius: Int
    ) -> (previous: [String], next: [String]) {
        guard let first = block.first, let last = block.last,
              let start = transcript.segments.firstIndex(where: { $0.id == first.id }),
              let end = transcript.segments.firstIndex(where: { $0.id == last.id })
        else { return ([], []) }
        let previousStart = max(transcript.segments.startIndex, start - max(0, radius))
        let previous = Array(transcript.segments[previousStart..<start].map(\.displayText))
        let nextStart = end + 1
        let nextEnd = min(transcript.segments.endIndex, nextStart + max(0, radius))
        let next = nextStart < nextEnd ? Array(transcript.segments[nextStart..<nextEnd].map(\.displayText)) : []
        return (previous, next)
    }

    /// Translate (or hydrate from managed cache) the chapter-aligned sentence chunk.
    private func translateSentenceBlock(
        around segment: TranscriptSegment,
        forceIDs: Set<String>,
        generate: Bool,
        lookupOnly: Bool = false
    ) {
        guard let transcript = presentedTranscript else { return }
        let language = studyLanguage
        let block = alignedSentenceBlock(around: segment, in: transcript)
        let missing = block.filter { candidate in
            forceIDs.contains(candidate.id) || sentenceGloss(for: candidate, language: language.rawValue) == nil
        }
        guard !missing.isEmpty else { return }
        if lookupOnly, llmProvider != .managedQwen {
            return
        }
        if lookupOnly, llmConfigurationError(for: .managedQwen) != nil {
            return
        }
        let origin = selectedOrigin()
        guard !llmJobQueue.jobs.contains(where: {
            ($0.kind == .sentenceTranslation || $0.kind == .chapterTranslation)
                && $0.chapterID == origin.chapterID
        }) else { return }
        let hydrationKey = "\(origin.chapterID ?? "")|\(language.rawValue)|\(block.first?.id ?? segment.id)"
        if lookupOnly, managedHydrationKeys.contains(hydrationKey) {
            return
        }
        if lookupOnly {
            managedHydrationKeys.insert(hydrationKey)
            Task { @MainActor in
                await self.hydrateManagedSentenceBlock(
                    missing: missing,
                    block: block,
                    transcript: transcript,
                    origin: origin,
                    language: language,
                    generate: generate
                )
            }
            return
        }
        requestSentenceBlockTranslation(
            missing: missing,
            block: block,
            transcript: transcript,
            origin: origin,
            language: language,
            forceIDs: forceIDs,
            primaryID: segment.id
        )
    }

    private func hydrateManagedSentenceBlock(
        missing: [TranscriptSegment],
        block: [TranscriptSegment],
        transcript: Transcript,
        origin: BackgroundJobOrigin,
        language: StudyLanguage,
        generate: Bool
    ) async {
        guard llmProvider == .managedQwen, llmConfigurationError(for: .managedQwen) == nil else {
            if generate {
                requestSentenceBlockTranslation(
                    missing: missing,
                    block: block,
                    transcript: transcript,
                    origin: origin,
                    language: language,
                    forceIDs: [],
                    primaryID: missing.first?.id ?? block.first?.id ?? ""
                )
            }
            return
        }
        do {
            let neighbors = neighborsOutside(block: block, in: transcript, radius: settings.sentenceContextCount)
            let batch = try await ManagedProductLLM.translateBatch(
                sentences: missing.map { ProductTranslationSentence(id: $0.id, text: $0.displayText) },
                sourceLanguage: currentAudiobookLanguage.languageCode,
                targetLanguage: language.rawValue,
                learnerLevel: readerLanguageLevel.rawValue,
                contextBefore: ReadingAssistantPrompt.sentenceContext(
                    around: missing,
                    in: transcript,
                    radius: settings.sentenceContextCount
                ),
                contextPrevious: neighbors.previous,
                contextNext: neighbors.next,
                editionFingerprint: origin.bookID ?? "",
                chapterFingerprint: origin.chapterID ?? "",
                bookTitle: origin.bookTitle,
                author: origin.author,
                chapterTitle: origin.chapterTitle,
                lookupOnly: true
            )
            try applySentenceBlockResults(
                ManagedProductLLM.chapterResults(from: batch),
                segments: missing,
                language: language,
                model: selectedLLMModel,
                origin: origin,
                forceIDs: []
            )
        } catch {
            // Lookup-only must not surface a generation error; explicit translate still can.
        }
        guard generate else { return }
        let remaining = missing.filter { sentenceGloss(for: $0, language: language.rawValue) == nil }
        guard !remaining.isEmpty else { return }
        requestSentenceBlockTranslation(
            missing: remaining,
            block: block,
            transcript: transcript,
            origin: origin,
            language: language,
            forceIDs: [],
            primaryID: remaining.first?.id ?? ""
        )
    }

    private func requestSentenceBlockTranslation(
        missing: [TranscriptSegment],
        block: [TranscriptSegment],
        transcript: Transcript,
        origin: BackgroundJobOrigin,
        language: StudyLanguage,
        forceIDs: Set<String>,
        primaryID: String
    ) {
        guard !missing.isEmpty else { return }
        let provider = llmProvider
        if let configurationError = llmConfigurationError(for: provider) {
            translationError = configurationError.localizedDescription
            presentSettings()
            return
        }
        translationError = nil
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
        let metadata = bookMetadata(book: book, chapter: chapter)
        let neighbors = neighborsOutside(block: block, in: transcript, radius: sentenceContextCount)
        let prompt = ReadingAssistantPrompt.sentenceTranslation(
            language: language,
            sourceLanguage: sourceLanguage,
            readerLevel: readerLevel,
            metadata: metadata,
            context: ReadingAssistantPrompt.sentenceContext(
                around: missing,
                in: transcript,
                radius: sentenceContextCount
            ),
            targetIDs: missing.map(\.id)
        )
        let replacementPairs: [(String, String)] = missing.compactMap { segment in
            guard forceIDs.contains(segment.id),
                  let existing = sentenceGloss(for: segment, language: language.rawValue)
            else { return nil }
            return (segment.id, existing.id)
        }
        let replacementResultIDs = Dictionary(uniqueKeysWithValues: replacementPairs)
        enqueueLLMJob(
            kind: .sentenceTranslation,
            origin: origin,
            targetID: primaryID,
            detail: "Requesting \(model)…"
        ) { _ in
            do {
                let parsed: ChapterTranslationParseResult
                if provider == .managedQwen {
                    let batch = try await ManagedProductLLM.translateBatch(
                        sentences: missing.map {
                            ProductTranslationSentence(
                                id: $0.id,
                                text: $0.displayText,
                                assistantResultId: replacementResultIDs[$0.id]
                            )
                        },
                        sourceLanguage: sourceLanguage.languageCode,
                        targetLanguage: language.rawValue,
                        learnerLevel: readerLevel.rawValue,
                        contextBefore: ReadingAssistantPrompt.sentenceContext(
                            around: missing,
                            in: transcript,
                            radius: sentenceContextCount
                        ),
                        contextPrevious: neighbors.previous,
                        contextNext: neighbors.next,
                        editionFingerprint: book?.id ?? "",
                        chapterFingerprint: chapter?.id ?? "",
                        bookTitle: book?.title ?? "",
                        author: book?.author ?? "",
                        chapterTitle: chapter?.title ?? "",
                        refreshIds: Array(forceIDs)
                    )
                    let results = ManagedProductLLM.chapterResults(from: batch)
                    let found = Set(results.map(\.id))
                    parsed = ChapterTranslationParseResult(
                        results: results,
                        missingIDs: missing.map(\.id).filter { !found.contains($0) }
                    )
                } else {
                    let raw = try await GrokClient.shared.completeStructuredJSON(
                        provider: provider,
                        system: prompt.system,
                        user: prompt.user,
                        baseURL: baseURL,
                        model: model,
                        effort: effort,
                        enableThinking: enableThinking,
                        grokAuthentication: grokAuthentication,
                        openAIAuthentication: openAIAuthentication,
                        sourceLanguage: self.currentAudiobookLanguage.languageCode,
                        targetLanguage: self.settings.targetLanguage,
                        learnerLevel: self.readerLanguageLevel.rawValue,
                        chapterID: origin.chapterID ?? "",
                        bookTitle: origin.bookTitle,
                        author: origin.author,
                        chapterTitle: origin.chapterTitle
                    )
                    parsed = try ChapterTranslationBatch.parseAvailable(
                        raw,
                        expectedIDs: missing.map(\.id)
                    )
                }
                try self.applySentenceBlockResults(
                    parsed.results,
                    segments: missing,
                    language: language,
                    model: model,
                    origin: origin,
                    forceIDs: forceIDs
                )
                if !parsed.missingIDs.isEmpty, self.isSelected(origin) {
                    self.translationError = ChapterTranslationBatchError.missingSentences.localizedDescription
                }
            } catch {
                if self.isSelected(origin) {
                    self.translationError = error.localizedDescription
                }
            }
        }
    }

    private func applySentenceBlockResults(
        _ results: [ChapterTranslationResult],
        segments: [TranscriptSegment],
        language: StudyLanguage,
        model: String,
        origin: BackgroundJobOrigin,
        forceIDs: Set<String>
    ) throws {
        var entries: [GlossEntry] = []
        entries.reserveCapacity(results.count)
        for result in results {
            guard let segment = segments.first(where: { $0.id == result.id }) else { continue }
            let existing = sentenceGloss(for: segment, language: language.rawValue)
            let replaced = forceIDs.contains(segment.id) ? existing : nil
            entries.append(GlossEntry(
                id: result.assistantResultID ?? replaced?.id ?? UUID().uuidString.lowercased(),
                kind: .sentence,
                language: language.rawValue,
                source: segment.displayText,
                context: nil,
                text: result.glossText,
                status: replaced == nil ? .pending : .replaced,
                model: result.model ?? model,
                promptVersion: result.promptVersion ?? "local",
                modelPolicyHash: result.modelPolicyHash ?? "local",
                sharedCacheEntryID: result.sharedCacheEntryID,
                bookID: origin.bookID,
                bookTitle: origin.bookTitle,
                chapterID: origin.chapterID,
                chapterTitle: origin.chapterTitle,
                timestamp: segment.start,
                createdAt: Date(),
                decidedAt: nil,
                replacedText: replaced?.status == .accepted ? replaced?.text : nil,
                replacedModel: replaced?.status == .accepted ? replaced?.model : nil
            ))
        }
        try saveGlosses(entries)
        refreshSelectedChapterTranslationStatus()
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
        if kind == .sentence, let segment {
            translateSentenceBlock(
                around: segment,
                forceIDs: force ? [segment.id] : [],
                generate: true
            )
            return
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let replaced = prepareGlossReplacement(
            force: force,
            kind: kind,
            source: trimmed,
            context: context
        )
        let id = replaced?.id ?? UUID().uuidString.lowercased()
        let provider = llmProvider
        if let configurationError = llmConfigurationError(for: provider) {
            translationError = configurationError.localizedDescription
            presentSettings()
            return
        }
        if !force,
           let existing = lookupGloss(kind: kind, source: trimmed, context: context),
           existing.status == .accepted || existing.status == .pending || existing.status == .replaced {
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
        let openAIAuthentication = self.openAIAuthentication
        let grokAuthentication = self.grokAuthentication
        let book = selectedBook
        let chapter = selectedChapter
        let origin = selectedOrigin()
        let jobKind: BackgroundJob.Kind = .wordTranslation
        guard !llmJobQueue.jobs.contains(where: {
            $0.kind == jobKind && $0.chapterID == origin.chapterID && $0.targetID == targetID
        }) else { return }
        let translationContext = context ?? trimmed
        let prompt = LLMTaskPrompt(
            system: ReadingAssistantPrompt.word(
                language: language,
                sourceLanguage: sourceLanguage,
                readerLevel: readerLevel
            ),
            user: "Word: \(trimmed)\nSentence: \(translationContext)"
        )
        enqueueLLMJob(
            kind: jobKind,
            origin: origin,
            targetID: targetID,
            detail: "Requesting \(model)…"
        ) { _ in
            do {
                let text: String
                var resultID = id
                var resultModel = model
                var resultPromptVersion = "local"
                var resultModelPolicyHash = "local"
                var resultSharedCacheEntryID: String?
                if provider == .managedQwen {
                    // Dedicated product routes write assistant_cache_entries. Chat does not.
                    let result = try await ManagedProductLLM.translate(
                        task: "word",
                        source: trimmed,
                        sourceLanguage: sourceLanguage.languageCode,
                        targetLanguage: language.rawValue,
                        learnerLevel: readerLevel.rawValue,
                        targetID: targetID,
                        context: context,
                        editionFingerprint: book?.id ?? "",
                        chapterFingerprint: chapter?.id ?? "",
                        bookTitle: book?.title ?? "",
                        author: book?.author ?? "",
                        chapterTitle: chapter?.title ?? "",
                        refresh: force,
                        assistantResultID: replaced?.id
                    )
                    text = ManagedProductLLM.wordMeaningText(from: result)
                    resultID = result.id
                    resultModel = result.model ?? model
                    resultPromptVersion = result.promptVersion ?? result.policyVersion
                    resultModelPolicyHash = result.modelPolicyHash ?? "local"
                    resultSharedCacheEntryID = result.sharedCacheEntryID
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
                    id: resultID,
                    kind: kind,
                    language: language.rawValue,
                    source: trimmed,
                    context: context,
                    text: text,
                    status: replaced == nil ? .pending : .replaced,
                    model: resultModel,
                    promptVersion: resultPromptVersion,
                    modelPolicyHash: resultModelPolicyHash,
                    sharedCacheEntryID: resultSharedCacheEntryID,
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
                try self.saveGloss(entry)
            } catch {
                if let replaced {
                    try? self.saveGloss(replaced)
                }
                if self.isSelected(origin) {
                    self.translationError = error.localizedDescription
                }
            }
        }
    }

    func translateChapter(mode: ChapterTranslationMode = .untranslatedOnly) {
        guard let transcript = completeTranscriptForChapterAssistant(), !transcript.segments.isEmpty else {
            chapterAssistantError = "Transcribe this chapter before translating it."
            return
        }
        account.recordUsage(
            name: "ai.chapter_translation.requested",
            properties: ["mode": mode.rawValue]
        )
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
            presentSettings()
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
        guard saveTranslationCheckpoint(
            chapterID: checkpointChapterID,
            language: language.rawValue,
            mode: resumedMode,
            nextSegmentIndex: startIndex,
            total: transcript.segments.count,
            status: .inProgress
        ) else {
            chapterAssistantError = "Translation could not start because its resume checkpoint was not saved."
            chapterTranslationProgress = nil
            chapterTranslationJobOrigin = nil
            return
        }

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
                        let parsed: ChapterTranslationParseResult
                        if provider == .managedQwen {
                            let neighbors = self.neighborsOutside(
                                block: block,
                                in: transcript,
                                radius: sentenceContextCount
                            )
                            let batch = try await ManagedProductLLM.translateBatch(
                                sentences: remaining.map {
                                    ProductTranslationSentence(
                                        id: $0.id,
                                        text: $0.displayText,
                                        assistantResultId: resumedMode == .retranslateAll
                                            ? self.sentenceGloss(for: $0, language: language.rawValue)?.id
                                            : nil
                                    )
                                },
                                sourceLanguage: sourceLanguage.languageCode,
                                targetLanguage: language.rawValue,
                                learnerLevel: readerLevel.rawValue,
                                contextBefore: ReadingAssistantPrompt.sentenceContext(
                                    around: remaining,
                                    in: transcript,
                                    radius: sentenceContextCount
                                ),
                                contextPrevious: neighbors.previous,
                                contextNext: neighbors.next,
                                editionFingerprint: book?.id ?? "",
                                chapterFingerprint: chapter?.id ?? "",
                                bookTitle: book?.title ?? "",
                                author: book?.author ?? "",
                                chapterTitle: chapter?.title ?? "",
                                refreshIds: resumedMode == .retranslateAll ? remaining.map(\.id) : []
                            )
                            let results = ManagedProductLLM.chapterResults(from: batch)
                            let found = Set(results.map(\.id))
                            parsed = ChapterTranslationParseResult(
                                results: results,
                                missingIDs: remaining.map(\.id).filter { !found.contains($0) }
                            )
                        } else {
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
                            parsed = try ChapterTranslationBatch.parseAvailable(
                                raw,
                                expectedIDs: remaining.map(\.id)
                            )
                        }
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
                        let missing = Set(parsed.missingIDs)
                        let nextRemaining = remaining.filter { missing.contains($0.id) }
                        let nextIndex = nextRemaining.first.flatMap { pending in
                            transcript.segments.firstIndex { $0.id == pending.id }
                        } ?? ((block.compactMap { item in
                            transcript.segments.firstIndex { $0.id == item.id }
                        }.max() ?? startIndex) + 1)
                        try self.saveGeneratedChapterDrafts(
                            completedEntries,
                            chapterID: checkpointChapterID,
                            language: language.rawValue,
                            mode: resumedMode,
                            nextSegmentIndex: nextIndex,
                            total: transcript.segments.count
                        )
                        completed += completedEntries.count
                        remaining = nextRemaining
                        if !nextRemaining.isEmpty {
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
                    if self.isSelected(origin) {
                        self.chapterTranslationFailed = true
                        self.chapterAssistantError = "Translation paused after \(ChapterTranslationBatch.maximumAttempts) attempts. \(remaining.count) sentence(s) in this block still need translation. Last issue: \(lastIssue)"
                        self.chapterTranslation = "\(completed) finished sentence draft(s) were checkpointed. Retry resumes with the remaining sentences only."
                    }
                    break
                }
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
        pendingChapterSentenceGlosses(in: transcript)
    }

    private func pendingChapterSentenceGlosses(in transcript: Transcript?) -> [GlossEntry] {
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
        let acceptedTranscript = completeTranscriptForChapterAssistant()
        let entries = pendingChapterSentenceGlosses(in: acceptedTranscript)
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
        let vocabSnapshot = vocab
        let acceptedChapterID = selectedChapterID
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

            chapterAcceptanceProgress = .init(
                stage: "Saving translations",
                detail: "Writing vocabulary and translation updates…",
                completed: accepted.count,
                total: accepted.count
            )
            let vocabulary = vocabularyRepository
            let storedVocabUpdates = result.upserts.map(StoredVocabularyOccurrence.init)
            let database = liveDatabase
            let saveSucceeded = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    if let database {
                        try Persistence.acceptGlosses(
                            accepted,
                            vocabulary: result.upserts,
                            database: database
                        )
                    } else {
                        try vocabulary.upsertVocabulary(storedVocabUpdates)
                    }
                    return true
                } catch {
                    return false
                }
            }.value
            guard chapterAcceptanceID == operationID else { return }
            if !saveSucceeded {
                errorMessage = "The chapter decisions could not be saved. Nothing was changed."
                chapterAcceptanceProgress = nil
                chapterAcceptanceID = nil
                return
            }
            glosses = GlossBatch.merging(accepted, into: glosses)
            mergeVocabUpserts(result.upserts, orderedAs: result.vocab)

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

    @discardableResult
    private func saveTranslationCheckpoint(
        chapterID: String,
        language: String,
        mode: ChapterTranslationMode? = nil,
        nextSegmentIndex: Int,
        total: Int,
        status: ChapterTranslationStatus
    ) -> Bool {
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
        var updated = chapterTranslationCheckpoints
        if let index = updated.firstIndex(where: { $0.id == checkpoint.id }) {
            updated[index] = checkpoint
        } else {
            updated.append(checkpoint)
        }
        if usesLivePersistence {
            guard let database = liveDatabase else { return false }
            do {
                try Persistence.saveChapterTranslationCheckpoint(checkpoint, database: database)
            } catch {
                return false
            }
        }
        chapterTranslationCheckpoints = updated
        return true
    }

    /// Chapter drafts and their resume cursor publish only after the shared
    /// SQLite transaction commits both records.
    func saveGeneratedChapterDrafts(
        _ entries: [GlossEntry],
        chapterID: String,
        language: String,
        mode: ChapterTranslationMode,
        nextSegmentIndex: Int,
        total: Int
    ) throws {
        let checkpoint = ChapterTranslationCheckpoint(
            chapterID: chapterID,
            language: language,
            mode: mode,
            nextSegmentIndex: nextSegmentIndex,
            totalSentences: total,
            status: .inProgress,
            updatedAt: Date()
        )
        let updatedGlosses = GlossBatch.merging(entries, into: glosses)
        var updatedCheckpoints = chapterTranslationCheckpoints
        if let index = updatedCheckpoints.firstIndex(where: { $0.id == checkpoint.id }) {
            updatedCheckpoints[index] = checkpoint
        } else {
            updatedCheckpoints.append(checkpoint)
        }
        if let database = liveDatabase {
            try Persistence.saveGeneratedTranslationDrafts(
                entries,
                checkpoint: checkpoint,
                database: database
            )
        }
        glosses = updatedGlosses
        chapterTranslationCheckpoints = updatedCheckpoints
    }

    private func refreshSelectedChapterTranslationStatus() {
        guard let transcript = completeTranscriptForChapterAssistant(), !transcript.segments.isEmpty, let chapterID = selectedChapterID else { return }
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

    func summarizeChapter(force: Bool = false) {
        guard let transcript = completeTranscriptForChapterAssistant(), !transcript.segments.isEmpty else {
            chapterAssistantError = "Transcribe this chapter before summarising it."
            return
        }
        account.recordUsage(name: "ai.summary.requested")
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
            $0.chapterID == chapterID && $0.language == language && $0.status != .rejected
        }
        let metadata = bookMetadata(book: selectedBook, chapter: selectedChapter)
        enqueueChapterAssistant(
            kind: .chapterSummary,
            origin: origin,
            targetID: force ? existing?.id : nil,
            system: system,
            user: fullChapterInput(transcript, metadata: metadata),
            refresh: force
        ) { summary, identity in
            let presentation = try ChapterSummaryPresentation.parse(summary)
            let record = ChapterSummaryRecord.pending(
                summary: presentation,
                language: language,
                model: identity?.model ?? model,
                bookID: origin.bookID,
                bookTitle: origin.bookTitle,
                chapterID: chapterID,
                chapterTitle: origin.chapterTitle,
                replacing: existing,
                assistantResultID: identity?.id,
                promptVersion: identity?.promptVersion ?? identity?.policyVersion ?? "local",
                modelPolicyHash: identity?.modelPolicyHash ?? "local",
                sharedCacheEntryID: identity?.sharedCacheEntryID
            )
            try self.persistAndPublishChapterSummary(record, origin: origin)
        }
    }

    func acceptChapterSummary() {
        guard let chapterSummary,
              chapterSummary.status == .pending || chapterSummary.status == .replaced
        else { return }
        saveChapterSummary(chapterSummary.accept(at: Date()), origin: selectedOrigin())
    }

    func rejectChapterSummary() {
        guard let chapterSummary,
              chapterSummary.status == .pending || chapterSummary.status == .replaced
        else { return }
        let reviewed = chapterSummary.reject(at: Date())
        if saveChapterSummary(reviewed, origin: selectedOrigin()), reviewed.status == .rejected {
            self.chapterSummary = nil
        }
    }

    @discardableResult
    private func saveChapterSummary(
        _ summary: ChapterSummaryRecord,
        origin: BackgroundJobOrigin
    ) -> Bool {
        do {
            try persistAndPublishChapterSummary(summary, origin: origin)
            return true
        } catch {
            chapterAssistantError = error.localizedDescription
            errorMessage = "The chapter summary could not be saved. Nothing was changed."
            return false
        }
    }

    /// Publish only after the injected or live persistence boundary confirms a durable save.
    private func persistAndPublishChapterSummary(
        _ summary: ChapterSummaryRecord,
        origin: BackgroundJobOrigin
    ) throws {
        if let chapterSummarySaver {
            try chapterSummarySaver.save(summary)
        } else if let database = liveDatabase {
            try Persistence.saveChapterSummaryUpdate(summary, database: database)
        }
        if let index = chapterSummaries.firstIndex(where: { $0.id == summary.id }) {
            chapterSummaries[index] = summary
        } else {
            chapterSummaries.append(summary)
        }
        if isSelected(origin) {
            chapterSummary = summary.status == .rejected ? nil : summary
        }
    }

    func sendChapterChat(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        account.recordUsage(name: "ai.chat.requested")
        guard let transcript = presentedTranscript else {
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
        ) { answer, _ in
            var messages = self.chapterChatsByChapterID[chapterID] ?? []
            messages.append(.init(role: .assistant, text: answer))
            self.chapterChatsByChapterID[chapterID] = messages
            if self.isSelected(origin) {
                self.chapterChat = messages
            }
        }
    }

    func ensureCachedChapterSummary() {
        guard llmProvider == .managedQwen else { return }
        guard llmConfigurationError(for: .managedQwen) == nil else { return }
        guard chapterSummary == nil else { return }
        guard let transcript = presentedTranscript, !transcript.segments.isEmpty else { return }
        let origin = selectedOrigin()
        guard let chapterID = origin.chapterID else { return }
        let hydrationKey = "summary|\(chapterID)|\(settings.targetLanguage)"
        guard !managedHydrationKeys.contains(hydrationKey) else { return }
        guard !llmJobQueue.jobs.contains(where: {
            $0.kind == .chapterSummary && $0.chapterID == chapterID
        }) else { return }
        managedHydrationKeys.insert(hydrationKey)
        let language = settings.targetLanguage
        let model = selectedLLMModel
        let segments = transcript.segments.map(\.displayText)
        let existing = chapterSummaries.first {
            $0.chapterID == chapterID && $0.language == language && $0.status != .rejected
        }
        Task { @MainActor in
            do {
                guard let identity = try await ManagedProductLLM.lookupSummary(
                    chapterID: chapterID,
                    sourceLanguage: self.currentAudiobookLanguage.languageCode,
                    targetLanguage: language,
                    learnerLevel: self.readerLanguageLevel.rawValue,
                    segments: segments,
                    editionFingerprint: origin.bookID ?? "",
                    bookTitle: origin.bookTitle,
                    author: origin.author,
                    chapterTitle: origin.chapterTitle
                ) else { return }
                let presentation = try ChapterSummaryPresentation.parse(
                    ManagedProductLLM.summaryText(from: identity)
                )
                let record = ChapterSummaryRecord.pending(
                    summary: presentation,
                    language: language,
                    model: identity.model ?? model,
                    bookID: origin.bookID,
                    bookTitle: origin.bookTitle,
                    chapterID: chapterID,
                    chapterTitle: origin.chapterTitle,
                    replacing: existing,
                    assistantResultID: identity.id,
                    promptVersion: identity.promptVersion ?? identity.policyVersion ?? "local",
                    modelPolicyHash: identity.modelPolicyHash ?? "local",
                    sharedCacheEntryID: identity.sharedCacheEntryID
                )
                self.saveChapterSummary(record, origin: origin)
            } catch {
                // Cache hydration is best-effort; explicit Summarise still reports errors.
            }
        }
    }

    private func enqueueChapterAssistant(
        kind: BackgroundJob.Kind,
        origin: BackgroundJobOrigin,
        targetID: String? = nil,
        system: String,
        user: String,
        refresh: Bool = false,
        structuredJSON: Bool = false,
        heardQuizSegments: [ProductHeardSegment]? = nil,
        completion: @escaping @MainActor (String, ProductChapterSummary?) throws -> Void,
        failure: (@MainActor () -> Void)? = nil
    ) {
        let jobID = UUID()
        let progressLanguage = settings.targetLanguage
        let provider = llmProvider
        let usesInjectedSummaryExecutor = kind == .chapterSummary && chapterSummaryExecutor != nil
        if !usesInjectedSummaryExecutor,
           let configurationError = llmConfigurationError(for: provider) {
            if kind == .chapterSummary {
                recordChapterSummaryProgress(
                    ChapterSummaryProgress(
                        phase: .failed,
                        detail: configurationError.localizedDescription
                    ),
                    jobID: jobID,
                    origin: origin,
                    language: progressLanguage
                )
            }
            if let failure {
                failure()
                return
            }
            chapterAssistantError = configurationError.localizedDescription
            presentSettings()
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
        let initialSummaryProgress = ChapterSummaryProgress(
            phase: .preparing,
            detail: "Preparing chapter and reading context…"
        )
        let enqueuedJob = enqueueLLMJob(
            id: jobID,
            kind: kind,
            origin: origin,
            targetID: targetID,
            language: kind == .chapterSummary ? progressLanguage : nil,
            stage: kind == .chapterSummary ? initialSummaryProgress.stage : nil,
            detail: kind == .chapterSummary ? initialSummaryProgress.detail : "Requesting \(model)…",
            chapterSummaryPhase: kind == .chapterSummary ? initialSummaryProgress.phase : nil
        ) { jobID in
            if kind == .chapterSummary {
                self.recordChapterSummaryProgress(
                    initialSummaryProgress,
                    jobID: jobID,
                    origin: origin,
                    language: progressLanguage
                )
                let requestProgress: ChapterSummaryProgress
                if provider == .managedQwen {
                    requestProgress = ChapterSummaryProgress(
                        phase: .cacheOrRequest,
                        detail: refresh
                            ? "Requesting a fresh summary from \(model). Model progress is indeterminate."
                            : "Checking the shared cache first; \(model) will generate a summary if needed. Model progress is indeterminate."
                    )
                } else {
                    requestProgress = ChapterSummaryProgress(
                        phase: .waitingForModel,
                        detail: "Waiting for \(model). Model progress is indeterminate."
                    )
                }
                self.recordChapterSummaryProgress(
                    requestProgress,
                    jobID: jobID,
                    origin: origin,
                    language: progressLanguage
                )
            }
            do {
                let result: String
                var summaryIdentity: ProductChapterSummary?
                if kind == .chapterSummary, let chapterSummaryExecutor = self.chapterSummaryExecutor {
                    let execution = try await chapterSummaryExecutor.execute(ChapterSummaryExecutionRequest(
                        provider: provider,
                        model: model,
                        origin: origin,
                        system: system,
                        user: user,
                        refresh: refresh,
                        targetID: targetID
                    ))
                    result = execution.text
                    summaryIdentity = execution.identity
                } else if provider == .managedQwen, let heardQuizSegments {
                    result = try await ManagedProductLLM.heardQuiz(
                        chapterID: origin.chapterID ?? "",
                        sourceLanguage: self.currentAudiobookLanguage.languageCode,
                        targetLanguage: self.settings.targetLanguage,
                        learnerLevel: self.readerLanguageLevel.rawValue,
                        segments: heardQuizSegments,
                        bookTitle: origin.bookTitle,
                        author: origin.author,
                        chapterTitle: origin.chapterTitle
                    )
                } else if provider == .managedQwen, kind == .chapterSummary {
                    let transcript = origin.chapterID.flatMap {
                        Persistence.loadTranscript(chapterID: $0, database: self.transcriptRepository)
                    }
                        ?? self.transcript
                    let segments = transcript?.segments.map(\.displayText) ?? []
                    let summary = try await ManagedProductLLM.summarizeResult(
                        chapterID: origin.chapterID ?? "",
                        sourceLanguage: self.currentAudiobookLanguage.languageCode,
                        targetLanguage: self.settings.targetLanguage,
                        learnerLevel: self.readerLanguageLevel.rawValue,
                        segments: segments,
                        editionFingerprint: origin.bookID ?? self.selectedBookID ?? "",
                        bookTitle: origin.bookTitle,
                        author: origin.author,
                        chapterTitle: origin.chapterTitle,
                        refresh: refresh,
                        assistantResultID: refresh ? targetID : nil
                    )
                    summaryIdentity = summary
                    result = ManagedProductLLM.summaryText(from: summary)
                } else if structuredJSON {
                    result = try await GrokClient.shared.completeStructuredJSON(
                        provider: provider,
                        system: system,
                        user: user,
                        baseURL: baseURL,
                        model: model,
                        effort: effort,
                        enableThinking: enableThinking,
                        grokAuthentication: grokAuthentication,
                        openAIAuthentication: openAIAuthentication,
                        sourceLanguage: self.currentAudiobookLanguage.languageCode,
                        targetLanguage: self.settings.targetLanguage,
                        learnerLevel: self.readerLanguageLevel.rawValue,
                        chapterID: origin.chapterID ?? "",
                        bookTitle: origin.bookTitle,
                        author: origin.author,
                        chapterTitle: origin.chapterTitle
                    )
                } else {
                    result = try await GrokClient.shared.complete(
                        provider: provider,
                        system: system,
                        user: user,
                        baseURL: baseURL,
                        model: model,
                        effort: effort,
                        enableThinking: enableThinking,
                        grokAuthentication: grokAuthentication,
                        openAIAuthentication: openAIAuthentication,
                        sourceLanguage: self.currentAudiobookLanguage.languageCode,
                        targetLanguage: self.settings.targetLanguage,
                        learnerLevel: self.readerLanguageLevel.rawValue,
                        chapterID: origin.chapterID ?? "",
                        bookTitle: origin.bookTitle,
                        author: origin.author,
                        chapterTitle: origin.chapterTitle
                    )
                }
                if kind == .chapterSummary {
                    let usedCache = summaryIdentity?.provenance.hasPrefix("cache") == true
                    self.recordChapterSummaryProgress(
                        ChapterSummaryProgress(
                            phase: .processing,
                            detail: usedCache
                                ? "Cached summary found. Parsing and saving it for review…"
                                : "Model response received. Parsing and saving it for review…"
                        ),
                        jobID: jobID,
                        origin: origin,
                        language: progressLanguage
                    )
                }
                try completion(result, summaryIdentity)
                if kind == .chapterSummary {
                    let usedCache = summaryIdentity?.provenance.hasPrefix("cache") == true
                    self.recordChapterSummaryProgress(
                        ChapterSummaryProgress(
                            phase: .completed,
                            detail: usedCache
                                ? "Cached summary saved and ready for review."
                                : "Summary saved and ready for review."
                        ),
                        jobID: jobID,
                        origin: origin,
                        language: progressLanguage
                    )
                }
            } catch {
                let cancelled = error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                    || Task.isCancelled
                if kind == .chapterSummary {
                    self.recordChapterSummaryProgress(
                        ChapterSummaryProgress(
                            phase: cancelled ? .cancelled : .failed,
                            detail: cancelled
                                ? "The summary request was cancelled."
                                : error.localizedDescription
                        ),
                        jobID: jobID,
                        origin: origin,
                        language: progressLanguage
                    )
                }
                if !cancelled {
                    if let chapterID = origin.chapterID {
                        self.chapterAssistantErrorsByChapterID[chapterID] = error.localizedDescription
                    }
                    if self.isSelected(origin) {
                        self.chapterAssistantError = error.localizedDescription
                    }
                }
                failure?()
            }
        }
        if kind == .chapterSummary {
            let enqueuedProgress = enqueuedJob.state == .queued
                ? ChapterSummaryProgress(
                    phase: .queued,
                    detail: "Waiting for a chapter summary slot…"
                )
                : initialSummaryProgress
            recordChapterSummaryProgress(
                enqueuedProgress,
                jobID: jobID,
                origin: origin,
                language: progressLanguage
            )
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

    private func saveGloss(_ entry: GlossEntry) throws {
        try saveGlosses([entry])
    }

    private func saveGlosses(_ entries: [GlossEntry]) throws {
        guard !entries.isEmpty else { return }
        let updated = GlossBatch.merging(entries, into: glosses)
        if usesLivePersistence {
            guard let database = liveDatabase else { return }
            try Persistence.saveGlossUpdates(
                entries,
                allItems: updated,
                database: database
            )
        }
        glosses = updated
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
                let canonicalization = VocabularyCanonicalizer.canonicalize(
                    surfaceForm: gloss.source,
                    context: original,
                    language: sourceLanguage ?? "und"
                )
                vocab.insert(
                    VocabEntry(
                        id: UUID().uuidString,
                        word: gloss.source,
                        canonicalForm: canonicalization.canonicalForm,
                        partOfSpeech: canonicalization.partOfSpeech,
                        senseID: canonicalization.senseID,
                        canonicalizationSource: canonicalization.source,
                        canonicalizationConfidence: canonicalization.confidence,
                        canonicalizationStatus: canonicalization.status,
                        canonicalizationTraceID: canonicalization.traceID,
                        captureSource: .explicitWord,
                        reviewEligible: true,
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
                        canonicalForm: gloss.source,
                        partOfSpeech: .sentence,
                        canonicalizationConfidence: 1,
                        canonicalizationStatus: .confirmed,
                        captureSource: .acceptedSentenceTranslation,
                        reviewEligible: false,
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
                let canonicalization = VocabularyCanonicalizer.canonicalize(
                    surfaceForm: phrase.phrase,
                    context: gloss.source,
                    language: sourceLanguage ?? "und"
                )
                vocab.insert(
                    VocabEntry(
                        id: UUID().uuidString,
                        word: phrase.phrase,
                        canonicalForm: canonicalization.canonicalForm,
                        partOfSpeech: canonicalization.partOfSpeech,
                        senseID: canonicalization.senseID,
                        canonicalizationSource: canonicalization.source,
                        canonicalizationConfidence: canonicalization.confidence,
                        canonicalizationStatus: canonicalization.status,
                        canonicalizationTraceID: canonicalization.traceID,
                        captureSource: .automaticPhraseSuggestion,
                        reviewEligible: false,
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
        guard let transcript = presentedTranscript else { return }
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

#if DEBUG
extension AppState {
    /// Produces a completed-sentence pause without touching a user's media or provider credentials.
    func prepareUITestListenFirstPause(segmentID: String, time: TimeInterval) {
        settings.deepReadingMode = true
        player.currentTime = time
        deepReadingActiveSentenceID = nil
        deepReadingPausedSentenceID = segmentID
    }
}
#endif

private struct PendingReveal {
    var kind: TextRevealKind
    var timestamp: TimeInterval
    var segmentID: String?
    var wordID: String?
    var wordText: String?
    var sentenceText: String?
}
