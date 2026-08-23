import Foundation

struct SelectedChapterJobPresentation: Equatable, Sendable {
    var isTranslating: Bool
    var isChapterAssistantWorking: Bool
    var chapterTranslationState: BackgroundJob.State?
}

struct BackgroundJobQueue: Sendable {
    let maxConcurrentPerKind: Int
    private(set) var jobs: [BackgroundJob] = []

    init(maxConcurrentPerKind: Int = 2) {
        precondition(maxConcurrentPerKind > 0)
        self.maxConcurrentPerKind = maxConcurrentPerKind
    }

    @discardableResult
    mutating func enqueue(
        id: UUID = UUID(),
        kind: BackgroundJob.Kind,
        origin: BackgroundJobOrigin,
        targetID: String? = nil,
        stage: String? = nil,
        detail: String? = nil,
        fraction: Double? = nil
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
            stage: stage ?? kind.title,
            detail: state == .queued ? "Waiting for a \(kind.queueName) slot…" : detail ?? "Starting…",
            fraction: state == .queued ? nil : fraction
        )
        jobs.append(job)
        return job
    }

    mutating func update(id: UUID, stage: String, detail: String, fraction: Double?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        jobs[index].stage = stage
        jobs[index].detail = detail
        jobs[index].fraction = fraction
    }

    @discardableResult
    mutating func finish(id: UUID) -> UUID? {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        let finished = jobs.remove(at: index)
        guard finished.state == .running,
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
        let selectedJobs = jobs.filter { $0.chapterID == chapterID }
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
