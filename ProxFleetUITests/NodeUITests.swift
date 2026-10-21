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

    @MainActor
    func testNetworkChangesAreAppliedLater() {
        app.launch()
        openNode("pve1")
        app.buttons["tab.more"].tap()
        app.buttons["more.network"].tap()
        XCTAssertTrue(app.buttons["interface.vmbr0"].waitForExistence(timeout: 10))
        snapshot("54-node-network")

        app.buttons["network.add"].tap()
        app.buttons["Linux Bridge"].firstMatch.tap()
        let comment = app.textFields["interface.comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
        comment.tap()
        comment.typeText("Isolated")
        let cidr = app.textFields["interface.cidr"]
        cidr.tap()
        cidr.typeText("192.168.50.1/24")
        snapshot("55-node-new-bridge")
        app.buttons["save"].tap()

        let apply = app.buttons["network.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["interface.vmbr2"].label.contains("Inactive"))
        app.buttons["network.changes"].tap()
        XCTAssertTrue(app.staticTexts["+auto vmbr2"].waitForExistence(timeout: 5))
        snapshot("56-node-network-changes")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        apply.tap()
        let confirm = app.alerts.buttons["network.apply.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let vmbr2 = app.buttons["interface.vmbr2"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: apply)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(vmbr2.label.contains("Inactive"))
    }

    @MainActor
    func testDNSAndTimeZone() {
        app.launch()
        openNode("pve2")
        app.buttons["tab.more"].tap()
        app.buttons["more.dns"].tap()
        let server = app.textFields["dns.server3"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        server.tap()
        server.typeText("9.9.9.9")
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["more.time"].waitForExistence(timeout: 10))

        app.buttons["more.time"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Warsaw")
        let warsaw = app.buttons["zone.Europe/Warsaw"]
        XCTAssertTrue(warsaw.waitForExistence(timeout: 5))
        warsaw.tap()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: warsaw)
        waitForExpectations(timeout: 10)
        snapshot("57-node-time-zone")
        app.buttons["close"].firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.buttons["more.time"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label CONTAINS 'Europe/Warsaw'"), evaluatedWith: row)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testDisksAndZFSPool() {
        app.launch()
        openNode("pve1")
        app.buttons["tab.more"].tap()
        app.buttons["more.disks"].tap()
        XCTAssertTrue(app.buttons["disk.sdd"].waitForExistence(timeout: 10))
        snapshot("58-node-disks")

        app.buttons["disk.sdd"].tap()
        let attributes = app.buttons["SMART Attributes"]
        XCTAssertTrue(attributes.waitForExistence(timeout: 10))
        attributes.tap()
        XCTAssertTrue(app.staticTexts["Power On Hours"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["disks.add"].tap()
        app.buttons["Create ZFS Pool"].firstMatch.tap()
        let name = app.textFields["storage.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("fast")
        app.buttons["candidate.sdc"].tap()
        app.buttons["candidate.sdd"].tap()
        snapshot("59-node-create-zfs")
        app.buttons["storage.create"].tap()

        let pool = app.buttons["zfs.fast"]
        XCTAssertTrue(pool.waitForExistence(timeout: 15))
        app.buttons["zfs.tank"].tap()
        XCTAssertTrue(app.staticTexts["mirror-0"].waitForExistence(timeout: 10))
        snapshot("60-node-zfs-pool")
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
