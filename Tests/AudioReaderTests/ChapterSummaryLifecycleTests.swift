import Foundation
import Testing
@testable import AudioReader
@testable import AudioReaderNetworking

@MainActor
struct ChapterSummaryLifecycleTests {
    @Test("Cache success follows the actual enqueue path and completes only after durable save")
    func cacheSuccessCompletesAfterSave() async throws {
        let executor = GatedSummaryExecutor()
        let saver = RecordingSummarySaver()
        let state = makeState(executor: executor, saver: saver)
        saver.state = state

        state.summarizeChapter()
        #expect(await eventually { executor.callCount == 1 })
        let activeID = try #require(state.selectedChapterSummaryJob?.id)
        #expect(state.selectedChapterSummaryJob?.chapterSummaryPhase == .cacheOrRequest)
        #expect(state.selectedChapterSummaryJob?.fraction == nil)

        executor.succeed(call: 1, with: cachedResult())
        #expect(await eventually { state.selectedChapterSummaryJob?.state == .completed })

        let completed = try #require(state.selectedChapterSummaryJob)
        #expect(completed.id == activeID)
        #expect(completed.detail == "Cached summary saved and ready for review.")
        #expect(saver.observedPhases == [.processing])
        #expect(saver.saved.count == 1)
        #expect(state.chapterSummary != nil)
        #expect(!state.isLLMJobActive(kind: .chapterSummary))
        #expect(!state.isChapterAssistantWorking)
    }

    @Test("Parse and durable-save failures retain a correlated failed job without publishing a draft")
    func parseAndSaveFailuresDoNotComplete() async {
        let parseExecutor = ImmediateSummaryExecutor(outcomes: [.success(.init(text: "not-json", identity: nil))])
        let parseSaver = RecordingSummarySaver()
        let parseState = makeState(executor: parseExecutor, saver: parseSaver)
        parseState.summarizeChapter()
        #expect(await eventually { parseState.selectedChapterSummaryJob?.state == .failed })
        #expect(parseState.chapterSummary == nil)
        #expect(parseSaver.saved.isEmpty)
        #expect(!parseState.isChapterAssistantWorking)

        let saveExecutor = ImmediateSummaryExecutor(outcomes: [.success(generatedResult())])
        let saveSaver = RecordingSummarySaver(error: SummaryTestError.saveFailed)
        let saveState = makeState(executor: saveExecutor, saver: saveSaver)
        saveSaver.state = saveState
        saveState.summarizeChapter()
        #expect(await eventually { saveState.selectedChapterSummaryJob?.state == .failed })
        #expect(saveSaver.observedPhases == [.processing])
        #expect(saveState.chapterSummary == nil)
        #expect(!saveState.isLLMJobActive(kind: .chapterSummary))
        #expect(!saveState.isChapterAssistantWorking)
    }

    @Test("Cancellation and configuration failure are terminal, correlated, and never leave busy state")
    func cancellationAndConfigurationFailureClearBusyState() async throws {
        let executor = ImmediateSummaryExecutor(outcomes: [.failure(CancellationError())])
        let state = makeState(executor: executor, saver: RecordingSummarySaver())
        state.summarizeChapter()
        #expect(await eventually { state.selectedChapterSummaryJob?.state == .cancelled })
        let cancelled = try #require(state.selectedChapterSummaryJob)
        #expect(cancelled.chapterSummaryPhase == .cancelled)
        #expect(!state.isChapterAssistantWorking)

        let configurationState = makeState(executor: nil, saver: RecordingSummarySaver())
        configurationState.settings.llmProvider = LLMProvider.managedQwen.rawValue
        configurationState.summarizeChapter()
        let failed = try #require(configurationState.selectedChapterSummaryJob)
        #expect(failed.state == .failed)
        #expect(failed.id != cancelled.id)
        #expect(configurationState.llmJobQueue.jobs.isEmpty)
        #expect(!configurationState.isChapterAssistantWorking)
    }

    @Test("A summary executor never bypasses configuration validation for chapter chat")
    func summaryExecutorDoesNotBypassChapterChatConfiguration() {
        let executor = GatedSummaryExecutor()
        let state = makeState(executor: executor, saver: RecordingSummarySaver())

        state.sendChapterChat("What happened?")

        #expect(executor.callCount == 0)
        #expect(state.llmJobQueue.jobs.isEmpty)
        #expect(state.chapterAssistantError != nil)
        #expect(state.tab == .settings)
    }

