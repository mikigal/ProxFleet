import XCTest

/// The demo backup server: dashboard, datastores and tasks.
final class BackupServerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demoBackupServer"]
    }

    @MainActor
    func testDashboard() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        snapshot("pbs-dashboard-top")

        let main = app.descendants(matching: .any)["datastore.main"]
        for _ in 0..<8 where !main.exists { app.swipeUp() }
        XCTAssertTrue(main.exists)
        XCTAssertTrue(main.label.contains("of"), main.label)
        XCTAssertTrue(app.descendants(matching: .any)["datastore.offsite"].label.contains("Not Mounted"))
        snapshot("pbs-dashboard-datastores")

        let backups = app.descendants(matching: .any)["summary.backup"]
        for _ in 0..<6 where !backups.exists { app.swipeUp() }
        XCTAssertTrue(backups.exists)
        // A month of nightly backups of seven guests, one of them failed.
        XCTAssertTrue(backups.label.contains("Backups"), backups.label)
        snapshot("pbs-dashboard-tasks")
        let longest = app.staticTexts["Longest Tasks"]
        for _ in 0..<10 where !longest.exists { app.swipeUp() }
        XCTAssertTrue(longest.exists)
        snapshot("pbs-dashboard-longest")
        for _ in 0..<6 { app.swipeUp() }
        snapshot("pbs-dashboard-bottom")
    }

    @MainActor
    func testDatastoresAndTasks() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        app.buttons["tab.datastores"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["datastore.main"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["datastore.offsite"].exists)
        snapshot("pbs-datastores")

        app.buttons["tasks"].tap()
        let gc = app.staticTexts["main – Garbage Collection"].firstMatch
        XCTAssertTrue(gc.waitForExistence(timeout: 10))
        snapshot("pbs-tasks")
        gc.tap()
        // The output is one text of all lines.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'TASK OK'")).firstMatch.waitForExistence(timeout: 10))
        snapshot("pbs-task-log")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["tab.more"].tap()
        XCTAssertTrue(app.buttons["signOut"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '4.2.1'")).firstMatch.exists)
        snapshot("pbs-more")
    }

    /// The demo address adds both demo servers, so App Review finds the backup server too.
    @MainActor
    func testDemoAddressAddsBothServers() {
        app.launchArguments = ["-inMemory"]
        app.launch()
        app.buttons["welcome.addServer"].tap()
        let address = app.textFields["address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '8006'")).firstMatch.exists)
        app.buttons["Backup Server"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '8007'")).firstMatch.exists)
        snapshot("pbs-add-server")
        app.buttons["Proxmox VE"].tap()
        address.tap()
        address.typeText("demo.proxfleet\n")

        XCTAssertTrue(app.staticTexts["Cluster homelab"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        let backupServer = app.descendants(matching: .any)["server.Demo Backup Server"]
        XCTAssertTrue(backupServer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["server.Demo Cluster"].exists)
        snapshot("pbs-server-list")
        backupServer.tap()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
