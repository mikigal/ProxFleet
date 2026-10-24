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

    @MainActor
    func testDatastoreSummaryOptionsAndPermissions() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        app.buttons["tab.datastores"].tap()
        // In the list the row is a navigation link; its content carries the same identifier.
        let main = app.buttons["datastore.main"]
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        main.tap()

        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'groups'")).firstMatch.waitForExistence(timeout: 10))
        snapshot("pbs-datastore-summary")
        app.buttons["datastore.actions"].tap()
        app.buttons["datastore.gc"].tap()
        // The task starts without an error; it shows in the server's task list.
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 3))

        // Comment and verify-new, saved through the general and verification editors.
        app.buttons["tab.options"].tap()
        let general = app.buttons["options.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        general.tap()
        let comment = app.textFields["datastore.comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
        comment.tap()
        comment.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        comment.typeText("Nightly backups")
        app.buttons["save"].tap()
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        XCTAssertTrue(general.label.contains("Nightly backups"), general.label)

        app.buttons["options.maintenance"].tap()
        XCTAssertTrue(app.buttons["Read-Only"].waitForExistence(timeout: 5))
        app.buttons["Read-Only"].tap()
        app.textFields["datastore.maintenanceMessage"].tap()
        app.textFields["datastore.maintenanceMessage"].typeText("Disk swap")
        snapshot("pbs-datastore-maintenance")
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["options.maintenance"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["options.maintenance"].label.contains("Read-Only"))

        app.buttons["tab.permissions"].tap()
        XCTAssertTrue(app.staticTexts["anna@pbs"].waitForExistence(timeout: 10))
        app.buttons["permissions.add"].tap()
        XCTAssertTrue(app.buttons["permission.user"].waitForExistence(timeout: 5))
        app.buttons["permission.user"].tap()
        app.buttons["monitoring@pbs!zabbix"].tap()
        app.buttons["permission.save"].tap()
        XCTAssertTrue(app.staticTexts["monitoring@pbs!zabbix"].waitForExistence(timeout: 10))
        snapshot("pbs-datastore-permissions")
    }

    @MainActor
    func testAddAndRemoveDatastore() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        app.buttons["tab.datastores"].tap()
        let add = app.buttons["datastore.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let name = app.textFields["datastore.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("archive")
        // A relative path is refused before anything is sent.
        let path = app.textFields["datastore.path"]
        path.tap()
        path.typeText("archive")
        app.buttons["datastore.create"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'absolute path'")).firstMatch.waitForExistence(timeout: 5))
        snapshot("pbs-add-datastore-error")
        path.tap()
        path.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        path.typeText("/mnt/datastore/archive")
        app.buttons["datastore.create"].tap()

        let archive = app.buttons["datastore.archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 15))
        archive.tap()
        app.buttons["tab.options"].tap()
        let remove = app.buttons["datastore.remove"]
        for _ in 0..<6 where !remove.isHittable { app.swipeUp() }
        remove.tap()
        let confirm = app.textFields["remove.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["remove.submit"].isEnabled)
        confirm.tap()
        confirm.typeText("archive")
        app.buttons["remove.submit"].tap()
        XCTAssertTrue(app.buttons["datastore.main"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["datastore.archive"].exists)
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
