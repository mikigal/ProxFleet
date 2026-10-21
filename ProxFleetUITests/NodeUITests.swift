import XCTest

/// The node screen on the demo cluster.
final class NodeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo"]
    }

    @MainActor
    func testSummaryUpdatesAndShell() {
        app.launch()
        openNode("pve1")
        XCTAssertTrue(app.staticTexts["Load Average"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Load"].exists)
        snapshot("50-node-summary")

        app.buttons["tab.updates"].tap()
        XCTAssertTrue(app.staticTexts["2 Updates"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["pve-manager"].exists)
        snapshot("51-node-updates")
        app.buttons["updates.refresh"].tap()
        XCTAssertTrue(app.staticTexts["2 Updates"].waitForExistence(timeout: 10))

        app.buttons["tab.shell"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Shell Unavailable"].exists)
    }

    @MainActor
    func testServicesLogAndTasks() {
        app.launch()
        openNode("pve1")
        app.buttons["tab.more"].tap()
        app.buttons["more.services"].tap()
        let chrony = app.buttons["service.chrony"]
        XCTAssertTrue(chrony.waitForExistence(timeout: 10))
        XCTAssertTrue(chrony.label.contains("Running"))
        snapshot("52-node-services")
        chrony.tap()
        let stop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Dead'"), evaluatedWith: chrony)
        waitForExpectations(timeout: 10)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["more.log"].tap()
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'pvedaemon'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        snapshot("53-node-log")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["more.tasks"].tap()
        XCTAssertTrue(app.staticTexts["chrony – Stop Service"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testRebootTakesTheNodeOffline() {
        app.launch()
        openNode("pve2")
        app.buttons["tab.more"].tap()
        app.buttons["node.reboot"].tap()
        let confirm = app.alerts.buttons["node.power.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let done = app.alerts["Rebooting"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.buttons["OK"].tap()

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.buttons["node.pve2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label CONTAINS 'Offline'"), evaluatedWith: row)
        waitForExpectations(timeout: 15)
    }

    private func openNode(_ name: String) {
        let row = app.buttons["node.\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["tab.more"].waitForExistence(timeout: 10))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
