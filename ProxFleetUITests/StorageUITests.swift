import XCTest

/// Storage content on the demo cluster.
final class StorageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo"]
    }

    @MainActor
    func testBrowseDownloadAndDeleteISO() {
        app.launch()
        let local = app.buttons["storage.pve1.local"]
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        for _ in 0..<8 where !local.isHittable { app.swipeUp() }
        local.tap()

        let debian = app.descendants(matching: .any)["volume.debian-13.1.0-amd64-netinst.iso"]
        XCTAssertTrue(debian.waitForExistence(timeout: 10))
        snapshot("70-storage-iso")

        app.buttons["storage.add"].tap()
        app.buttons["Download from URL"].firstMatch.tap()
        let url = app.textFields["download.url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText("https://releases.example.org/fedora-server-43.iso")
        app.buttons["download.query"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Size'")).firstMatch.waitForExistence(timeout: 5))
        snapshot("71-storage-download")
        app.buttons["download.start"].tap()

        let fedora = app.descendants(matching: .any)["volume.fedora-server-43.iso"]
        XCTAssertTrue(fedora.waitForExistence(timeout: 15))
        fedora.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.buttons["volume.delete.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: fedora)
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testGuestDisksAndBackupsOnNodeStorage() {
        app.launch()
        let row = app.buttons["node.pve2"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["tab.more"].tap()
        app.buttons["more.storage"].tap()
        app.buttons["storage.pve2.local-lvm"].tap()
        XCTAssertTrue(app.staticTexts["VM Disks"].waitForExistence(timeout: 10))
        let disk = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'vm-103-disk-0'")).firstMatch
        XCTAssertTrue(disk.waitForExistence(timeout: 5))
        snapshot("72-storage-disks")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
