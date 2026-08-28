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
        #expect(IPadBackgroundJobsToolbarPlacement.owner(
            isVocabularySelected: false,
            isReaderActive: false,
            isSettingsSelected: true,
            hasSelectedBook: false
        ) == .detail)
    }

    @Test("Opening the reader focuses the detail column instead of keeping three equal columns")
    func readerUsesFocusedDetailColumns() {
        #expect(IPadSplitColumnPolicy.mode(
            isReaderActive: true,
            isVocabularySelected: false,
            showsLibraryAlongside: false
        ) == .readingFocused)
        #expect(IPadSplitColumnPolicy.mode(
            isReaderActive: true,
            isVocabularySelected: false,
            showsLibraryAlongside: true
        ) == .readingWithLibrary)
        #expect(IPadSplitColumnPolicy.contentMax - IPadSplitColumnPolicy.contentMin >= 280)
    }

    @Test("Vocabulary uses the focused detail column instead of an empty middle pane")
    func vocabularyUsesFocusedDetailColumn() {
        #expect(IPadSplitColumnPolicy.mode(
            isReaderActive: false,
            isVocabularySelected: true,
            showsLibraryAlongside: false
        ) == .vocabularyFocused)
    }

    @Test("Settings uses a sidebar-plus-detail page instead of a sheet")
    func settingsUsesSidebarAndDetail() {
        #expect(IPadSplitColumnPolicy.mode(
            isReaderActive: false,
            isVocabularySelected: false,
            isSettingsSelected: true,
            showsLibraryAlongside: false
        ) == .settings)
        #expect(AppTab.allCases.contains(.settings))
    }
}
