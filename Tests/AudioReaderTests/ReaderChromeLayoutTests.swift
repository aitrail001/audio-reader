import Foundation
import Testing
@testable import AudioReader

@Suite("Reader and iPad chrome layout")
struct ReaderChromeLayoutTests {
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

    @Test("iPad reader chrome uses half-height Lookup and Chapter AI sheets")
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
        #expect(playerView.contains("private enum ReaderAuxiliarySheet"))
        #expect(playerView.contains("private var iPadAuxiliarySheetBinding: Binding<ReaderAuxiliarySheet?>"))
        #expect(playerView.contains(".sheet(item: iPadAuxiliarySheetBinding)"))
        #expect(playerView.contains("case .lookup:"))
        #expect(playerView.contains("case .chapterAI:"))
        #expect(playerView.contains(".presentationDetents([.medium])"))
        #expect(!playerView.contains(".presentationDetents([.medium, .large])"))
        #expect(playerView.contains(".presentationDragIndicator(.visible)"))
        #expect(playerView.contains(".presentationSizing(.form)"))
        #expect(!playerView.contains(".presentationSizing(.page)"))
        #expect(playerView.contains(".accessibilityIdentifier(\"reader.chapterAI.close\")"))
        #expect(!playerView.contains("SplitterPanHandle"))
        #expect(!playerView.contains("ReaderSplitGeometry("))
        #expect(!playerView.contains(".accessibilityLabel(\"Resize lookup panel\")"))
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
        #expect(!sentenceRow.contains("Menu(\"More\")"))
        #expect(sentenceRow.contains("reader.translation.edit"))
        #expect(sentenceRow.contains("reader.translation.retranslate"))
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
