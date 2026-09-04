import Foundation
import Testing
@testable import AudioReader

@Suite("Reader split and iPad chrome layout")
struct ReaderChromeLayoutTests {
    @Test("Wide containers keep the stored lookup width and a readable text column")
    func wideLookupSplitHonorsStoredWidth() {
        let geometry = ReaderSplitGeometry(
            containerWidth: 1100,
            proposedLookupWidth: 420,
            isLookupOpen: true,
            splitterWidth: 8
        )

        #expect(geometry.lookupWidth == 420)
        #expect(geometry.textWidth == 672)
    }

    @Test("Narrow containers prefer reading text over the lookup panel")
    func narrowLookupSplitPrefersText() {
        let iPadMiniDetail = ReaderSplitGeometry(
            containerWidth: 500,
            proposedLookupWidth: 420,
            isLookupOpen: true,
            splitterWidth: ReaderSplitLayout.iPadSplitterWidth
        )

        #expect(iPadMiniDetail.lookupWidth < 220)
        #expect(iPadMiniDetail.textWidth >= ReaderSplitLayout.absoluteMinimumTextWidth)
        #expect(iPadMiniDetail.textWidth + iPadMiniDetail.lookupWidth + ReaderSplitLayout.iPadSplitterWidth == 500)
    }

    @Test("Closing lookup gives the transcript the full canvas")
    func closedLookupUsesFullWidth() {
        let geometry = ReaderSplitGeometry(
            containerWidth: 744,
            proposedLookupWidth: 420,
            isLookupOpen: false,
            splitterWidth: ReaderSplitLayout.iPadSplitterWidth
        )

        #expect(geometry.lookupWidth == 0)
        #expect(geometry.textWidth == 744)
    }

