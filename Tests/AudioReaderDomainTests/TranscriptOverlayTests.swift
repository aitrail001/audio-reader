import Foundation
import Testing
@testable import AudioReaderDomain

@Suite("Transcript overlay resolution")
struct TranscriptOverlayTests {
    @Test("valid corrections replace text and bounds without mutating the base")
    func resolvesValidOverlay() throws {
        let base = sampleTranscript()
        let fingerprint = TranscriptOverlayResolver.baseFingerprint(for: base.segments[1])
        let overlay = StoredTranscriptOverlay(
            id: "chapter:segment-2",
            chapterID: base.chapterID,
            segmentID: "segment-2",
            baseFingerprint: fingerprint,
            correctedText: "Corrected middle sentence.",
            correctedStart: 1.1,
            correctedEnd: 2.9,
            provenance: .init(deviceID: "mac", actorID: "user", createdAt: Date(timeIntervalSince1970: 10)),
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        let result = TranscriptOverlayResolver.resolve(
            base: base,
            overlays: [overlay],
            chapterDuration: 4
        )

        #expect(result.segments[1].displayText == "Corrected middle sentence.")
        #expect(result.segments[1].start == 1.1)
        #expect(result.segments[1].end == 2.9)
        #expect(result.statuses[overlay.id] == .applied)
        #expect(base.segments[1].start == 1)
        #expect(base.segments[1].end == 3)
    }

    @Test("stale fingerprints are retained but not applied")
    func rejectsStaleBase() {
        let base = sampleTranscript()
        let overlay = StoredTranscriptOverlay(
            id: "chapter:segment-2",
            chapterID: base.chapterID,
            segmentID: "segment-2",
            baseFingerprint: "old-base",
            correctedText: "Wrong base",
            correctedStart: 1,
            correctedEnd: 3,
            provenance: .init(deviceID: "ipad", createdAt: .now),
            updatedAt: .now
        )

        let result = TranscriptOverlayResolver.resolve(base: base, overlays: [overlay], chapterDuration: 4)

        #expect(result.segments[1].displayText == base.segments[1].displayText)
        #expect(result.statuses[overlay.id] == .staleBase)
        #expect(result.retainedOverlays == [overlay])
    }

    @Test(arguments: [
        ("", 1.0, 3.0, TranscriptOverlayValidationError.emptyText),
        ("Text", -0.1, 3.0, .negativeTiming),
        ("Text", 1.0, 1.2, .durationTooShort),
        ("Text", 1.0, 4.1, .outsideChapterBounds),
        ("Text", 0.9, 3.0, .overlapsNeighbor),
        ("Text", 1.0, 3.1, .overlapsNeighbor),
    ])
    func rejectsInvalidContent(
        text: String,
        start: Double,
        end: Double,
        expected: TranscriptOverlayValidationError
    ) {
        let base = sampleTranscript()
        let overlay = StoredTranscriptOverlay(
            id: "chapter:segment-2",
            chapterID: base.chapterID,
            segmentID: "segment-2",
            baseFingerprint: TranscriptOverlayResolver.baseFingerprint(for: base.segments[1]),
            correctedText: text,
            correctedStart: start,
            correctedEnd: end,
            provenance: .init(deviceID: "mac", createdAt: .now),
            updatedAt: .now
        )

        let result = TranscriptOverlayResolver.resolve(base: base, overlays: [overlay], chapterDuration: 4)
        #expect(result.statuses[overlay.id] == .invalid(expected))
        #expect(result.segments[1].displayText == base.segments[1].displayText)
    }

    @Test("overlay identity is deterministic per base segment")
    func stableIdentity() {
        #expect(StoredTranscriptOverlay.stableID(chapterID: ChapterID(rawValue: "c/1"), segmentID: "s:2") == "c%2F1:s%3A2")
    }

    @Test("competing edits sharing an entity ID receive distinct candidate IDs")
    func distinctConflictCandidateIdentity() {
        let base = sampleTranscript()
        let first = StoredTranscriptOverlay(
            id: "chapter:segment-2",
            chapterID: base.chapterID,
            segmentID: "segment-2",
            baseFingerprint: "base",
            correctedText: "First",
            correctedStart: 1,
            correctedEnd: 3,
            provenance: .init(deviceID: "mac", createdAt: Date(timeIntervalSince1970: 1)),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        var second = first
        second.correctedText = "Second"
        second.provenance.deviceID = "ipad"

        let firstCandidate = StoredTranscriptOverlayCandidate(overlay: first, revision: 4)
        let repeated = StoredTranscriptOverlayCandidate(overlay: first, revision: 4)
        let secondCandidate = StoredTranscriptOverlayCandidate(overlay: second, revision: 4)

        #expect(firstCandidate.id == repeated.id)
        #expect(firstCandidate.id != secondCandidate.id)
    }

    private func sampleTranscript() -> StoredTranscript {
        StoredTranscript(
            chapterID: ChapterID(rawValue: "chapter"),
            localMediaKey: "/tmp/book.m4b",
            createdAt: Date(timeIntervalSince1970: 1),
            locale: "en-US",
            source: "asr",
            ebookAligned: false,
            segments: [
                segment("segment-1", 0, 1, "First."),
                segment("segment-2", 1, 3, "Middle."),
                segment("segment-3", 3, 4, "Last."),
            ]
        )
    }

    private func segment(_ id: String, _ start: Double, _ end: Double, _ text: String) -> StoredTranscriptSegment {
        StoredTranscriptSegment(
            id: id,
            start: start,
            end: end,
            words: [.init(id: "\(id)-word", text: text, start: start, end: end)]
        )
    }
}
