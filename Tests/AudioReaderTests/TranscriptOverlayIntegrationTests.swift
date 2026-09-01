import Foundation
import Testing
@testable import AudioReader

@Suite("Transcript overlay app integration")
struct TranscriptOverlayIntegrationTests {
    @Test("resolved presentation applies overlay text and bounds without changing source bytes or word timing")
    func resolvedPresentationKeepsImmutableBase() throws {
        let base = Transcript(
            chapterID: "chapter",
            audioPath: "/tmp/book.m4b",
            createdAt: Date(timeIntervalSince1970: 1),
            locale: "en-US",
            segments: [
                TranscriptSegment(
                    id: "segment",
                    start: 1,
                    end: 2,
                    words: [TranscriptWord(id: "word", text: "Original.", start: 1.1, end: 1.9)]
                )
            ],
            source: "asr",
            ebookAligned: false
        )
        let sourceBytes = try JSONEncoder.iso.encode(base)
        let stored = StoredTranscript(base)
        let overlay = StoredTranscriptOverlay(
            id: "overlay",
            chapterID: stored.chapterID,
            segmentID: "segment",
            baseFingerprint: TranscriptOverlayResolver.baseFingerprint(for: stored.segments[0]),
            correctedText: "Corrected.",
            correctedStart: 1.05,
            correctedEnd: 2.1,
            provenance: .init(deviceID: "mac", createdAt: Date(timeIntervalSince1970: 2)),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let presented = Transcript(TranscriptOverlayResolver.resolve(
            base: stored,
            overlays: [overlay],
            chapterDuration: 3
        ))

        #expect(presented.segments[0].spokenText == "Corrected.")
        #expect(presented.segments[0].displayText == "Corrected.")
        #expect(presented.segments[0].start == 1.05)
        #expect(presented.segments[0].end == 2.1)
        #expect(presented.segments[0].words[0].id == "word")
        #expect(presented.segments[0].words[0].start == 1.1)
        #expect(presented.segments[0].words[0].end == 1.9)
        #expect(try JSONEncoder.iso.encode(base) == sourceBytes)

        let roundTripBase = try JSONDecoder.iso.decode(Transcript.self, from: sourceBytes)
        #expect(roundTripBase.segments[0].resolvedOverlayText == nil)
    }

    @Test("correcting sentence text hides accepted translations for the old source")
    func marksOldAcceptedTranslationStale() {
        let matching = gloss(id: "matching", source: "Original sentence.", status: .accepted, chapterID: "chapter")
        let pending = gloss(id: "pending", source: "Original sentence.", status: .pending, chapterID: "chapter")
        let other = gloss(id: "other", source: "Original sentence.", status: .accepted, chapterID: "other")

        let updated = GlossEntry.stalingAcceptedSentenceTranslations(
            [matching, pending, other],
            chapterID: "chapter",
            source: " Original   sentence. "
        )

        #expect(updated.first(where: { $0.id == "matching" })?.status == .stale)
        #expect(updated.first(where: { $0.id == "pending" })?.status == .pending)
        #expect(updated.first(where: { $0.id == "other" })?.status == .accepted)
    }

    private func gloss(id: String, source: String, status: GlossStatus, chapterID: String) -> GlossEntry {
        GlossEntry(
            id: id,
            kind: .sentence,
            language: "zh-Hans",
            source: source,
            text: "Translation",
            status: status,
            model: "model",
            chapterID: chapterID,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}
