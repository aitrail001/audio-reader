import Foundation
import Testing
@testable import AudioReader

@Suite("Native redesign presentation contracts")
struct NativeRedesignContractTests {
    @Test("macOS destinations live in the sidebar and have keyboard commands")
    func macDestinationNavigation() throws {
        let root = try source("Sources/AudioReader/RootView.swift")
        let app = try source("Sources/AudioReader/AudioReaderApp.swift")

        #expect(!root.contains(".pickerStyle(.segmented)\n                .frame(width: 360)"))
        #expect(root.contains("sidebar.library"))
        #expect(root.contains("sidebar.nowReading"))
        #expect(root.contains("sidebar.words"))
        #expect(root.contains("sidebar.settings"))
        #expect(app.contains("Button(\"Library\")"))
        #expect(app.contains("Button(\"Now Reading\")"))
        #expect(app.contains("Button(\"Words\")"))
        #expect(app.contains(".keyboardShortcut(\"1\", modifiers: [.command])"))
        #expect(app.contains(".keyboardShortcut(\"2\", modifiers: [.command])"))
        #expect(app.contains(".keyboardShortcut(\"3\", modifiers: [.command])"))
        #expect(app.contains("Button(\"Settings\")"))
        #expect(app.contains(".keyboardShortcut(\",\", modifiers: [.command])"))
    }

    @Test("library actions are searchable, focusable, and deterministic")
    func accessibleLibraryActions() throws {
        let library = try source("Sources/AudioReader/LibraryView.swift")

        #expect(library.contains(".searchable(text: $query"))
        #expect(library.contains("library.search"))
        #expect(library.contains("library.importPaired"))
        #expect(library.contains("library.continue"))
        #expect(library.contains("library.repair"))
        #expect(!library.contains(".onTapGesture"))
        #expect(library.contains("Button"))
        #expect(library.contains(".accessibilityAction(named: \"Continue reading\")"))
    }

    @Test("reader interactions have controls, identifiers, and reduced-motion behavior")
    func accessibleReaderInteractions() throws {
        let player = try source("Sources/AudioReader/PlayerView.swift")
        let sentence = try section(in: player, from: "private struct SentenceRow: View", to: "private struct WordToken: View")
        let word = try section(in: player, from: "private struct WordToken: View", to: "private struct WordInspector: View")

        #expect(!sentence.contains(".onTapGesture"))
        #expect(!word.contains(".onTapGesture"))
        #expect(sentence.contains("reader.sentence."))
        #expect(word.contains("reader.word."))
        #expect(sentence.contains(".accessibilityAction(named: \"Play from sentence\")"))
        #expect(word.contains(".accessibilityAction(named: \"Add to vocabulary\")"))
        #expect(player.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(player.contains("minHeight: 44"))
    }

    @Test("sentence corrections and progress conflicts use the shared resolved reader state")
    func correctionAndProgressPresentation() throws {
        let player = try source("Sources/AudioReader/PlayerView.swift")
        let appState = try source("Sources/AudioReader/AppState.swift")
        let library = try source("Sources/AudioReader/LibraryView.swift")
        let iPad = try source("Sources/AudioReader/IPadRootView.swift")

        #expect(player.contains("state.presentedTranscript?.segments"))
        #expect(player.contains("transcript.edit"))
        #expect(player.contains("transcript.preview"))
        #expect(player.contains("transcript.save"))
        #expect(player.contains("ToolbarItemGroup(placement: .topBarTrailing)"))
        #expect(player.contains("private func saveCorrection()"))
        #expect(player.contains("transcript.restore"))
        #expect(player.contains("state.saveTranscriptCorrection"))
        #expect(player.contains("state.restoreTranscriptCorrection"))
        #expect(player.contains("state.readerProgressChoices"))
        #expect(player.contains("state.resolveReaderProgress"))
        #expect(player.contains("transcript.conflictBanner"))
        #expect(player.contains("transcript.conflictReview."))
        #expect(appState.contains("persistCurrentPosition: false"))
        #expect(appState.contains("Task { await account.synchronize() }"))
        #expect(library.contains("state.continueReading(book)"))
        #expect(iPad.contains("state.continueReading(book)"))
    }

    @Test("Words leads with due review and keeps a stable identifier")
    func dueReviewPrimaryAction() throws {
        let vocabulary = try source("Sources/AudioReader/VocabularyView.swift")

        #expect(vocabulary.contains("due in this view"))
        #expect(vocabulary.contains("words.reviewDue"))
        #expect(vocabulary.contains("VocabularyListFilter.allCases"))
        #expect(vocabulary.contains("VocabularyFilterProjection.make"))
        #expect(vocabulary.contains("ForEach(page.entries)"))
        #expect(vocabulary.contains("words.pagePicker"))
        #expect(vocabulary.contains("page.rangeDescription"))
        #expect(!vocabulary.contains("visibleLimit"))
        #expect(vocabulary.contains(".task(id: learningRefreshRequest)"))
        #expect(vocabulary.contains("withTaskCancellationHandler"))
        #expect(vocabulary.contains("learningSnapshotRequest == learningRefreshRequest"))
        #expect(!vocabulary.contains("private var filtered"))
        #expect(!vocabulary.contains("VocabReviewScheduler.dueEntries(in: filtered"))
        #expect(vocabulary.contains("minHeight: 44"))
    }

