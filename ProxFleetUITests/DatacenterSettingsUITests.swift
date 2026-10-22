import XCTest

/// Notifications and datacenter options on the demo cluster.
final class DatacenterSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo"]
    }

    @MainActor
    func testNotifications() {
        app.launch()
        open("datacenter.notifications")
        XCTAssertTrue(app.buttons["target.team-chat"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["matcher.backup-failures"].exists)
        snapshot("70-notifications")

        // A test through the built-in sendmail target succeeds.
        app.buttons["target.mail-to-root"].swipeLeft()
        app.buttons["Test"].tap()
        XCTAssertTrue(app.alerts["Test Sent"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()

        app.buttons["target.team-chat"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["target.url"].waitForExistence(timeout: 10))
        snapshot("71-webhook")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openAddMenu(showing: app.buttons["Gotify"].firstMatch)
        type("phone2", into: app.textFields["target.name"])
        type("https://push.example.com", into: app.textFields["target.server"])
        type("secret-token", into: app.secureTextFields["target.token"])
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["target.phone2"].waitForExistence(timeout: 10))

        openAddMenu(showing: app.buttons["matcher.add"])
        type("everything", into: app.textFields["matcher.name"])
        let target = app.switches["matcher.target.phone2"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.switches.firstMatch.tap()
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["matcher.everything"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testOptions() {
        app.launch()
        open("datacenter.options")
        let prefix = app.textFields["options.macPrefix"]
        XCTAssertTrue(prefix.waitForExistence(timeout: 10))
        XCTAssertEqual(prefix.value as? String, "BC:24:11")
        snapshot("72-options")
        type("1000", into: app.textFields["options.nextIDLower"])
        app.buttons["save"].tap()
        // Saving reloads the options, and the form shows the saved value with nothing left to save.
        let saved = NSPredicate(format: "isEnabled == false")
        expectation(for: saved, evaluatedWith: app.buttons["save"])
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.textFields["options.nextIDLower"].value as? String, "1000")
    }

    @MainActor
    func testMetricServers() {
        app.launch()
        open("datacenter.metrics")
        XCTAssertTrue(app.buttons["metric.graphite"].waitForExistence(timeout: 10))
        openAddMenu(showing: app.buttons["metric.add.influxdb"], menu: "metric.add")
        type("influx", into: app.textFields["metric.id"])
        type("influx.home.arpa", into: app.textFields["metric.server"])
        snapshot("68-metric-server")
        app.buttons["save"].tap()
        let created = app.buttons["metric.influx"]
        XCTAssertTrue(created.waitForExistence(timeout: 10))
        XCTAssertTrue(created.label.contains("influx.home.arpa:8089"))

        created.tap()
        let port = app.textFields["metric.port"]
        XCTAssertTrue(port.waitForExistence(timeout: 10))
        XCTAssertEqual(port.value as? String, "8089")
    }

    /// Opens the Add menu, again if a closing sheet swallowed the tap, and picks an item.
    private func openAddMenu(showing item: XCUIElement, menu: String) {
        for _ in 0..<5 where !item.exists {
            app.buttons[menu].tap()
            _ = item.waitForExistence(timeout: 2)
        }
        item.tap()
    }

    private func openAddMenu(showing item: XCUIElement) {
        openAddMenu(showing: item, menu: "notifications.add")
    }

    private func open(_ identifier: String) {
        let entry = app.buttons[identifier]
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        for _ in 0..<12 where !entry.isHittable { app.swipeUp() }
        entry.tap()
    }

    /// Scrolls the form until the field is visible, then types into it.
    private func type(_ text: String, into field: XCUIElement) {
        for _ in 0..<10 where !(field.exists && field.isHittable) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        for _ in 0..<3 {
            field.tap()
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
        }
        field.typeText(text)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