    @Test("Queued promotion and retry preserve one job record per request without stale busy state")
    func queuedPromotionAndRetry() async throws {
        let executor = GatedSummaryExecutor()
        let saver = RecordingSummarySaver()
        let state = makeState(executor: executor, saver: saver, chapters: 2)
        state.llmJobQueue = BackgroundJobQueue(maxConcurrentPerKind: 1, maxRetainedTerminalJobs: 4)

        selectChapter(1, in: state)
        state.summarizeChapter()
        #expect(await eventually { executor.callCount == 1 })
        let firstID = try #require(state.selectedChapterSummaryJob?.id)

        selectChapter(2, in: state)
        state.summarizeChapter()
        let queued = try #require(state.selectedChapterSummaryJob)
        #expect(queued.state == .queued)
        #expect(queued.chapterSummaryPhase == .queued)
        #expect(queued.stage == "Chapter summary queued")
        #expect(queued.detail == "Waiting for a chapter summary slot…")

        executor.succeed(call: 1, with: generatedResult())
        #expect(await eventually { executor.callCount == 2 })
        let promoted = try #require(state.selectedChapterSummaryJob)
        #expect(promoted.id == queued.id)
        #expect(promoted.state == .running)
        #expect(promoted.chapterSummaryPhase == .cacheOrRequest)
        executor.fail(call: 2, with: SummaryTestError.providerFailed)
        #expect(await eventually { state.selectedChapterSummaryJob?.state == .failed })
        #expect(!state.isChapterAssistantWorking)

        state.summarizeChapter()
        #expect(await eventually { executor.callCount == 3 })
        let retry = try #require(state.selectedChapterSummaryJob)
        #expect(retry.id != queued.id)
        #expect(retry.state == .running)
        executor.succeed(call: 3, with: generatedResult())
        #expect(await eventually { state.selectedChapterSummaryJob?.state == .completed })
        #expect(state.selectedChapterSummaryJob?.id == retry.id)
        #expect(firstID != retry.id)
        #expect(!state.isChapterAssistantWorking)
    }

    @Test("Terminal summary history is bounded and queued metadata has one source of truth")
    func queueBoundsTerminalHistoryAndUpdatesQueuedMetadata() {
        var queue = BackgroundJobQueue(maxConcurrentPerKind: 1, maxRetainedTerminalJobs: 2)
        let origin = BackgroundJobOrigin(bookTitle: "Book", chapterID: "chapter", chapterTitle: "Chapter")
        let running = queue.enqueue(kind: .chapterSummary, origin: origin)
        let queued = queue.enqueue(kind: .chapterSummary, origin: origin)
        queue.update(
            id: queued.id,
            stage: "Chapter summary queued",
            detail: "Waiting for a chapter summary slot…",
            fraction: nil,
            chapterSummaryPhase: .queued
        )
        #expect(queue.jobs.last?.stage == "Chapter summary queued")
        #expect(queue.visibleJobs.last?.detail == "Waiting for a chapter summary slot…")

        queue.markTerminal(
            id: running.id,
            state: .failed,
            stage: "Chapter summary failed",
            detail: "Failed",
            chapterSummaryPhase: .failed
        )
        _ = queue.finish(id: running.id)
        for index in 0..<3 {
            queue.recordTerminal(BackgroundJob(
                id: UUID(),
                kind: .chapterSummary,
                state: .failed,
                bookTitle: "Book",
                chapterTitle: "Chapter \(index)",
                stage: "Chapter summary failed",
                detail: "Failed",
                fraction: nil,
                chapterSummaryPhase: .failed
            ))
        }
        #expect(queue.retainedTerminalJobs.count == 2)
        #expect(queue.visibleJobs.filter(\.state.isTerminal).count == 2)
    }

