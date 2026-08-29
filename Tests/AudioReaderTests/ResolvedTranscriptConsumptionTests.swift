import Foundation
import Testing
import AudioReaderDomain
@testable import AudioReader

@MainActor
@Suite("Resolved transcript consumption")
struct ResolvedTranscriptConsumptionTests {
    @Test("AppState presents one resolved transcript while retaining the immutable base")
    func appStateKeepsBaseAndPresentationSeparate() {
        let state = AppState(composition: .inMemory())
        let base = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/book.m4b",
            createdAt: Date(timeIntervalSince1970: 1),
            locale: "en-AU",
            segments: [segment()],
            source: "asr",
            ebookAligned: false
        )
        state.transcript = base
        let overlay = StoredTranscriptOverlay(
            id: StoredTranscriptOverlay.stableID(
                chapterID: ChapterID(rawValue: "chapter"),
                segmentID: "sentence"
            ),
            chapterID: ChapterID(rawValue: "chapter"),
            segmentID: "sentence",
            baseFingerprint: TranscriptOverlayResolver.baseFingerprint(for: StoredTranscriptSegment(base.segments[0])),
            correctedText: "Corrected sentence.",
            correctedStart: 0.5,
            correctedEnd: 2.5,
            provenance: .init(deviceID: "test-device", createdAt: Date(timeIntervalSince1970: 2)),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        state.reloadResolvedTranscriptForCurrentChapter(overlays: [overlay], chapterDuration: 3)

        #expect(state.transcript?.segments[0].displayText == "Original sentence.")
        #expect(state.transcript?.segments[0].start == 0)
        #expect(state.presentedTranscript?.segments[0].displayText == "Corrected sentence.")
        #expect(state.presentedTranscript?.segments[0].start == 0.5)
        #expect(state.presentedTranscript?.segments[0].words.map(\.id) == ["word"])
        #expect(state.transcriptOverlayStatuses[overlay.id] == .applied)
    }

    @Test("reader source uses the shared presented transcript seam")
    func playerUsesPresentedTranscript() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let player = try String(
            contentsOf: repository.appendingPathComponent("Sources/AudioReader/PlayerView.swift"),
            encoding: .utf8
        )

        #expect(player.contains("state.presentedTranscript"))
        #expect(!player.contains("state.transcript?.segments"))
        #expect(player.contains("transcript.conflictChoice."))
    }

    @Test("corrected text supplies lookup and vocabulary tokens inside corrected bounds")
    func correctedTextSuppliesPresentationTokens() {
        var corrected = segment()
        corrected.start = 0.5
        corrected.end = 2.5
        corrected.resolvedOverlayText = "Corrected sentence here"

        let tokens = StudyTokenIndex.tokens(in: corrected)

        #expect(tokens.map(\.text) == ["Corrected", "sentence", "here"])
        #expect(tokens.first?.start == 0.5)
        #expect(tokens.last?.end == 2.5)
        #expect(tokens.allSatisfy { $0.id.contains("-overlay-") })
    }

    private func segment() -> TranscriptSegment {
        TranscriptSegment(
            id: "sentence",
            start: 0,
            end: 3,
            words: [.init(id: "word", text: "Original sentence.", start: 0, end: 3, confidence: 1)],
            ebookText: nil,
            alignmentScore: nil
        )
    }
}
