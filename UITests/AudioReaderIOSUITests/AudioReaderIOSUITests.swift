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
}
