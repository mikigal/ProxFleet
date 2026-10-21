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

    @MainActor
    func testAddNFSStorageAndDisableOne() {
        app.launch()
        let entry = app.buttons["datacenter.storage"]
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        for _ in 0..<10 where !entry.isHittable { app.swipeUp() }
        entry.tap()
        XCTAssertTrue(app.buttons["storageconfig.nas"].waitForExistence(timeout: 10))
        snapshot("73-datacenter-storage")

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
        XCTAssertTrue(app.buttons["storageconfig.media"].waitForExistence(timeout: 10))

        app.buttons["storageconfig.nas"].tap()
        let enabled = app.switches["Enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        app.buttons["save"].tap()
        let nas = app.buttons["storageconfig.nas"]
        XCTAssertTrue(nas.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label CONTAINS 'Disabled'"), evaluatedWith: nas)
        waitForExpectations(timeout: 10)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
