import Foundation
import Testing
@testable import AudioReader

@Suite("Temporary Anki export selection")
struct AnkiExportSelectionTests {
    @Test("Selection is available only inside explicit export mode")
    func selectionRequiresExportMode() {
        var selection = AnkiExportSelectionState()

        selection.toggle("one")
        #expect(!selection.isActive)
        #expect(selection.selectedIDs.isEmpty)

        selection.begin()
        selection.toggle("one")
        selection.toggle("two")
        #expect(selection.isActive)
        #expect(selection.selectedCount == 2)
        #expect(selection.isSelected("one"))

        selection.toggle("one")
        #expect(selection.selectedIDs == ["two"])
    }

    @Test("Cancel, navigation away, and export completion clear temporary selection")
    func everyExitClearsSelection() {
        var selection = AnkiExportSelectionState()

        selection.begin()
        selection.toggle("one")
        selection.cancel()
        #expect(!selection.isActive)
        #expect(selection.selectedIDs.isEmpty)

        selection.begin()
        selection.toggle("two")
        selection.leaveVocabulary()
        #expect(!selection.isActive)
        #expect(selection.selectedIDs.isEmpty)

        selection.begin()
        selection.toggle("three")
        selection.completeExport()
        #expect(!selection.isActive)
        #expect(selection.selectedIDs.isEmpty)
    }

    @Test("Selected export content preserves learning, review, and My List state")
    func selectedEntriesDoNotMutateVocabularyState() {
        var first = entry(id: "one", reviewCount: 4, isInLearnList: true)
        first.nextReview = Date(timeIntervalSince1970: 2_000_000)
        let second = entry(id: "two", reviewCount: 1, isInLearnList: false)
        let entries = [first, second]
        let original = entries
        var selection = AnkiExportSelectionState()
        selection.begin()
        selection.toggle("two")

        let exported = selection.entriesForExport(from: entries)

        #expect(exported.map(\.id) == ["two"])
        #expect(entries == original)
        #expect(entries[0].reviewCount == 4)
        #expect(entries[0].nextReview == Date(timeIntervalSince1970: 2_000_000))
        #expect(entries[0].isInLearnList)
        #expect(entries[1].reviewCount == 1)
        #expect(!entries[1].isInLearnList)
    }

    private func entry(id: String, reviewCount: Int, isInLearnList: Bool) -> VocabEntry {
        VocabEntry(
            id: id,
            word: id,
            context: "A sentence containing \(id).",
            bookID: "book",
            bookTitle: "Book",
            chapterID: "chapter",
            chapterTitle: "Chapter",
            timestamp: 1,
            addedAt: Date(timeIntervalSince1970: 1_000_000),
            reviewCount: reviewCount,
            isInLearnList: isInLearnList
        )
    }
}
