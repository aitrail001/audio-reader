import XCTest

@MainActor
final class AudioReaderMacOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFirstRunOffersPairedImport() {
        let app = launch(scenario: "empty-library")

        XCTAssertTrue(element("sidebar.library", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Build your reading library"].exists)
        XCTAssertTrue(waitForHittable(app.buttons["Import Audio or EPUB"].firstMatch, timeout: 5))
        XCTAssertTrue(element("library.search", in: app).exists)
    }

    func testKeyboardNavigationAndCoreStudyFlow() {
        let app = launch(scenario: "library")

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(element("reader.sentence.ui-sentence-1", in: app).waitForExistence(timeout: 3))
        element("reader.sentence.ui-sentence-1", in: app).tap()
        XCTAssertTrue(element("reader.word.ui-word-1", in: app).isHittable)
        element("reader.word.ui-word-1", in: app).tap()

        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(element("words.reviewDue", in: app).waitForExistence(timeout: 3))

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(element("sidebar.settings", in: app).exists)
    }

    func testWordsOpensWithVisibleLearningWorkspaceAndPopulatedSidebar() {
        let app = launch(scenario: "words-rich")

        for destination in ["sidebar.library", "sidebar.nowReading", "sidebar.words", "sidebar.settings"] {
            XCTAssertTrue(element(destination, in: app).waitForExistence(timeout: 5))
        }
        XCTAssertTrue(waitForHittable(element("words.section.today", in: app), timeout: 5))
        let studyToday = button("words.studyToday", in: app)
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

        let librarySection = element("words.section.library", in: app)
        XCTAssertTrue(waitForHittable(librarySection, timeout: 5))
        librarySection.tap()
        XCTAssertTrue(element("words.listFilter", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("words.scope.all", in: app).exists)
        choose("Oldest added", from: "words.sortOrder", in: app)
        XCTAssertEqual(element("words.pageRange", in: app).value as? String, "Showing 1–80 of 85")
        button("words.pageLast", in: app).tap()
        XCTAssertEqual(element("words.pageRange", in: app).value as? String, "Showing 81–85 of 85")
        XCTAssertTrue(element("words.row.ui-vocab-new-76", in: app).waitForExistence(timeout: 3))
        button("words.pageFirst", in: app).tap()
        XCTAssertTrue(element("words.row.ui-vocab-new-0", in: app).waitForExistence(timeout: 3))

        element("words.scope.learning", in: app).tap()
        XCTAssertTrue(waitForNonExistence(element("words.row.ui-vocab-new-0", in: app), timeout: 3))
        XCTAssertTrue(element("words.row.ui-vocab-due-0", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("words.row.ui-vocab-due-3", in: app).exists)
        button("words.myList.ui-vocab-due-0", in: app).tap()
        XCTAssertTrue(element("words.row.ui-vocab-due-0", in: app).exists)

        element("words.scope.myList", in: app).tap()
        XCTAssertTrue(waitForNonExistence(element("words.row.ui-vocab-due-0", in: app), timeout: 3))
        XCTAssertFalse(element("words.row.ui-vocab-due-3", in: app).exists)
        XCTAssertTrue(element("words.row.ui-vocab-due-1", in: app).exists)

        element("words.scope.known", in: app).tap()
        choose("Recently added", from: "words.sortOrder", in: app)
        button("words.known.add", in: app).tap()
        let knownWord = element("words.known.wordField", in: app)
        XCTAssertTrue(knownWord.waitForExistence(timeout: 3))
        knownWord.tap()
        knownWord.typeText("Done.")
        app.buttons["Add"].firstMatch.tap()
        XCTAssertTrue(element("words.known.en.do", in: app).waitForExistence(timeout: 3))
        app.buttons["Remove do from Known"].firstMatch.tap()
        XCTAssertTrue(waitForNonExistence(element("words.known.en.do", in: app), timeout: 3))
    }

    func testVocabularySortDisplayStylesAndKnownPages() {
        let app = launch(scenario: "words-rich")
        element("words.section.library", in: app).tap()

        XCTAssertTrue(element("words.sortOrder", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("words.displayStyle", in: app).exists)
        choose("Oldest added", from: "words.sortOrder", in: app)
        choose("Cards", from: "words.displayStyle", in: app)
        XCTAssertTrue(element("words.cardSummary.ui-vocab-due-0", in: app).waitForExistence(timeout: 3))
        choose("Tags", from: "words.displayStyle", in: app)
        XCTAssertTrue(element("words.tag.ui-vocab-due-0", in: app).waitForExistence(timeout: 3))
        choose("List", from: "words.displayStyle", in: app)

        element("words.scope.known", in: app).tap()
        XCTAssertEqual(element("words.pageRange", in: app).value as? String, "Showing 1–80 of 167")
        button("words.pageLast", in: app).tap()
        XCTAssertEqual(element("words.pageRange", in: app).value as? String, "Showing 161–167 of 167")
        XCTAssertTrue(element("words.known.en.known-164", in: app).waitForExistence(timeout: 3))
        choose("Most common", from: "words.sortOrder", in: app)
        XCTAssertTrue(element("words.known.en.the", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("words.known.en.be", in: app).exists)
    }

    func testCorrectionRestoreAndSyncActions() {
        let app = launch(scenario: "reader")

        XCTAssertTrue(element("transcript.edit", in: app).waitForExistence(timeout: 3))
        element("transcript.edit", in: app).tap()
        let text = element("transcript.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        text.tap()
        text.typeKey("a", modifierFlags: .command)
        text.typeText("Corrected listening changes us.")
        XCTAssertTrue(element("transcript.preview", in: app).isHittable)
        element("transcript.preview", in: app).tap()
        let save = element("transcript.save", in: app)
        XCTAssertTrue(waitForHittable(save, timeout: 3))
        save.tap()
        XCTAssertTrue(element("transcript.edit", in: app).waitForExistence(timeout: 3))
        element("transcript.edit", in: app).tap()
        XCTAssertTrue(element("transcript.restore", in: app).waitForExistence(timeout: 3))
        element("transcript.restore", in: app).tap()

        XCTAssertTrue(element("sync.status", in: app).exists)
        XCTAssertTrue(element("sync.now", in: app).exists)
    }

    func testAnkiExportSelectionIsExplicitAndTemporary() {
        let app = launch(scenario: "words-rich")
        let entryID = "ui-vocab-due-0"

        let librarySection = element("words.section.library", in: app)
        XCTAssertTrue(waitForHittable(librarySection, timeout: 5))
        librarySection.tap()
        XCTAssertTrue(element("words.row.\(entryID)", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("anki.selection.\(entryID)", in: app).exists)

        let myList = element("words.myList.\(entryID)", in: app)
        XCTAssertTrue(scrollToExistence(myList, in: app))
        let originalMyListLabel = myList.label

        enterAnkiExportSelection(in: app)
        let selection = element("anki.selection.\(entryID)", in: app)
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
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
        XCTAssertTrue(secondSelection.waitForExistence(timeout: 3))
        secondSelection.tap()
        XCTAssertEqual(element("anki.selection.count", in: app).value as? String, "1 selected")

        app.buttons["Export"].firstMatch.tap()
        XCTAssertTrue(waitForNonExistence(element("anki.selection.count", in: app), timeout: 3))
        XCTAssertTrue(waitForNonExistence(secondSelection, timeout: 3))
        XCTAssertEqual(myList.label, originalMyListLabel)
    }

    private func enterAnkiExportSelection(in app: XCUIApplication) {
        let actions = app.menuButtons.matching(identifier: "words.actions").firstMatch
        XCTAssertTrue(waitForHittable(actions, timeout: 3))
        actions.tap()
        let export = app.menuItems["Export to Anki"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 3))
        export.tap()
        let select = app.menuItems["Select for Anki export"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        select.tap()
    }

    func testReducedMotionFixtureKeepsReadingControlsUsable() {
        let app = launch(scenario: "reader", reduceMotion: true)
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
        XCTAssertTrue(waitForLabel(element("reader.playback.toggle", in: app), label: "Pause", timeout: 2))
        XCTAssertTrue(element("reader.readAndPauseCoach", in: app).waitForExistence(timeout: 4))
        XCTAssertEqual(
            element("reader.word.ui-sentence-2-word-3", in: app).value as? String,
            "current audio word"
        )
    }

    func testEPUBCoverContentsSearchAndChapterJump() {
        let app = launch(scenario: "epub-reader")

        XCTAssertTrue(element("reader.epubCover", in: app).waitForExistence(timeout: 5))
        button("reader.bookNavigation", in: app).tap()
        XCTAssertTrue(element("reader.bookSearch", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["The Arrival"].exists)
        let search = element("reader.bookSearch", in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("paper lantern")
        let matchingChapters = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "The Lantern Room")
        )
        XCTAssertTrue(matchingChapters.firstMatch.waitForExistence(timeout: 3))
        matchingChapters.element(boundBy: matchingChapters.count - 1).tap()
        // macOS exposes the navigation title as window chrome, so the target chapter's
        // unique reader tokens are the stable accessibility proof of the jump.
        XCTAssertTrue(app.buttons["paper"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["lantern"].exists)
    }

    private func launch(scenario: String, reduceMotion: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // UI runs must not inherit a previously closed or off-screen SwiftUI window.
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--uitesting", "--uitesting-scenario=\(scenario)",
        ]
        if reduceMotion {
            app.launchArguments.append("--uitesting-reduce-motion")
        }
        app.launch()
        return app
    }

    private func choose(_ title: String, from identifier: String, in app: XCUIApplication) {
        element(identifier, in: app).tap()
        let menuItem = app.menuItems[title].firstMatch
        if menuItem.waitForExistence(timeout: 1) {
            menuItem.tap()
        } else {
            XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 2))
            app.buttons[title].firstMatch.tap()
        }
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func button(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: identifier).firstMatch
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