    @Test("Review sessions advance only after durable grading")
    func durableReviewAdvancement() throws {
        let appState = try source("Sources/AudioReader/AppState.swift")
        let review = try source("Sources/AudioReader/VocabularyReviewView.swift")

        #expect(appState.contains("@discardableResult\n    func reviewVocabulary("))
        #expect(appState.contains(") async -> Bool"))
        #expect(review.contains("await state.reviewVocabulary("))
        #expect(review.contains("reviewedCount = nextReviewedCount"))
        #expect(review.contains("isSavingReview"))
        #expect(review.contains(".interactiveDismissDisabled(isSavingReview)"))
    }

    @Test("Learning dashboard stays on the opaque paper stack and uses a quiet streak symbol")
    func learningDashboardVisualGrounds() throws {
        let dashboard = try source("Sources/AudioReader/VocabularyLearningDashboard.swift")

        #expect(dashboard.contains(#"symbol: "calendar""#))
        #expect(!dashboard.contains(#"symbol: "flame""#))
        #expect(dashboard.contains(".background(Palette.panel)"))
        #expect(!dashboard.contains(".background(Palette.panel.opacity"))
    }

    @Test("macOS Words header keeps its actions concise at ordinary split-view widths")
    func vocabularyHeaderUsesCompactActions() throws {
        let vocabulary = try source("Sources/AudioReader/VocabularyView.swift")

        #expect(vocabulary.contains(#"Label("Review due — \(projection.due.count)""#))
        #expect(vocabulary.contains(#"Label("Choose review""#))
    }

    @Test("Anki export selection is explicit, temporary, accessible, and distinct from My List")
    func ankiExportSelectionModeContract() throws {
        let vocabulary = try source("Sources/AudioReader/VocabularyView.swift")

        #expect(vocabulary.contains(#"Button("Select for Anki export")"#))
        #expect(vocabulary.contains("if exportSelection.isActive"))
        #expect(vocabulary.contains(#"Text("\(exportSelection.selectedCount) selected")"#))
        #expect(vocabulary.contains(#"Button("Cancel")"#))
        #expect(vocabulary.contains("exportSelection.completeExport()"))
        #expect(vocabulary.contains("exportSelection.leaveVocabulary()"))
        #expect(vocabulary.contains(".onDisappear"))
        #expect(vocabulary.contains("showsExportSelection: exportSelection.isActive"))
        #expect(vocabulary.contains("if showsExportSelection"))
        #expect(vocabulary.contains("Temporary Anki export selection"))
        #expect(vocabulary.contains(".accessibilityValue(selectedForExport ? \"Selected\" : \"Not selected\")"))
        #expect(vocabulary.contains(".accessibilityAddTraits(selectedForExport ? .isSelected : [])"))
        #expect(vocabulary.contains("words.myList."))

        let export = try section(
            in: vocabulary,
            from: "private func startAnkiExport(scope: AnkiExportScope)",
            to: "private func beginAnkiExportSelection()"
        )
        let clear = try #require(export.range(of: "exportSelection.completeExport()"))
        let asyncWork = try #require(export.range(of: "Task {"))
        #expect(clear.lowerBound < asyncWork.lowerBound)
    }

    @Test("iPad destinations and import actions meet touch and automation contracts")
    func iPadTouchContracts() throws {
        let root = try source("Sources/AudioReader/IPadRootView.swift")
        let vocabulary = try source("Sources/AudioReader/VocabularyView.swift")

        #expect(root.contains("sidebar.library"))
        #expect(root.contains("sidebar.nowReading"))
        #expect(root.contains("sidebar.words"))
        #expect(root.contains("sidebar.settings"))
        #expect(root.contains("library.importMedia"))
        #expect(root.contains("library.importDevice."))
        #expect(root.contains("AccountSyncStatusView(session: state.account, compact: true)"))
        #expect(root.contains("minHeight: 44"))
        #expect(vocabulary.contains("words.category."))
        #expect(vocabulary.contains("pendingAnkiReport"))
        #expect(vocabulary.contains("ankiReport = pendingAnkiReport"))
    }

    @Test("iPad compact navigation and study controls keep native accessibility contracts")
    func iPadCompactPolishContracts() throws {
        let settings = try source("Sources/AudioReader/SettingsView.swift")
        let root = try source("Sources/AudioReader/IPadRootView.swift")
        let player = try source("Sources/AudioReader/PlayerView.swift")
        let shadowing = try source("Sources/AudioReader/ShadowingPracticeView.swift")
        let review = try source("Sources/AudioReader/VocabularyReviewView.swift")

        #expect(!settings.contains(".navigationBarBackButtonHidden(true)"))
        #expect(root.contains(".scrollContentBackground(.hidden)"))
        #expect(root.contains(".fill(Palette.panel2)"))
        #expect(player.contains(".frame(width: 44, height: 44)"))
        #expect(shadowing.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(review.contains("case .forgot, .vague: Palette.panel2"))
        #expect(review.contains("case .remember: Palette.gold"))
        #expect(!review.contains("case .forgot: .red"))
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
