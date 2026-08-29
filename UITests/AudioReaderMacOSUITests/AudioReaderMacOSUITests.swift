import XCTest

@MainActor
final class AudioReaderMacOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFirstRunOffersPairedImport() {
        let app = launch(scenario: "empty-library")

        XCTAssertTrue(element("sidebar.library", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("library.importPaired", in: app).isHittable)
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
        XCTAssertTrue(element("transcript.save", in: app).isHittable)
        element("transcript.save", in: app).tap()
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
