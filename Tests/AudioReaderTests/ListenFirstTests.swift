import Foundation
import Testing
@testable import AudioReader

@MainActor
@Suite("Listen First")
struct ListenFirstTests {
    @Test("Listen First conceals the unfinished sentence and every future sentence")
    func visibilityFollowsTheListeningBoundary() {
        let ids = ["first", "second", "third"]

        #expect(ListenFirstVisibility.resolve(
            segmentID: "first",
            orderedSegmentIDs: ids,
            currentSegmentID: "second",
            pausedSegmentID: nil,
            replayRevealedSegmentID: nil
        ) == .revealed)
        #expect(ListenFirstVisibility.resolve(
            segmentID: "second",
            orderedSegmentIDs: ids,
            currentSegmentID: "second",
            pausedSegmentID: nil,
            replayRevealedSegmentID: nil
        ) == .currentHidden)
        #expect(ListenFirstVisibility.resolve(
            segmentID: "third",
            orderedSegmentIDs: ids,
            currentSegmentID: "second",
            pausedSegmentID: nil,
            replayRevealedSegmentID: nil
        ) == .futureHidden)
    }

    @Test("The sentence is revealed after the Listen First pause or an explicit replay")
    func pauseAndReplayRevealTheSentence() {
        let ids = ["first", "second"]
        #expect(ListenFirstVisibility.resolve(
            segmentID: "second",
            orderedSegmentIDs: ids,
            currentSegmentID: "second",
            pausedSegmentID: "second",
            replayRevealedSegmentID: nil
        ) == .revealed)
        #expect(ListenFirstVisibility.resolve(
            segmentID: "second",
            orderedSegmentIDs: ids,
            currentSegmentID: "second",
            pausedSegmentID: nil,
            replayRevealedSegmentID: "second"
        ) == .revealed)
    }

    @Test("Heard passage is bounded and never includes unfinished or future text")
    func heardPassageIsBounded() throws {
        let transcript = makeTranscript(count: 8)
        let passage = try #require(HeardPassage.recent(
            in: transcript,
            throughSegmentID: "segment-5",
            limit: 3
        ))

        #expect(passage.segments.map(\.id) == ["segment-3", "segment-4", "segment-5"])
        #expect(!passage.promptInput.contains("Sentence 6"))
        #expect(!passage.promptInput.contains("segment-6"))
    }

    @Test("Quick Quiz prompt requires grounded structured output without revealing answers early")
    func quizPromptIsGroundedAndStructured() throws {
        let passage = try #require(HeardPassage.recent(
            in: makeTranscript(count: 4),
            throughSegmentID: "segment-2",
            limit: 3
        ))
        let task = ReadingAssistantPrompt.heardQuiz(
            passage: passage,
            language: .zhHans,
            sourceLanguage: .englishUS,
            readerLevel: .intermediate
        )

        #expect(task.system.contains("already-heard passage"))
        #expect(task.system.contains("valid JSON only"))
        #expect(task.system.contains("answerIndex"))
        #expect(task.user.contains("segment-2"))
        #expect(!task.user.contains("segment-3"))
        #expect(task.user.contains("Do not reveal the answer outside the JSON"))
    }

    @Test("Invalid AI quiz output falls back to a local quiz over the same heard passage")
    func invalidModelOutputFallsBackLocally() throws {
        let passage = try #require(HeardPassage.recent(
            in: makeTranscript(count: 8),
            throughSegmentID: "segment-6",
            limit: 6
        ))
        let quiz = HeardQuizResolver.resolve(
            response: "not json",
            passage: passage,
            language: "en"
        )

        #expect(!quiz.questions.isEmpty)
        #expect(quiz.questions.allSatisfy { question in
            question.segmentID.map(Set(passage.segments.map(\.id)).contains) ?? true
        })
    }

    @Test("AI quiz output must cite a heard sentence and provide four distinct choices")
    func modelOutputRequiresGroundingAndValidChoices() throws {
        let passage = try #require(HeardPassage.recent(
            in: makeTranscript(count: 8),
            throughSegmentID: "segment-6",
            limit: 6
        ))
        let response = """
        {"questions":[
          {"id":"missing-source","kind":"comprehension","prompt":"What happened?","choices":["A","B","C","D"],"answerIndex":0,"rationale":"A","segmentID":null},
          {"id":"duplicate-choice","kind":"comprehension","prompt":"Which detail?","choices":["A","A","C","D"],"answerIndex":2,"rationale":"C","segmentID":"segment-6"}
        ]}
        """

        let quiz = HeardQuizResolver.resolve(
            response: response,
            passage: passage,
            language: "en"
        )

        #expect(!quiz.questions.contains { $0.id == "missing-source" || $0.id == "duplicate-choice" })
        #expect(quiz.questions.allSatisfy { $0.segmentID != nil })
        #expect(quiz.questions.allSatisfy { Set($0.choices).count == 4 })
    }

    @Test("Listen First conceals transcript before playback establishes a sentence")
    func transcriptStartsConcealed() {
        #expect(ListenFirstVisibility.resolve(
            segmentID: "first",
            orderedSegmentIDs: ["first", "second"],
            currentSegmentID: nil,
            pausedSegmentID: nil,
            replayRevealedSegmentID: nil
        ) == .futureHidden)
    }

    @Test("Listen First remains shared across macOS and iPadOS reader UI")
    func sharedReaderContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let player = try String(
            contentsOf: root.appendingPathComponent("Sources/AudioReader/PlayerView.swift"),
            encoding: .utf8
        )
        let coach = try String(
            contentsOf: root.appendingPathComponent("Sources/AudioReader/ListenFirstCoachView.swift"),
            encoding: .utf8
        )

        #expect(player.contains("Toggle(\"Listen First\""))
        #expect(player.contains("ListenFirstVisibility.resolve"))
        #expect(player.contains("ListenFirstCoachView"))
        #expect(coach.contains("Quick Quiz"))
        #expect(coach.contains("minHeight: 44"))
        #expect(!coach.contains("#if os("))
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/AudioReader/AppState.swift"),
            encoding: .utf8
        )
        #expect(appState.contains("ManagedProductLLM.heardQuiz("))
    }

    private func makeTranscript(count: Int) -> Transcript {
        let segments: [TranscriptSegment] = (0..<count).map { index in
            let start = Double(index * 2)
            let words: [TranscriptWord] = [
                TranscriptWord(
                    id: "word-\(index)-a",
                    text: "Forest ",
                    start: start,
                    end: start + 0.8,
                    confidence: nil
                ),
                TranscriptWord(
                    id: "word-\(index)-b",
                    text: "canopy ",
                    start: start + 0.8,
                    end: start + 1.4,
                    confidence: nil
                ),
                TranscriptWord(
                    id: "word-\(index)-c",
                    text: "Sentence \(index)",
                    start: start + 1.4,
                    end: start + 2,
                    confidence: nil
                )
            ]
            return TranscriptSegment(
                id: "segment-\(index)",
                start: start,
                end: start + 2,
                words: words,
                ebookText: nil,
                alignmentScore: nil
            )
        }
        return Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/listen-first.m4b",
            createdAt: Date(),
            locale: "en-US",
            segments: segments,
            source: "test",
            ebookAligned: false
        )
    }
}
