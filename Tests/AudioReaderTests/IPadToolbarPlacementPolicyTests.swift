import Testing
@testable import AudioReader

@Suite("iPad background-jobs toolbar placement")
struct IPadToolbarPlacementPolicyTests {
    @Test("The visible detail state is the sole toolbar owner")
    func activeColumnOwnsBackgroundJobsToolbar() {
        #expect(IPadBackgroundJobsToolbarPlacement.owner(
            isVocabularySelected: false,
            isReaderActive: false,
            hasSelectedBook: false
        ) == .content)
        #expect(IPadBackgroundJobsToolbarPlacement.owner(
            isVocabularySelected: true,
            isReaderActive: false,
            hasSelectedBook: false
        ) == .detail)
        #expect(IPadBackgroundJobsToolbarPlacement.owner(
            isVocabularySelected: false,
            isReaderActive: false,
            hasSelectedBook: true
        ) == .detail)
        #expect(IPadBackgroundJobsToolbarPlacement.owner(
            isVocabularySelected: false,
            isReaderActive: true,
            hasSelectedBook: true
        ) == .detail)
    }
}
