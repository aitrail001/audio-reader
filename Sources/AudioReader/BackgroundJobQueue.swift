import Foundation

struct SelectedChapterJobPresentation: Equatable, Sendable {
    var isTranslating: Bool
    var isChapterAssistantWorking: Bool
    var chapterTranslationState: BackgroundJob.State?
}

struct BackgroundJobQueue: Sendable {
    let maxConcurrentPerKind: Int
    let maxRetainedTerminalJobs: Int
    private(set) var jobs: [BackgroundJob] = []
    private(set) var retainedTerminalJobs: [BackgroundJob] = []

    init(maxConcurrentPerKind: Int = 2, maxRetainedTerminalJobs: Int = 8) {
        precondition(maxConcurrentPerKind > 0)
        precondition(maxRetainedTerminalJobs >= 0)
        self.maxConcurrentPerKind = maxConcurrentPerKind
        self.maxRetainedTerminalJobs = maxRetainedTerminalJobs
    }

    var visibleJobs: [BackgroundJob] { jobs + retainedTerminalJobs }

    @discardableResult
    mutating func enqueue(
        id: UUID = UUID(),
        kind: BackgroundJob.Kind,
        origin: BackgroundJobOrigin,
        targetID: String? = nil,
        language: String? = nil,
        stage: String? = nil,
        detail: String? = nil,
        fraction: Double? = nil,
        chapterSummaryPhase: ChapterSummaryProgress.Phase? = nil
    ) -> BackgroundJob {
        precondition(kind != .transcription)
        precondition(!jobs.contains(where: { $0.id == id }))
        let state: BackgroundJob.State = runningJobs(of: kind).count < maxConcurrentPerKind ? .running : .queued
        let job = BackgroundJob(
            id: id,
            kind: kind,
            state: state,
            bookID: origin.bookID,
            bookTitle: origin.bookTitle,
            chapterID: origin.chapterID,
            chapterTitle: origin.chapterTitle,
            targetID: targetID,
            language: language,
            stage: stage ?? kind.title,
            detail: state == .queued ? "Waiting for a \(kind.queueName) slot…" : detail ?? "Starting…",
            fraction: state == .queued ? nil : fraction,
            chapterSummaryPhase: chapterSummaryPhase
        )
        jobs.append(job)
        return job
    }

    /// Queued metadata is mutable so the queue remains the single presentation
    /// source before and after a concurrency slot is promoted.
    mutating func update(
        id: UUID,
        stage: String,
        detail: String,
        fraction: Double?,
        chapterSummaryPhase: ChapterSummaryProgress.Phase? = nil
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].state.isTerminal else { return }
        jobs[index].stage = stage
        jobs[index].detail = detail
        jobs[index].fraction = jobs[index].state == .queued ? nil : fraction
        if let chapterSummaryPhase {
            jobs[index].chapterSummaryPhase = chapterSummaryPhase
        }
    }

    /// Terminal state is recorded on the active request first, preserving its UUID
    /// until `finish` moves the same record into bounded presentation history.
    mutating func markTerminal(
        id: UUID,
        state: BackgroundJob.State,
        stage: String,
        detail: String,
        chapterSummaryPhase: ChapterSummaryProgress.Phase? = nil
    ) {
        precondition(state.isTerminal)
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        jobs[index].stage = stage
        jobs[index].detail = detail
        jobs[index].fraction = nil
        if let chapterSummaryPhase {
            jobs[index].chapterSummaryPhase = chapterSummaryPhase
        }
    }

    mutating func recordTerminal(_ job: BackgroundJob) {
        precondition(job.state.isTerminal)
        guard maxRetainedTerminalJobs > 0 else { return }
        retainedTerminalJobs.removeAll { $0.id == job.id }
        retainedTerminalJobs.append(job)
        if retainedTerminalJobs.count > maxRetainedTerminalJobs {
            retainedTerminalJobs.removeFirst(retainedTerminalJobs.count - maxRetainedTerminalJobs)
        }
    }

    @discardableResult
    mutating func finish(id: UUID) -> UUID? {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        let finished = jobs.remove(at: index)
        if finished.state.isTerminal {
            recordTerminal(finished)
        }
        guard finished.state != .queued,
              let queuedIndex = jobs.firstIndex(where: { $0.kind == finished.kind && $0.state == .queued })
        else { return nil }
        jobs[queuedIndex].state = .running
        jobs[queuedIndex].detail = "Starting…"
        return jobs[queuedIndex].id
    }

    func runningJobs(of kind: BackgroundJob.Kind) -> [BackgroundJob] {
        jobs.filter { $0.kind == kind && $0.state == .running }
    }

    func presentation(forChapterID chapterID: String?) -> SelectedChapterJobPresentation {
        guard let chapterID else {
            return SelectedChapterJobPresentation(
                isTranslating: false,
                isChapterAssistantWorking: false,
                chapterTranslationState: nil
            )
        }
        let selectedJobs = jobs.filter { $0.chapterID == chapterID && !$0.state.isTerminal }
        return SelectedChapterJobPresentation(
            isTranslating: selectedJobs.contains {
                $0.kind == .sentenceTranslation || $0.kind == .wordTranslation
            },
            isChapterAssistantWorking: selectedJobs.contains {
                $0.kind == .chapterTranslation || $0.kind == .chapterSummary || $0.kind == .chapterChat
            },
            chapterTranslationState: selectedJobs.first { $0.kind == .chapterTranslation }?.state
        )
    }

    func latestChapterSummary(chapterID: String, language: String) -> BackgroundJob? {
        jobs.last {
            $0.kind == .chapterSummary && $0.chapterID == chapterID && $0.language == language
        } ?? retainedTerminalJobs.last {
            $0.kind == .chapterSummary && $0.chapterID == chapterID && $0.language == language
        }
    }
}

extension BackgroundJob.Kind {
    var title: String {
        switch self {
        case .transcription: "Transcribing chapter"
        case .chapterTranslation: "Translating chapter"
        case .sentenceTranslation: "Translating sentence"
        case .wordTranslation: "Translating word"
        case .chapterChat: "Answering chapter question"
        case .chapterSummary: "Summarising chapter"
        }
    }

    fileprivate var queueName: String {
        switch self {
        case .transcription: "transcription"
        case .chapterTranslation: "chapter translation"
        case .sentenceTranslation: "sentence translation"
        case .wordTranslation: "word translation"
        case .chapterChat: "chapter chat"
        case .chapterSummary: "chapter summary"
        }
    }
}
