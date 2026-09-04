import XCTest

@MainActor
final class AudioReaderIOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFirstRunOffersPairedImportAtTouchSize() {
        let app = launch(scenario: "empty-library")

        revealSidebar(in: app)
        XCTAssertTrue(element("sidebar.library", in: app).waitForExistence(timeout: 5))
        element("sidebar.library", in: app).tap()
        XCTAssertTrue(element("library.importMedia", in: app).isHittable)
        XCTAssertTrue(element("library.search", in: app).exists)
    }

    func testSelectedBookKeepsListAndDetailTextVisible() {
        let app = launch(scenario: "library")

        revealSidebar(in: app)
        element("sidebar.library", in: app).tap()
        let row = element("library.book.ui-book-1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(element("library.bookTitle.ui-book-1", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["A Clear Beginning"].exists)
    }

    func testSettingsOffersOnlySupportedIPadAIConnections() {
        let app = launch(scenario: "library")

        navigate(to: "sidebar.settings", in: app)
        let connection = element("settings.llmConnection", in: app)
        XCTAssertTrue(scrollToExistence(connection, in: app))
        connection.tap()

        for label in [
            "AudioReader · Managed Qwen",
            "xAI · API key",
            "Qwen · API key",
            "OpenAI · API key",
            "On-device · Apple Intelligence",
        ] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3), "Missing \(label)")
        }
        XCTAssertFalse(app.buttons["xAI · Grok Build (OAuth)"].exists)
        XCTAssertFalse(app.buttons["OpenAI · ChatGPT plan (OAuth)"].exists)
    }

    func testSidebarReadingLookupAndDueReview() {
        let app = launch(scenario: "library")

        navigate(to: "sidebar.nowReading", in: app)
        XCTAssertTrue(element("reader.sentence.ui-sentence-1", in: app).waitForExistence(timeout: 3))
        element("reader.sentence.ui-sentence-1", in: app).tap()
        XCTAssertTrue(element("reader.word.ui-word-1", in: app).isHittable)
        element("reader.word.ui-word-1", in: app).tap()
        let lookupTitle = app.staticTexts["Lookup"]
        XCTAssertTrue(lookupTitle.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(lookupTitle.frame.minY, app.frame.height * 0.35)
        XCTAssertTrue(app.buttons["Dictionary"].isSelected)
        XCTAssertTrue(app.buttons["Open Apple Dictionary"].waitForExistence(timeout: 3))
        XCTAssertFalse(element("reader.lookup.meaning", in: app).exists)
        app.buttons["Learning"].tap()
        XCTAssertTrue(element("reader.lookup.meaning", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Open Apple Dictionary"].exists)
        app.buttons["Dictionary"].tap()
        XCTAssertTrue(app.buttons["Open Apple Dictionary"].waitForExistence(timeout: 3))
        app.buttons["Open Apple Dictionary"].tap()
        let dictionaryClose = app.buttons["DDUIDone"].firstMatch
        XCTAssertTrue(dictionaryClose.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Dictionary"].exists)
        XCTAssertGreaterThan(dictionaryClose.frame.minY, app.frame.height * 0.2)
        dictionaryClose.tap()
        XCTAssertTrue(app.staticTexts["Lookup"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(element("reader.word.ui-word-1", in: app).value as? String, "current audio word, selected for lookup")
        element("reader.lookup.close", in: app).tap()
        element("reader.word.ui-word-2", in: app).tap()
        XCTAssertTrue(app.staticTexts["Lookup"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(element("reader.word.ui-word-1", in: app).value as? String, "current audio word")
        XCTAssertEqual(element("reader.word.ui-word-2", in: app).value as? String, "selected for lookup")
        element("reader.lookup.close", in: app).tap()
        XCTAssertEqual(element("reader.word.ui-word-2", in: app).value as? String, "")

        app.buttons["Chapter AI"].tap()
        let chapterAITitle = app.staticTexts["Chapter AI"]
        XCTAssertTrue(chapterAITitle.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(chapterAITitle.frame.minY, app.frame.height * 0.35)
        element("reader.chapterAI.close", in: app).tap()

        app.terminate()
        let wordsApp = launch(scenario: "words")
        XCTAssertTrue(element("words.reviewDue", in: wordsApp).waitForExistence(timeout: 3))
    }

    func testWordsUsesTheSameLearningFirstWorkspaceAsMacOS() {
        let app = launch(scenario: "words-rich")

        XCTAssertTrue(element("words.section.today", in: app).waitForExistence(timeout: 5))
        let studyToday = element("words.studyToday", in: app)
        XCTAssertTrue(studyToday.isHittable)
        XCTAssertEqual(studyToday.label, "Study 24 cards today")
        XCTAssertEqual(element("words.metric.learning", in: app).label, "Learning, 4")
        XCTAssertTrue(element("words.metric.reviewedToday", in: app).exists)
        XCTAssertTrue(element("words.todayCards", in: app).exists)
        XCTAssertTrue(scrollToExistence(element("words.todayCard.ui-vocab-due-0", in: app), in: app))
        XCTAssertTrue(scrollToExistence(element("words.todayCard.ui-vocab-new-15", in: app), in: app))
        XCTAssertFalse(element("words.todayCard.ui-vocab-new-16", in: app).exists)
        XCTAssertTrue(scrollToExistence(
            app.staticTexts["The study session includes 4 more cards after this preview."],
            in: app
        ))

        element("words.section.library", in: app).tap()
        XCTAssertTrue(element("words.listFilter", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("words.scope.all", in: app).exists)
        XCTAssertEqual(element("words.pageRange", in: app).label, "Showing 1–80 of 85")
        element("words.pageLast", in: app).tap()
        XCTAssertEqual(element("words.pageRange", in: app).label, "Showing 81–85 of 85")
        XCTAssertTrue(element("words.row.ui-vocab-new-76", in: app).waitForExistence(timeout: 3))
        let firstPage = element("words.pageFirst", in: app)
        XCTAssertGreaterThanOrEqual(firstPage.frame.width, 44)
        XCTAssertGreaterThanOrEqual(firstPage.frame.height, 44)
        element("words.pagePicker", in: app).tap()
        app.buttons["Page 1 of 2"].firstMatch.tap()
        XCTAssertTrue(element("words.row.ui-vocab-new-0", in: app).waitForExistence(timeout: 3))

        element("words.scope.learning", in: app).tap()
        XCTAssertTrue(waitForNonExistence(element("words.row.ui-vocab-new-0", in: app), timeout: 3))
        XCTAssertTrue(element("words.row.ui-vocab-due-0", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("words.row.ui-vocab-due-3", in: app).exists)
        element("words.myList.ui-vocab-due-0", in: app).tap()
        XCTAssertTrue(element("words.row.ui-vocab-due-0", in: app).exists)

        element("words.scope.myList", in: app).tap()
        XCTAssertTrue(waitForNonExistence(element("words.row.ui-vocab-due-0", in: app), timeout: 3))
        XCTAssertFalse(element("words.row.ui-vocab-due-3", in: app).exists)
        XCTAssertTrue(element("words.row.ui-vocab-due-1", in: app).exists)

        element("words.scope.known", in: app).tap()
        element("words.known.add", in: app).tap()
        let knownWord = app.textFields["Word"].firstMatch
        XCTAssertTrue(knownWord.waitForExistence(timeout: 3))
        knownWord.tap()
        knownWord.typeText("Done.")
        app.buttons["Add"].firstMatch.tap()
        XCTAssertTrue(element("words.known.en.do", in: app).waitForExistence(timeout: 3))
        app.buttons["Remove do from Known"].firstMatch.tap()
        XCTAssertTrue(waitForNonExistence(element("words.known.en.do", in: app), timeout: 3))

        app.terminate()
        let sidebarApp = launch(scenario: "library")
        revealSidebar(in: sidebarApp)
        for destination in ["sidebar.library", "sidebar.nowReading", "sidebar.words", "sidebar.settings"] {
            XCTAssertTrue(element(destination, in: sidebarApp).waitForExistence(timeout: 3))
        }
    }

    func testCorrectionRestoreAndSyncActions() {
        let app = launch(scenario: "reader")

        if !element("transcript.edit", in: app).waitForExistence(timeout: 3) {
            navigate(to: "sidebar.nowReading", in: app)
        }
        XCTAssertTrue(element("transcript.edit", in: app).waitForExistence(timeout: 3))
        element("transcript.edit", in: app).tap()
        let text = element("transcript.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        text.tap()
        text.typeText(" Corrected.")
        XCTAssertTrue(element("transcript.preview", in: app).isHittable)
        element("transcript.preview", in: app).tap()
        let save = element("transcript.save", in: app)
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(element("transcript.edit", in: app).waitForExistence(timeout: 3))
        element("transcript.edit", in: app).tap()
        XCTAssertTrue(element("transcript.restore", in: app).waitForExistence(timeout: 3))
        element("transcript.restore", in: app).tap()

        app.terminate()
        let libraryApp = launch(scenario: "library")
        revealSidebar(in: libraryApp)
        XCTAssertTrue(element("sync.status", in: libraryApp).waitForExistence(timeout: 3))
        XCTAssertTrue(element("sync.now", in: libraryApp).exists)
    }

    func testAnkiExportSelectionIsExplicitAndTemporary() {
        let app = launch(scenario: "words-rich")
        let entryID = "ui-vocab-due-0"

        element("words.section.library", in: app).tap()
        XCTAssertTrue(element("words.row.\(entryID)", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("anki.selection.\(entryID)", in: app).exists)

        let myList = element("words.myList.\(entryID)", in: app)
        XCTAssertTrue(scrollToExistence(myList, in: app))
        let originalMyListLabel = myList.label

        enterAnkiExportSelection(in: app)
        let selection = element("anki.selection.\(entryID)", in: app)
        XCTAssertTrue(scrollToExistence(selection, in: app))
        XCTAssertEqual(selection.value as? String, "Not selected")
        selection.tap()

        let count = element("anki.selection.count", in: app)
        XCTAssertTrue(count.waitForExistence(timeout: 3))
        XCTAssertEqual(count.value as? String, "1 selected")
        XCTAssertEqual(selection.value as? String, "Selected")
        XCTAssertEqual(myList.label, originalMyListLabel)

        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(waitForNonExistence(count, timeout: 3))
        XCTAssertTrue(waitForNonExistence(selection, timeout: 3))
        XCTAssertEqual(myList.label, originalMyListLabel)

        enterAnkiExportSelection(in: app)
        let secondSelection = element("anki.selection.\(entryID)", in: app)
        XCTAssertTrue(scrollToExistence(secondSelection, in: app))
        secondSelection.tap()
        XCTAssertEqual(element("anki.selection.count", in: app).value as? String, "1 selected")

        app.buttons["Export"].firstMatch.tap()
        XCTAssertTrue(waitForNonExistence(element("anki.selection.count", in: app), timeout: 3))
        XCTAssertTrue(waitForNonExistence(secondSelection, timeout: 3))
        XCTAssertEqual(myList.label, originalMyListLabel)
    }

    func testReducedMotionFixtureKeepsReaderUsable() {
        let app = launch(scenario: "reader", reduceMotion: true)
        if !element("reader.sentence.ui-sentence-1", in: app).waitForExistence(timeout: 3) {
            navigate(to: "sidebar.nowReading", in: app)
        }
        XCTAssertTrue(element("reader.sentence.ui-sentence-1", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("reader.word.ui-word-1", in: app).isHittable)
    }

    func testListenFirstPauseAndGroundedQuiz() {
        let app = launch(scenario: "listen-first")

        XCTAssertTrue(element("reader.listenFirstCoach", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Future sentence hidden in Listen First."].exists)

        app.buttons["Quick Quiz"].tap()
        XCTAssertTrue(app.staticTexts["Quick quiz"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Why this answer"].exists)
    }

    func testReadAndPauseKeepsTextVisibleWithReplayAndContinue() {
        let app = launch(scenario: "read-and-pause")

        XCTAssertTrue(element("reader.readAndPauseCoach", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("reader.word.ui-sentence-4-word-0", in: app).exists)
        XCTAssertTrue(app.buttons["Tomorrow brings another chapter."].exists)
        XCTAssertTrue(element("reader.readAndPauseReplay", in: app).isHittable)
        XCTAssertTrue(element("reader.readAndPauseContinue", in: app).isHittable)
        XCTAssertFalse(app.staticTexts["Future sentence hidden in Listen First."].exists)
    }

    func testPlayOnTapMovesAWordAwayFromThePreviousPacedPause() {
        let app = launch(scenario: "playback-anchor")
        let secondSentence = element("reader.sentence.ui-sentence-2", in: app)
        XCTAssertTrue(secondSentence.waitForExistence(timeout: 3))
        secondSentence.tap()
        XCTAssertTrue(waitForLabel(element("reader.playback.toggle", in: app), label: "Pause", timeout: 2))
        element("reader.playback.toggle", in: app).tap()

        let secondWord = element("reader.word.ui-sentence-2-word-0", in: app)
        XCTAssertTrue(secondWord.waitForExistence(timeout: 3))
        secondWord.tap()
        XCTAssertTrue(app.staticTexts["Lookup"].waitForExistence(timeout: 3))
        element("reader.lookup.close", in: app).tap()
        XCTAssertTrue(element("reader.readAndPauseCoach", in: app).waitForExistence(timeout: 4))
        XCTAssertEqual(
            element("reader.word.ui-sentence-2-word-3", in: app).value as? String,
            "current audio word"
        )
    }

    func testTranslationActionsStayCompactBesideLookup() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(scenario: "translation-layout")

        XCTAssertTrue(app.staticTexts["Lookup"].waitForExistence(timeout: 3))
        app.buttons["Learning"].tap()
        element("reader.lookup.close", in: app).tap()
        XCTAssertTrue(app.staticTexts["Draft · Model: qwen3.6-flash"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("reader.translation.accept", in: app).isHittable)
        XCTAssertTrue(element("reader.translation.reject", in: app).isHittable)
        XCTAssertTrue(element("reader.translation.edit", in: app).isHittable)
        XCTAssertTrue(element("reader.translation.retranslate", in: app).isHittable)
        XCTAssertFalse(app.buttons["More"].exists)
    }

    func testEPUBCoverContentsSearchAndChapterJump() {
        let app = launch(scenario: "epub-reader")

        XCTAssertTrue(element("reader.epubCover", in: app).waitForExistence(timeout: 5))
        element("reader.bookNavigation", in: app).tap()
        XCTAssertTrue(element("reader.bookNavigation.sheet", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["The Arrival"].exists)
        let search = element("reader.bookSearch", in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("paper lantern")
        XCTAssertTrue(app.staticTexts["The Lantern Room"].waitForExistence(timeout: 3))
        let matchingChapters = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "The Lantern Room")
        )
        matchingChapters.element(boundBy: matchingChapters.count - 1).tap()
        let chapterHeader = app.navigationBars.matching(
            NSPredicate(format: "identifier CONTAINS %@", "The Lantern Room")
        ).firstMatch
        XCTAssertTrue(chapterHeader.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["paper"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["lantern"].exists)
    }

    private func navigate(to identifier: String, in app: XCUIApplication) {
        revealSidebar(in: app)
        let destination = element(identifier, in: app)
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        destination.tap()
    }

    private func revealSidebar(in app: XCUIApplication) {
        guard !element("sidebar.library", in: app).exists else { return }
        // Three-column split views may require revealing content before the
        // destination sidebar; re-query after each navigation transition.
        for _ in 0..<2 where !element("sidebar.library", in: app).exists {
            let toggles = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Show Sidebar"))
            XCTAssertGreaterThan(toggles.count, 0)
            toggles.element(boundBy: toggles.count - 1).tap()
            _ = element("sidebar.library", in: app).waitForExistence(timeout: 1)
        }
        XCTAssertTrue(element("sidebar.library", in: app).waitForExistence(timeout: 3))
    }

    private func enterAnkiExportSelection(in app: XCUIApplication) {
        let identifiedExport = element("anki.export", in: app)
        let export: XCUIElement
        if waitForHittable(identifiedExport, timeout: 2) {
            export = identifiedExport
        } else {
            let vocabularyActions = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Vocabulary actions")
            ).firstMatch
            if !waitForHittable(vocabularyActions, timeout: 2) {
                let more = app.buttons["More"].firstMatch
                XCTAssertTrue(more.waitForExistence(timeout: 3))
                more.tap()
            }
            XCTAssertTrue(waitForHittable(vocabularyActions, timeout: 3))
            vocabularyActions.tap()
            export = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Export to Anki")
            ).firstMatch
        }
        XCTAssertTrue(waitForHittable(export, timeout: 3))
        export.tap()
        let select = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Select for Anki export")
        ).firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        select.tap()
    }

    private func launch(scenario: String, reduceMotion: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-scenario=\(scenario)"]
        if reduceMotion {
            app.launchArguments.append("--uitesting-reduce-motion")
        }
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func scrollToExistence(
        _ target: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 12
    ) -> Bool {
        if target.exists { return true }
        for _ in 0..<attempts {
            app.swipeUp()
            if target.waitForExistence(timeout: 0.3) { return true }
        }
        return false
    }
}
