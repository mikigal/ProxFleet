import XCTest

/// The firewall of the demo cluster: datacenter rules and security groups, and a guest's firewall and log.
final class FirewallUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo"]
    }

    @MainActor
    func testDatacenterRulesAndGroups() {
        app.launch()
        let entry = app.buttons["datacenter.firewall"]
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        app.buttons["tab.more"].tap()
        for _ in 0..<10 where !entry.isHittable { app.swipeUp() }
        entry.tap()

        XCTAssertTrue(app.switches["firewall.enabled"].waitForExistence(timeout: 10))
        snapshot("90-firewall")
        app.buttons["firewall.rules"].tap()
        XCTAssertTrue(app.buttons["rule.2"].waitForExistence(timeout: 10))
        snapshot("91-firewall-rules")

        app.buttons["rule.add"].tap()
        let macro = app.buttons["rule.macro"]
        XCTAssertTrue(macro.waitForExistence(timeout: 5))
        macro.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("secure shell")
        app.buttons["macro.SSH"].tap()
        // A macro brings its own protocol and ports.
        XCTAssertTrue(app.staticTexts["The macro sets the protocol and ports."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["rule.dport"].exists)
        app.buttons["rule.source.refs"].tap()
        app.buttons["admin-laptop"].tap()
        let comment = app.textFields["rule.comment"]
        comment.tap()
        comment.typeText("Admin SSH")
        snapshot("92-firewall-rule-editor")
        app.buttons["save"].tap()

        // New rules go to the top.
        let first = app.buttons["rule.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.label.contains("Admin SSH"))
        first.swipeLeft()
        app.buttons["Disable"].firstMatch.tap()
        let disabled = NSPredicate(format: "label CONTAINS 'Off'")
        expectation(for: disabled, evaluatedWith: app.buttons["rule.0"])
        waitForExpectations(timeout: 10)

        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["firewall.groups"].tap()
        let group = app.buttons["group.webserver"]
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        group.tap()
        XCTAssertTrue(app.buttons["rule.1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["HTTPS"].exists)
    }

    @MainActor
    func testGuestFirewallAndLog() {
        app.launch()
        let guest = app.buttons["guest.100"]
        XCTAssertTrue(guest.waitForExistence(timeout: 10))
        guest.tap()
        XCTAssertTrue(app.buttons["tab.more"].waitForExistence(timeout: 10))
        app.buttons["tab.more"].tap()
        app.buttons["more.firewall"].tap()

        let toggle = app.switches["firewall.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(app.buttons["firewall.groups"].exists)
        app.buttons["firewall.aliases"].tap()
        XCTAssertTrue(app.buttons["alias.tablet"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["firewall.rules"].tap()
        XCTAssertTrue(app.buttons["rule.2"].waitForExistence(timeout: 10))
        app.buttons["rule.add"].tap()
        // Guests have no forward rules.
        XCTAssertTrue(app.buttons["Out"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Forward"].exists)
        app.buttons["Group"].tap()
        XCTAssertTrue(app.buttons["rule.group"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["rule.macro"].exists)
        app.buttons["Cancel"].tap()

        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["firewall.log"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'policy DROP'")).firstMatch.waitForExistence(timeout: 10))
        snapshot("93-firewall-log")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
