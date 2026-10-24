import XCTest

/// The demo cluster as Proxmox VE 8.4: what came with PVE 9 is not offered.
final class OlderReleaseUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo", "-demoVersion", "8.4.0"]
    }

    @MainActor
    func testDatacenterWithoutPVE9Features() {
        app.launch()
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        app.buttons["tab.more"].tap()
        let signOut = app.buttons["signOut"]
        for _ in 0..<12 where !signOut.isHittable { app.swipeUp() }
        // Bulk actions exist per node only.
        XCTAssertFalse(app.buttons["bulk.start"].exists)
        snapshot("pve8-more")

        open("datacenter.ha")
        XCTAssertTrue(app.buttons["ha.resource.vm:101"].waitForExistence(timeout: 10))
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertFalse(app.buttons["ha.rules"].exists)
        XCTAssertFalse(app.buttons["ha.more"].exists)
        app.buttons["ha.resource.vm:101"].tap()
        XCTAssertTrue(app.buttons["ha.move"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["Failback"].exists)
        XCTAssertFalse(app.switches["Auto-Rebalance"].exists)
        snapshot("pve8-ha-resource")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()

        open("datacenter.sdn")
        let controllers = app.buttons["sdn.controllers"]
        for _ in 0..<6 where !(controllers.exists && controllers.isHittable) { app.swipeUp() }
        XCTAssertTrue(controllers.exists)
        XCTAssertFalse(app.buttons["sdn.fabrics"].exists)
        XCTAssertFalse(app.buttons["sdn.routemaps"].exists)
        XCTAssertFalse(app.buttons["sdn.prefixlists"].exists)
        snapshot("pve8-sdn")
        app.navigationBars.buttons.firstMatch.tap()

        open("datacenter.metrics")
        let add = app.buttons["metric.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.buttons["metric.add.influxdb"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["metric.add.opentelemetry"].exists)
    }

    /// Proxmox VE 8.0 had no notification targets and matchers yet.
    @MainActor
    func testFirstPVE8Release() {
        app.launchArguments = ["-inMemory", "-demo", "-demoVersion", "8.0.4"]
        app.launch()
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        app.buttons["tab.more"].tap()
        XCTAssertTrue(app.buttons["datacenter.metrics"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["datacenter.notifications"].exists)
    }

    private func open(_ identifier: String) {
        let entry = app.buttons[identifier]
        let more = app.buttons["tab.more"]
        // The floating tab bar covers the rows below its top edge.
        for _ in 0..<12 where !entry.isHittable || entry.frame.maxY > more.frame.minY { app.swipeUp() }
        for _ in 0..<12 where !entry.isHittable { app.swipeDown() }
        entry.tap()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
