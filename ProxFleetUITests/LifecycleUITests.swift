import XCTest

/// Snapshots, clones, templates and deletion on the demo cluster.
final class LifecycleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo"]
    }

    @MainActor
    func testTakeAndRollBackSnapshot() {
        app.launch()
        openGuest(200)
        app.buttons["tab.more"].tap()
        app.buttons["more.snapshots"].tap()
        XCTAssertTrue(app.staticTexts["Now"].waitForExistence(timeout: 5))

        app.buttons["snapshot.take"].tap()
        let name = app.textFields["snapshot.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        // An invalid name is caught before sending.
        name.tap()
        name.typeText("1st")
        app.buttons["snapshot.save"].tap()
        XCTAssertTrue(app.staticTexts["Start with a letter, then use letters, digits, - and _ only."].waitForExistence(timeout: 5))
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "before-test")
        app.buttons["snapshot.save"].tap()

        let row = app.buttons["snapshot.before-test"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        snapshot("40-snapshots")
        row.tap()
        app.buttons["snapshot.rollback"].tap()
        let confirm = app.alerts.buttons["snapshot.rollback.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        // Back in the list once the rollback finished.
        XCTAssertTrue(app.buttons["snapshot.take"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Now"].exists)
    }

    @MainActor
    func testCloneTemplate() {
        app.launch()
        openGuest(9000)
        let clone = app.buttons["template.clone"]
        XCTAssertTrue(clone.waitForExistence(timeout: 10))
        clone.tap()
        let name = app.textFields["clone.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        // Guest IDs are shown without a thousands separator.
        XCTAssertTrue(app.staticTexts["Clone VM 9000"].exists)
        expectation(for: NSPredicate(format: "value == '106'"), evaluatedWith: app.textFields["vmid"])
        waitForExpectations(timeout: 5)
        name.tap()
        name.typeText("web-03")
        snapshot("41-clone")
        app.buttons["create"].tap()
        // The clone opens once its task finished.
        XCTAssertTrue(app.staticTexts["web-03"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["power.start"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testConvertToTemplateAndDelete() {
        app.launch()
        // Container 203 is stopped.
        openGuest(203)
        app.buttons["tab.more"].tap()
        app.buttons["more.template"].tap()
        let convert = app.alerts.buttons["template.confirm"].firstMatch
        XCTAssertTrue(convert.waitForExistence(timeout: 5))
        convert.tap()
        // A template has no Convert row and offers cloning instead of power actions.
        let deleteRow = app.buttons["more.delete"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["more.template"])
        waitForExpectations(timeout: 10)
        app.buttons["tab.summary"].tap()
        XCTAssertTrue(app.buttons["template.clone"].waitForExistence(timeout: 5))

        app.buttons["tab.more"].tap()
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 5))
        deleteRow.tap()
        let delete = app.buttons["delete.confirm"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled)
        app.textFields["delete.confirmation"].tap()
        app.textFields["delete.confirmation"].typeText("203")
        snapshot("42-delete")
        XCTAssertTrue(delete.isEnabled)
        delete.tap()

        // Back on the server, without the container.
        XCTAssertTrue(app.buttons["guest.100"].waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["guest.203"])
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testRunningGuestCannotBeDeleted() {
        app.launch()
        openGuest(100)
        app.buttons["tab.more"].tap()
        app.buttons["more.delete"].tap()
        XCTAssertTrue(app.staticTexts["Stop the guest before deleting it."].waitForExistence(timeout: 5))
        app.textFields["delete.confirmation"].tap()
        app.textFields["delete.confirmation"].typeText("100")
        XCTAssertFalse(app.buttons["delete.confirm"].isEnabled)
    }

    @MainActor
    func testBackUpNowProtectAndDelete() {
        app.launch()
        openGuest(200)
        app.buttons["tab.more"].tap()
        app.buttons["more.backups"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'backup.vzdump'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 1)

        app.buttons["backup.now"].tap()
        XCTAssertTrue(app.buttons["backup.mode"].waitForExistence(timeout: 5))
        snapshot("43-backup-now")
        app.buttons["create"].tap()
        // The sheet closes when the backup is done, and the list shows it first.
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)
        waitForExpectations(timeout: 15)
        snapshot("44-backups")

        rows.firstMatch.tap()
        let protected = app.switches["backup.protected"]
        XCTAssertTrue(protected.waitForExistence(timeout: 5))
        protected.switches.firstMatch.tap()
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: app.buttons["backup.delete"])
        waitForExpectations(timeout: 10)
        protected.switches.firstMatch.tap()
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: app.buttons["backup.delete"])
        waitForExpectations(timeout: 10)
        app.buttons["backup.delete"].tap()
        let confirm = app.alerts.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["backup.now"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: rows)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testRestoreBackupAsNewGuest() {
        app.launch()
        openGuest(100)
        app.buttons["tab.more"].tap()
        app.buttons["more.backups"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'backup.vzdump'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["backup.restore"].tap()

        // VM 100 is running, so it cannot be replaced.
        let restore = app.buttons["create"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.tap()
        XCTAssertTrue(app.staticTexts["Stop the guest before restoring over it."].waitForExistence(timeout: 5))

        app.buttons["restore.target"].tap()
        let newVM = app.buttons["New VM"].firstMatch
        XCTAssertTrue(newVM.waitForExistence(timeout: 5))
        newVM.tap()
        expectation(for: NSPredicate(format: "value == '106'"), evaluatedWith: app.textFields["vmid"])
        waitForExpectations(timeout: 5)
        snapshot("45-restore")
        restore.tap()

        // The restored VM opens, stopped, under its new ID.
        XCTAssertTrue(app.buttons["power.start"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["VM 106 · pve1"].exists)
    }

    /// Opens a guest from the server's list, scrolling to it if needed.
    private func openGuest(_ vmid: Int) {
        XCTAssertTrue(app.buttons["guest.100"].waitForExistence(timeout: 10))
        let row = app.buttons["guest.\(vmid)"]
        for _ in 0..<8 where !(row.exists && row.isHittable) {
            app.swipeUp()
        }
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
