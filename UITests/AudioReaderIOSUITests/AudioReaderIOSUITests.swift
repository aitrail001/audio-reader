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
        XCTAssertTrue(element("library.importPaired", in: app).isHittable)
        XCTAssertTrue(element("library.search", in: app).exists)
    }

    func testSidebarReadingLookupAndDueReview() {
        let app = launch(scenario: "library")

        navigate(to: "sidebar.nowReading", in: app)
        XCTAssertTrue(element("reader.sentence.ui-sentence-1", in: app).waitForExistence(timeout: 3))
        element("reader.sentence.ui-sentence-1", in: app).tap()
        XCTAssertTrue(element("reader.word.ui-word-1", in: app).isHittable)
        element("reader.word.ui-word-1", in: app).tap()

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
        XCTAssertTrue(element("words.category.all", in: app).exists)
        XCTAssertEqual(element("words.pageRange", in: app).label, "Showing 1–80 of 85")
        element("words.pageLast", in: app).tap()
        XCTAssertEqual(element("words.pageRange", in: app).label, "Showing 81–85 of 85")
        XCTAssertTrue(element("words.card.ui-vocab-new-76", in: app).waitForExistence(timeout: 3))

        app.terminate()
        let sidebarApp = launch(scenario: "library")
        revealSidebar(in: sidebarApp)
        for destination in ["sidebar.library", "sidebar.nowReading", "sidebar.words", "sidebar.settings"] {
            XCTAssertTrue(element(destination, in: sidebarApp).waitForExistence(timeout: 3))
        }
    }

    func testCorrectionRestoreSyncAndExportActions() {
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
        libraryApp.terminate()
        let wordsApp = launch(scenario: "words")
        let identifiedExport = element("anki.export", in: wordsApp)
        let export: XCUIElement
        if identifiedExport.waitForExistence(timeout: 3) {
            export = identifiedExport
        } else {
            let more = wordsApp.buttons["More"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 3))
            more.tap()
            export = wordsApp.buttons["Export to Anki"].firstMatch
        }
        XCTAssertTrue(export.waitForExistence(timeout: 3))
        XCTAssertTrue(export.isEnabled)
        export.tap()
        XCTAssertTrue(wordsApp.buttons["Current filtered view"].waitForExistence(timeout: 3))
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
