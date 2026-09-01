import Foundation
import Testing
@testable import AudioReader

struct BackgroundJobSchedulerTests {
    private let origin = BackgroundJobOrigin(
        bookID: "book-1",
        bookTitle: "The Book",
        chapterID: "chapter-1",
        chapterTitle: "The Chapter"
    )

    @Test("A third job of the same LLM kind waits in FIFO order")
    func thirdSameKindQueues() {
        var queue = BackgroundJobQueue(maxConcurrentPerKind: 2)
        let ids = (1...3).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }

        for id in ids {
            queue.enqueue(id: id, kind: .sentenceTranslation, origin: origin)
        }

        #expect(queue.jobs.map(\.id) == ids)
        #expect(Set(queue.jobs.map(\.id)).count == 3)
        #expect(queue.jobs.map(\.state) == [.running, .running, .queued])
    }

    @Test("Different LLM kinds do not consume each other's slots")
    func differentKindsRunIndependently() {
        var queue = BackgroundJobQueue(maxConcurrentPerKind: 2)

        for index in 1...3 {
            queue.enqueue(
                id: UUID(uuidString: "10000000-0000-0000-0000-00000000000\(index)")!,
                kind: .wordTranslation,
                origin: origin
            )
        }
        let chat = queue.enqueue(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            kind: .chapterChat,
            origin: origin
        )

        #expect(queue.jobs.last?.id == chat.id)
        #expect(chat.state == .running)
        #expect(queue.runningJobs(of: .wordTranslation).count == 2)
        #expect(queue.runningJobs(of: .chapterChat).count == 1)
    }

    @Test("Completing a running job promotes exactly the oldest queued job of that kind")
    func completionPromotesExactlyOne() {
        var queue = BackgroundJobQueue(maxConcurrentPerKind: 2)
        let ids = (1...4).map { UUID(uuidString: "30000000-0000-0000-0000-00000000000\($0)")! }
        for id in ids {
            queue.enqueue(id: id, kind: .chapterSummary, origin: origin)
        }

        let promotedID = queue.finish(id: ids[0])

        #expect(promotedID == ids[2])
        #expect(queue.jobs.map(\.id) == [ids[1], ids[2], ids[3]])
        #expect(queue.jobs.map(\.state) == [.running, .running, .queued])
    }

    @Test("Queued and running records remain visible with stable origins and progress")
    func queuedAndRunningRecordsAreVisible() {
        var queue = BackgroundJobQueue(maxConcurrentPerKind: 2)
        let firstID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        queue.enqueue(id: firstID, kind: .chapterTranslation, origin: origin)
        queue.enqueue(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            kind: .chapterTranslation,
            origin: origin
        )
        queue.enqueue(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000003")!,
            kind: .chapterTranslation,
            origin: origin
        )
        queue.update(
            id: firstID,
            stage: "Translating chapter",
            detail: "4 of 10 drafts ready",
            fraction: 0.4
        )

        let visible = queue.jobs
        #expect(visible.count == 3)
        #expect(visible[0].origin == origin)
        #expect(visible[0].detail == "4 of 10 drafts ready")
        #expect(visible[0].fraction == 0.4)
        #expect(visible[2].state == .queued)
        #expect(visible[2].detail == "Waiting for a chapter translation slot…")
    }

    @Test("Chapter summary phases stay indeterminate while their detail remains meaningful")
    func chapterSummaryPhasesAreTruthfullyIndeterminate() {
        let phases = ChapterSummaryProgress.Phase.allCases.map {
            ChapterSummaryProgress(phase: $0, detail: "Phase detail")
        }

        #expect(phases.allSatisfy { $0.fraction == nil })
        #expect(ChapterSummaryProgress(phase: .queued, detail: "Queued").stage == "Chapter summary queued")
        #expect(ChapterSummaryProgress(phase: .preparing, detail: "Context").stage == "Preparing chapter summary")
        #expect(ChapterSummaryProgress(phase: .cacheOrRequest, detail: "Cache").stage == "Checking cache or requesting summary")
        #expect(ChapterSummaryProgress(phase: .waitingForModel, detail: "Model").stage == "Waiting for model")
        #expect(ChapterSummaryProgress(phase: .processing, detail: "Saving").stage == "Processing chapter summary")
        #expect(ChapterSummaryProgress(phase: .completed, detail: "Ready").isTerminal)
        #expect(ChapterSummaryProgress(phase: .failed, detail: "Failed").isTerminal)
        #expect(ChapterSummaryProgress(phase: .cancelled, detail: "Cancelled").isTerminal)
    }

    @MainActor
    @Test("Selected chapter summary progress updates the shared job and retains a terminal outcome")
    func selectedChapterSummaryProgressSharesJobLifecycle() {
        let state = AppState()
        state.selectedChapterID = "chapter-1"
        let job = state.llmJobQueue.enqueue(
            kind: .chapterSummary,
            origin: origin,
            language: state.settings.targetLanguage,
            stage: "Preparing chapter summary",
            detail: "Preparing chapter and reading context…",
            chapterSummaryPhase: .preparing
        )
        let waiting = ChapterSummaryProgress(
            phase: .waitingForModel,
            detail: "Waiting for Test Model. Model progress is indeterminate."
        )

        state.recordChapterSummaryProgress(waiting, jobID: job.id, origin: origin)

        #expect(state.selectedChapterSummaryJob?.chapterSummaryPhase == waiting.phase)
        #expect(state.llmJobQueue.jobs.first?.stage == waiting.stage)
        #expect(state.llmJobQueue.jobs.first?.detail == waiting.detail)
        #expect(state.llmJobQueue.jobs.first?.fraction == nil)

        let requestedLanguage = state.settings.targetLanguage
        state.settings.targetLanguage = requestedLanguage == "ko" ? "zh-Hans" : "ko"
        #expect(state.selectedChapterSummaryJob == nil)
        state.settings.targetLanguage = requestedLanguage

        _ = state.llmJobQueue.finish(id: job.id)
        let completed = ChapterSummaryProgress(
            phase: .completed,
            detail: "Summary saved and ready for review."
        )
        state.recordChapterSummaryProgress(completed, jobID: job.id, origin: origin)

        #expect(state.selectedChapterSummaryJob?.chapterSummaryPhase == completed.phase)
        #expect(state.selectedChapterSummaryJob?.id == job.id)
        #expect(!state.isLLMJobActive(kind: .chapterSummary))

        let retryJob = state.llmJobQueue.enqueue(
            kind: .chapterSummary,
            origin: origin,
            language: state.settings.targetLanguage
        )
        let retry = ChapterSummaryProgress(
            phase: .preparing,
            detail: "Preparing chapter and reading context…"
        )
        state.recordChapterSummaryProgress(retry, jobID: retryJob.id, origin: origin)
        #expect(state.selectedChapterSummaryJob?.chapterSummaryPhase == retry.phase)
        #expect(state.selectedChapterSummaryJob?.id == retryJob.id)
    }

    @Test("Selected-chapter busy state changes deterministically with selection")
    func projectsBusyStateForSelectedChapter() {
        var queue = BackgroundJobQueue(maxConcurrentPerKind: 2)
        let secondOrigin = BackgroundJobOrigin(
            bookID: "book-2",
            bookTitle: "Other Book",
            chapterID: "chapter-2",
            chapterTitle: "Other Chapter"
        )
        queue.enqueue(kind: .sentenceTranslation, origin: origin)
        queue.enqueue(kind: .chapterSummary, origin: secondOrigin)

        let first = queue.presentation(forChapterID: "chapter-1")
        let second = queue.presentation(forChapterID: "chapter-2")
        let missing = queue.presentation(forChapterID: "missing")

        #expect(first.isTranslating)
        #expect(!first.isChapterAssistantWorking)
        #expect(!second.isTranslating)
        #expect(second.isChapterAssistantWorking)
        #expect(!missing.isTranslating)
        #expect(!missing.isChapterAssistantWorking)
    }

    @Test("Selected chapter translation presentation distinguishes queued from running")
    func projectsQueuedAndRunningChapterTranslations() {
        var queue = BackgroundJobQueue(maxConcurrentPerKind: 2)
        let origins = (1...3).map { index in
            BackgroundJobOrigin(
                bookID: "book-\(index)",
                bookTitle: "Book \(index)",
                chapterID: "chapter-\(index)",
                chapterTitle: "Chapter \(index)"
            )
        }
        for origin in origins {
            queue.enqueue(kind: .chapterTranslation, origin: origin)
        }

        #expect(queue.presentation(forChapterID: "chapter-1").chapterTranslationState == .running)
        #expect(queue.presentation(forChapterID: "chapter-3").chapterTranslationState == .queued)
    }

    @MainActor
    @Test("Refreshing AppState recomputes busy flags after chapter selection changes")
    func refreshesAppStateForSelectionChanges() {
        let state = AppState()
        state.llmJobQueue.enqueue(kind: .wordTranslation, origin: origin)
        state.selectedChapterID = "chapter-1"
        state.refreshLLMBusyState()
        #expect(state.isTranslating)
        #expect(!state.isChapterAssistantWorking)

        state.selectedChapterID = "chapter-2"
        state.refreshLLMBusyState()
        #expect(!state.isTranslating)
        #expect(!state.isChapterAssistantWorking)
    }

    @MainActor
    @Test("A queued selected chapter translation cannot pretend to stop after a block")
    func queuedChapterTranslationDoesNotExposeStopState() {
        let state = AppState()
        for index in 1...3 {
            state.llmJobQueue.enqueue(
                kind: .chapterTranslation,
                origin: BackgroundJobOrigin(
                    bookID: "book-\(index)",
                    bookTitle: "Book \(index)",
                    chapterID: "chapter-\(index)",
                    chapterTitle: "Chapter \(index)"
                )
            )
        }
        state.selectedChapterID = "chapter-3"
        state.refreshLLMBusyState()
        let queuedDetail = state.chapterTranslationProgress?.detail

        state.requestChapterTranslationStop()

        #expect(state.selectedChapterTranslationJobState == .queued)
        #expect(!state.chapterTranslationStopRequested)
        #expect(state.chapterTranslationProgress?.detail == queuedDetail)
    }

    @MainActor
    @Test("Forced replacement keeps an accepted gloss visible while work waits")
    func forcedReplacementRetainsAcceptedGloss() {
        let state = AppState()
        state.settings.targetLanguage = "zh-Hans"
        let source = "A sentence."
        let accepted = GlossEntry(
            id: GlossEntry.makeID(kind: .sentence, language: "zh-Hans", source: source, context: nil),
            kind: .sentence,
            language: "zh-Hans",
            source: source,
            context: nil,
            text: "旧译文。",
            status: .accepted,
            model: "old-model",
            createdAt: Date()
        )
        state.glosses = [accepted]

        let replaced = state.prepareGlossReplacement(
            force: true,
            kind: .sentence,
            source: source,
            context: nil
        )

        #expect(replaced == accepted)
        #expect(state.glosses == [accepted])
    }

    @MainActor
    @Test("Background job navigation prefers stable origin IDs and does not autoplay")
    func backgroundJobNavigationPrefersStableIDs() {
        let state = AppState()
        let stableChapter = Chapter(
            id: "stable-chapter",
            index: 0,
            title: "Current Chapter Title",
            audioPath: "/tmp/stable-chapter.m4b"
        )
        state.books = [
            Book(
                id: "stable-book",
                title: "Current Book Title",
                author: nil,
                folderPath: "/tmp/stable-book",
                coverPath: nil,
                ebookPath: nil,
                chapters: [stableChapter]
            ),
            Book(
                id: "misleading-book",
                title: "Legacy Book Title",
                author: nil,
                folderPath: "/tmp/misleading-book",
                coverPath: nil,
                ebookPath: nil,
                chapters: [Chapter(
                    id: "misleading-chapter",
                    index: 0,
                    title: "Legacy Chapter Title",
                    audioPath: "/tmp/misleading-chapter.m4b"
                )]
            )
        ]
        let job = BackgroundJob(
            kind: .chapterSummary,
            bookID: "stable-book",
            bookTitle: "Legacy Book Title",
            chapterID: "stable-chapter",
            chapterTitle: "Legacy Chapter Title",
            stage: "Summarizing chapter",
            detail: "Running",
            fraction: nil
        )
        state.player.load(path: stableChapter.audioPath)
        state.player.play()

        #expect(state.openBackgroundJob(job))
        #expect(state.selectedBookID == "stable-book")
        #expect(state.selectedChapterID == "stable-chapter")
        #expect(state.player.loadedPath == stableChapter.audioPath)
        #expect(!state.player.isPlaying)
        #expect(state.backgroundJobNavigationError == nil)
    }

    @MainActor
    @Test("Legacy background job origins use exact case-insensitive title fallback")
    func legacyBackgroundJobNavigationUsesSafeTitleFallback() {
        let state = AppState()
        let chapter = Chapter(
            id: "legacy-chapter",
            index: 0,
            title: "Legacy Chapter",
            audioPath: "/tmp/legacy-chapter.m4b"
        )
        state.books = [Book(
            id: "legacy-book",
            title: "Legacy Book",
            author: nil,
            folderPath: "/tmp/legacy-book",
            coverPath: nil,
            ebookPath: nil,
            chapters: [chapter]
        )]
        let legacyJob = BackgroundJob(
            kind: .sentenceTranslation,
            bookTitle: "legacy book",
            chapterTitle: "legacy chapter",
            stage: "Translating sentence",
            detail: "Queued",
            fraction: nil
        )

        #expect(state.openBackgroundJob(legacyJob))
        #expect(state.selectedBookID == "legacy-book")
        #expect(state.selectedChapterID == "legacy-chapter")
    }

    @MainActor
    @Test("Background job navigation reports removed books and chapters")
    func backgroundJobNavigationReportsMissingOrigins() {
        let state = AppState()
        state.books = [Book(
            id: "book-id",
            title: "Existing Book",
            author: nil,
            folderPath: "/tmp/existing-book",
            coverPath: nil,
            ebookPath: nil,
            chapters: [Chapter(
                id: "chapter-id",
                index: 0,
                title: "Existing Chapter",
                audioPath: "/tmp/existing-chapter.m4b"
            )]
        )]
        let removedBookJob = BackgroundJob(
            kind: .wordTranslation,
            bookID: "removed-book",
            bookTitle: "Removed Book",
            chapterID: "removed-chapter",
            chapterTitle: "Removed Chapter",
            stage: "Translating word",
            detail: "Queued",
            fraction: nil
        )

        #expect(!state.openBackgroundJob(removedBookJob))
        #expect(state.backgroundJobNavigationError == "Could not find “Removed Book” in the library. It may have been moved or deleted.")

        let removedChapterJob = BackgroundJob(
            kind: .chapterTranslation,
            bookID: "book-id",
            bookTitle: "Existing Book",
            chapterID: "removed-chapter",
            chapterTitle: "Removed Chapter",
            stage: "Translating chapter",
            detail: "Running",
            fraction: nil
        )

        #expect(!state.openBackgroundJob(removedChapterJob))
        #expect(state.backgroundJobNavigationError == "Could not find “Removed Chapter” in “Existing Book”. It may have been moved or deleted.")
        #expect(state.selectedBookID == nil)
        #expect(state.selectedChapterID == nil)
    }
}
