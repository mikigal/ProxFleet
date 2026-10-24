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
        app.buttons["tab.storage"].tap()
        for _ in 0..<8 where !local.isHittable { app.swipeUp() }
        local.tap()
        app.buttons["tab.content"].tap()

        let debian = app.descendants(matching: .any)["volume.debian-13.1.0-amd64-netinst.iso"]
        XCTAssertTrue(debian.waitForExistence(timeout: 10))
        snapshot("70-storage-iso")

        app.buttons["storage.add"].tap()
        XCTAssertTrue(app.buttons["Download from URL"].firstMatch.waitForExistence(timeout: 5))
        // Uploads from the device are hidden for now.
        XCTAssertFalse(app.buttons["Upload from Files"].exists)
        app.buttons["Download from URL"].firstMatch.tap()
        let url = app.textFields["download.url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText("https://releases.example.org/fedora-server-43.iso")
        app.buttons["download.query"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Size'")).firstMatch.waitForExistence(timeout: 5))
        snapshot("71-storage-download")
        app.buttons["download.start"].tap()

        // Scroll down once the download has finished.
        let fedora = app.descendants(matching: .any)["volume.fedora-server-43.iso"]
        for _ in 0..<15 where !fedora.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(fedora.waitForExistence(timeout: 5))
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
        app.buttons["tab.content"].tap()
        let disk = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'vm-103-disk-0'")).firstMatch
        XCTAssertTrue(disk.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["VM Disks"].exists)
        snapshot("72-storage-disks")
    }

    @MainActor
    func testAddNFSStorageThenDisableAndRemoveIt() {
        app.launch()
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        app.buttons["tab.storage"].tap()
        XCTAssertTrue(app.buttons["storage.pve1.nas"].waitForExistence(timeout: 10))

        app.buttons["storageconfig.add"].tap()
        app.buttons["NFS"].firstMatch.tap()
        let id = app.textFields["storageconfig.id"]
        XCTAssertTrue(id.waitForExistence(timeout: 5))
        id.tap()
        id.typeText("media")
        let server = app.textFields["storage.server"]
        server.tap()
        server.typeText("10.0.10.5")
        app.buttons["storage.scan"].tap()
        let export = app.buttons["scan.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        export.tap()
        app.buttons["/mnt/tank/media (10.0.10.0/24)"].firstMatch.tap()
        snapshot("74-datacenter-storage-nfs")
        app.buttons["save"].tap()

        // A shared storage shows once, through the first node.
        let media = app.buttons["storage.pve1.media"]
        XCTAssertTrue(media.waitForExistence(timeout: 10))
        reveal(media).tap()
        app.buttons["tab.settings"].tap()
        let enabled = app.switches["Enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        snapshot("73-storage-settings")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let save = app.buttons["save"]
        save.tap()
        // The form starts over from the saved settings, so there is nothing left to save.
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: save)
        waitForExpectations(timeout: 10)
        app.navigationBars.buttons.firstMatch.tap()

        // Disabled storages are not on any node; they are listed from the definitions.
        // They come last, below the storages in use.
        let disabled = reveal(app.buttons["storageconfig.media"])
        XCTAssertTrue(disabled.exists)
        XCTAssertFalse(media.exists)
        disabled.tap()
        reveal(app.buttons["storageconfig.remove"]).tap()
        app.buttons["storageconfig.remove.confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["storageconfig.add"].waitForExistence(timeout: 10))
        XCTAssertFalse(disabled.exists)
    }

    /// Scrolls the list until the element can be tapped.
    private func reveal(_ element: XCUIElement) -> XCUIElement {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
        return element
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
