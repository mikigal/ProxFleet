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
        let confirm = app.alerts.buttons["Stop"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        snapshot("12-confirm-stop")
        confirm.tap()
        XCTAssertTrue(app.buttons["power.start"].waitForExistence(timeout: 10))

        app.buttons["tab.hardware"].tap()
        XCTAssertTrue(app.staticTexts["Processor"].waitForExistence(timeout: 5))
        snapshot("14-hardware")
        app.buttons["tab.more"].tap()
        app.buttons["Options"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Start at Boot"].waitForExistence(timeout: 5))
        snapshot("15-options")

        // Back to the More list, then back to the server.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["tab.more"].waitForExistence(timeout: 5))
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

    @MainActor
    func testEditMemoryAndOptions() {
        app.launch()
        let guest = app.buttons["guest.102"]
        XCTAssertTrue(guest.waitForExistence(timeout: 10))
        guest.tap()

        app.buttons["tab.hardware"].tap()
        let memoryRow = app.buttons["hardware.memory"]
        XCTAssertTrue(memoryRow.waitForExistence(timeout: 10))
        let before = memoryRow.label
        memoryRow.tap()

        let save = app.buttons["save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        app.steppers.firstMatch.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(save.isEnabled)
        snapshot("20-memory-editor")
        save.tap()

        XCTAssertTrue(memoryRow.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: memoryRow)
        waitForExpectations(timeout: 10)
        snapshot("21-memory-saved")

        app.buttons["tab.more"].tap()
        app.buttons["more.options"].tap()
        let onboot = app.switches["option.onboot"]
        XCTAssertTrue(onboot.waitForExistence(timeout: 5))
        let wasOn = (onboot.value as? String) == "1"
        onboot.switches.firstMatch.tap()
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["more.options"].waitForExistence(timeout: 10))
        app.buttons["more.options"].tap()
        XCTAssertTrue(onboot.waitForExistence(timeout: 5))
        XCTAssertEqual((onboot.value as? String) == "1", !wasOn)
        snapshot("22-options-saved")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
