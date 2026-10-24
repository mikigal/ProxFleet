import XCTest

/// Backup jobs on the demo cluster.
final class BackupJobUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo"]
    }

    @MainActor
    func testRunNowAndAddJob() {
        app.launch()
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        app.buttons["tab.backup"].tap()

        let nightly = app.buttons["backupjob.Nightly, everything"]
        XCTAssertTrue(nightly.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Not Backed Up"].exists)
        snapshot("80-backup-jobs")

        nightly.swipeLeft()
        app.buttons["Run Now"].firstMatch.tap()
        let confirm = app.alerts.buttons["backupjob.run.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let started = app.alerts["Backup Started"]
        XCTAssertTrue(started.waitForExistence(timeout: 10))
        XCTAssertTrue(started.staticTexts.matching(NSPredicate(format: "label CONTAINS '2 backup tasks'")).firstMatch.exists)
        started.buttons["OK"].tap()

        app.buttons["backupjob.add"].tap()
        let comment = app.textFields["backupjob.comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
        comment.tap()
        comment.typeText("Weekly all")
        app.buttons["backupjob.presets"].tap()
        app.buttons["Every Saturday at 02:00"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Saturday'")).firstMatch.waitForExistence(timeout: 5))
        // The default selection is every guest, which includes the template the nightly job leaves out.
        XCTAssertTrue(app.staticTexts["Every guest, including ones added later."].exists)
        snapshot("81-backup-job-editor")
        app.buttons["save"].tap()

        XCTAssertTrue(app.buttons["backupjob.Weekly all"].waitForExistence(timeout: 10))
        // Every guest is covered now.
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["Not Backed Up"])
        waitForExpectations(timeout: 10)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