    @Test("Dragging the splitter is clamped instead of covering the transcript")
    func splitterDragStaysWithinReadableBounds() {
        let draggedWider = ReaderSplitLayout.clampedLookupWidth(
            proposed: 900,
            containerWidth: 744,
            splitterWidth: ReaderSplitLayout.iPadSplitterWidth
        )
        let draggedNarrower = ReaderSplitLayout.clampedLookupWidth(
            proposed: 40,
            containerWidth: 744,
            splitterWidth: ReaderSplitLayout.iPadSplitterWidth
        )

        #expect(draggedWider == 744 - ReaderSplitLayout.preferredMinimumTextWidth - ReaderSplitLayout.iPadSplitterWidth)
        #expect(draggedNarrower == ReaderSplitLayout.minimumLookupWidth)
        #expect(ReaderSplitLayout.textWidth(
            containerWidth: 744,
            lookupWidth: draggedWider,
            isLookupOpen: true,
            splitterWidth: ReaderSplitLayout.iPadSplitterWidth
        ) == ReaderSplitLayout.preferredMinimumTextWidth)
    }

    @Test("A compact iPad reader opens lookup at a fraction of the canvas")
    func initialLookupWidthLeavesRoomForText() {
        let portrait = ReaderSplitLayout.initialLookupWidth(
            stored: 420,
            containerWidth: 744,
            splitterWidth: ReaderSplitLayout.iPadSplitterWidth
        )
        let landscape = ReaderSplitLayout.initialLookupWidth(
            stored: 420,
            containerWidth: 1133,
            splitterWidth: ReaderSplitLayout.iPadSplitterWidth
        )

        #expect(portrait < 420)
        #expect(ReaderSplitLayout.textWidth(
            containerWidth: 744,
            lookupWidth: portrait,
            isLookupOpen: true,
            splitterWidth: ReaderSplitLayout.iPadSplitterWidth
        ) > 400)
        #expect(landscape == 420)
    }

    @Test("iPad column policy focuses the reader and leaves a real resize range")
    func iPadColumnsFocusReaderAndCanResize() {
        #expect(IPadSplitColumnPolicy.contentMax - IPadSplitColumnPolicy.contentMin >= 280)
        #expect(IPadSplitColumnPolicy.contentMin <= 220)
        #expect(IPadSplitColumnPolicy.mode(
            isReaderActive: false,
            isVocabularySelected: false,
            showsLibraryAlongside: false
        ) == .library)
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
        #expect(IPadSplitColumnPolicy.mode(
            isReaderActive: false,
            isVocabularySelected: true,
            showsLibraryAlongside: false
        ) == .vocabularyFocused)
    }

    @Test("iPad reader chrome uses the toolbar, a draggable splitter, and one playback row")
    func iPadReaderChromeContracts() throws {
        let playerView = try source("Sources/AudioReader/PlayerView.swift")
        let iPadRoot = try source("Sources/AudioReader/IPadRootView.swift")
        let playbackBar = try section(
            in: playerView,
            from: "    private var iPadCompactPlaybackBar",
            to: "    private var iPadTransportControls"
        )
        let iPadControls = try section(
            in: playerView,
            from: "    private var iPadCompactPlaybackBar",
            to: "#endif\n}"
        )

        #expect(playerView.contains("private var iPadReaderToolbar"))
        #expect(playerView.contains("EbookNavigationSheet"))
        #expect(playerView.contains("reader.bookNavigation"))
        #expect(playerView.contains("reader.epubCover"))
        #expect(playerView.contains("Search Book"))
        #expect(playerView.contains("Contents"))
        #expect(playerView.contains("SplitterPanHandle"))
        #expect(playerView.contains("ReaderSplitGeometry("))
        #expect(playerView.contains(".accessibilityLabel(\"Resize lookup panel\")"))
        #expect(playerView.contains("applyLookupDrag(translation:"))
        #expect(!playerView.contains("showReaderToolbar"))
        #expect(!playerView.contains("private var iPadHeader"))
        #expect(!playbackBar.contains("VStack"))
        #expect(!iPadControls.contains("VStack(spacing: 6)"))
        #expect(!iPadControls.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(!iPadControls.contains(".controlSize(.large)"))
        #expect(iPadControls.contains("minHeight: 44"))
        #expect(iPadControls.contains("iPadCompactPlaybackBar"))
        #expect(iPadControls.contains(".accessibilityLabel(\"Previous chapter\")"))
        #expect(iPadControls.contains(".accessibilityLabel(\"Next chapter\")"))
        #expect(iPadControls.contains("chevron.left"))
        #expect(iPadControls.contains("chevron.right"))
        #expect(iPadRoot.contains(".navigationSplitViewStyle(.prominentDetail)"))
        #expect(!iPadRoot.contains(".navigationSplitViewStyle(.balanced)"))
        #expect(iPadRoot.contains("IPadSplitColumnPolicy.contentMin"))
        #expect(iPadRoot.contains(".doubleColumn"))
        #expect(iPadRoot.contains("Label(\"Open Book\", systemImage: \"book.pages\")"))
        #expect(iPadRoot.contains("Label(\"Book Actions\", systemImage: \"ellipsis.circle\")"))
        #expect(!iPadRoot.contains("private var bookActionButtons"))
        #expect(!iPadRoot.contains(".controlSize(.large)"))
        #expect(!iPadRoot.contains("ContentUnavailableView(\"Vocabulary\""))
        #expect(iPadRoot.contains(".vocabularyFocused"))
        #expect(playerView.contains("inspectorActionLabel()"))
        #expect(playerView.contains("Label(\"Sentence meaning\", systemImage: \"globe\")"))
        #expect(playerView.contains(".accessibilityLabel(\"This-sentence meaning"))
        #expect(playerView.contains("Toggle(\"Study overlay\""))
        #expect(playerView.components(separatedBy: "Toggle(\"Study overlay\"").count - 1 == 1)
        #expect(playerView.contains("ToolbarItemGroup(placement: .automatic)"))
        #expect(playerView.contains("desktopCompactHeaderControls"))
        let toolbarControls = try section(
            in: playerView,
            from: "    private var desktopCompactHeaderControls",
            to: "    private var sentenceLoopBinding"
        )
        #expect(toolbarControls.contains("sharedReadingMenu"))
        #expect(toolbarControls.contains("sharedLLMMenu"))
        #expect(!toolbarControls.contains("desktopProviderControls"))
        #expect(playerView.contains("readingAppearanceMenuContent"))
        #expect(playerView.contains("Chapter words"))
        #expect(playerView.contains("Mark known"))
        #expect(playerView.contains("ReaderWindowTitle.make("))
        #expect(!playerView.contains("chapterCoverageCaption"))
        #expect(!playerView.contains("chapterCoverageSubtitle"))
        #expect(!playerView.contains(".navigationSubtitle"))
        #expect(!playerView.contains("coverageCaption"))
        #expect(!playbackBar.contains("Study overlay"))
        #expect(!playbackBar.contains("% known"))
        #expect(!playbackBar.contains("This chapter"))
        #expect(!playerView.contains("ToolbarItem(placement: .primaryAction) {\n            Toggle(\"Study overlay\""))
        let sentenceRow = try section(
            in: playerView,
            from: "private struct SentenceRow: View",
            to: "private struct WordToken: View"
        )
        #expect(!sentenceRow.contains("chapterCoverage"))
        #expect(!sentenceRow.contains("This chapter"))
        #expect(sentenceRow.contains("lhs.languageLabel == rhs.languageLabel"))
        #expect(sentenceRow.contains("ViewThatFits(in: .horizontal)"))
        #expect(sentenceRow.contains("Menu(\"More\")"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func section(in source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
