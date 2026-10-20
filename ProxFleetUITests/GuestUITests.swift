import XCTest

/// Power actions and tasks against the demo cluster.
final class GuestUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo"]
    }

    @MainActor
    func testPauseResumeAndTaskList() {
        app.launch()

        let guest = app.buttons["guest.100"]
        XCTAssertTrue(guest.waitForExistence(timeout: 10))
        guest.tap()

        XCTAssertTrue(app.staticTexts["home-assistant"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 5))
        snapshot("10-guest-running")

        app.buttons["power.more"].tap()
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 10))
        snapshot("11-guest-paused")

        let resume = app.buttons["power.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10))

        // Stop asks for confirmation first. The buttons are disabled until the resume task finished.
        let more = app.buttons["power.more"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: more)
        waitForExpectations(timeout: 10)
        more.tap()
        app.buttons["Stop"].tap()
        let confirm = app.buttons.matching(identifier: "confirm.stop").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        snapshot("12-confirm-stop")
        confirm.tap()
        XCTAssertTrue(app.buttons["power.start"].waitForExistence(timeout: 10))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["tasks"].tap()
        XCTAssertTrue(app.staticTexts["VM 100 – Stop"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["VM 100 – Pause"].exists)
        snapshot("13-tasks")
    }

    @MainActor
    func testStartingStoppedVM() {
        app.launch()
        let guest = app.buttons["guest.102"]
        XCTAssertTrue(guest.waitForExistence(timeout: 10))
        guest.tap()

        let start = app.buttons["power.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