    private func makeState(
        executor: (any ChapterSummaryExecuting)?,
        saver: any ChapterSummarySaving,
        chapters: Int = 1
    ) -> AppState {
        let state = AppState(
            chapterSummaryExecutor: executor,
            chapterSummarySaver: saver
        )
        state.settings.llmProvider = LLMProvider.managedQwen.rawValue
        state.books = [Book(
            id: "book",
            title: "Book",
            author: "Author",
            folderPath: "/tmp/book",
            coverPath: nil,
            ebookPath: nil,
            chapters: (1...chapters).map {
                Chapter(id: "chapter-\($0)", index: $0 - 1, title: "Chapter \($0)", audioPath: "/tmp/\($0).m4b")
            }
        )]
        selectChapter(1, in: state)
        return state
    }

    private func selectChapter(_ index: Int, in state: AppState) {
        state.selectedBookID = "book"
        state.selectedChapterID = "chapter-\(index)"
        state.transcript = Transcript(
            chapterID: "chapter-\(index)",
            audioPath: "/tmp/\(index).m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: [TranscriptSegment(
                id: "segment-\(index)",
                start: 0,
                end: 1,
                words: [TranscriptWord(id: "word-\(index)", text: "Source text.", start: 0, end: 1, confidence: 1)]
            )],
            source: "test",
            ebookAligned: false
        )
    }

    private func cachedResult() -> ChapterSummaryExecutionResult {
        .init(text: validSummaryJSON, identity: identity(provenance: "cache_shared_exact"))
    }

    private func generatedResult() -> ChapterSummaryExecutionResult {
        .init(text: validSummaryJSON, identity: identity(provenance: "generated"))
    }

    private var validSummaryJSON: String {
        #"{"overview":"Overview","keyPoints":[],"charactersOrIdeas":[],"keyConcepts":[],"themes":[]}"#
    }

    private func identity(provenance: String) -> ProductChapterSummary {
        let json = #"{"id":"00000000-0000-4000-8000-000000000001","sharedCacheEntryID":"00000000-0000-4000-8000-000000000002","overview":"Overview","keyPoints":[],"charactersOrIdeas":[],"keyConcepts":[],"themes":[],"provenance":"\#(provenance)","model":"test-model","promptVersion":"test-prompt","modelPolicyHash":"test-hash","policyVersion":"test-policy","createdAt":"2026-09-01T00:00:00Z"}"#
        return try! JSONDecoder().decode(ProductChapterSummary.self, from: Data(json.utf8))
    }

    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return false
    }
}

private enum SummaryTestError: LocalizedError {
    case providerFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .providerFailed: "Provider failed"
        case .saveFailed: "Save failed"
        }
    }
}

@MainActor
private final class ImmediateSummaryExecutor: ChapterSummaryExecuting {
    enum Outcome {
        case success(ChapterSummaryExecutionResult)
        case failure(any Error)
    }

    private var outcomes: [Outcome]

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func execute(_ request: ChapterSummaryExecutionRequest) async throws -> ChapterSummaryExecutionResult {
        switch outcomes.removeFirst() {
        case .success(let result): result
        case .failure(let error): throw error
        }
    }
}

@MainActor
private final class GatedSummaryExecutor: ChapterSummaryExecuting {
    private(set) var callCount = 0
    private var continuations: [Int: CheckedContinuation<ChapterSummaryExecutionResult, any Error>] = [:]

    func execute(_ request: ChapterSummaryExecutionRequest) async throws -> ChapterSummaryExecutionResult {
        callCount += 1
        let call = callCount
        return try await withCheckedThrowingContinuation { continuations[call] = $0 }
    }

    func succeed(call: Int, with result: ChapterSummaryExecutionResult) {
        continuations.removeValue(forKey: call)?.resume(returning: result)
    }

    func fail(call: Int, with error: any Error) {
        continuations.removeValue(forKey: call)?.resume(throwing: error)
    }
}

@MainActor
private final class RecordingSummarySaver: ChapterSummarySaving {
    weak var state: AppState?
    private let error: (any Error)?
    private(set) var saved: [ChapterSummaryRecord] = []
    private(set) var observedPhases: [ChapterSummaryProgress.Phase] = []

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func save(_ summary: ChapterSummaryRecord) throws {
        if let phase = state?.selectedChapterSummaryJob?.chapterSummaryPhase {
            observedPhases.append(phase)
        }
        if let error { throw error }
        saved.append(summary)
    }
}
