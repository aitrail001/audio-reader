import XCTest

@MainActor
final class AudioReaderMacOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFirstRunOffersPairedImport() {
        let app = launch(scenario: "empty-library")

        XCTAssertTrue(element("sidebar.library", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Build your listening library"].exists)
        XCTAssertTrue(waitForHittable(app.buttons["Import audiobook + EPUB"].firstMatch, timeout: 5))
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
        XCTAssertTrue(element("words.section.today", in: app).isHittable)
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
    }

    func testCorrectionRestoreSyncAndExportActions() {
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

        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(element("anki.export", in: app).waitForExistence(timeout: 3))
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

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
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
