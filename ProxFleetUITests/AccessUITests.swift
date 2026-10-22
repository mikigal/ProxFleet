import XCTest

/// Users and permissions on the demo cluster.
final class AccessUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo"]
    }

    @MainActor
    func testUserWithTokenAndPermission() {
        app.launch()
        let entry = app.buttons["datacenter.access"]
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        for _ in 0..<10 where !entry.isHittable { app.swipeUp() }
        entry.tap()
        app.buttons["access.users"].tap()
        XCTAssertTrue(app.buttons["user.anna@pve"].waitForExistence(timeout: 10))
        snapshot("90-users")

        app.buttons["user.add"].tap()
        let name = app.textFields["user.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("bob")
        app.secureTextFields["user.password.new"].tap()
        app.secureTextFields["user.password.new"].typeText("correct horse")
        app.secureTextFields["user.password.confirm"].tap()
        app.secureTextFields["user.password.confirm"].typeText("correct horse")
        app.buttons["save"].tap()

        let bob = app.buttons["user.bob@pve"]
        XCTAssertTrue(bob.waitForExistence(timeout: 10))
        bob.tap()
        app.buttons["token.add"].tap()
        let tokenID = app.textFields["token.id"]
        XCTAssertTrue(tokenID.waitForExistence(timeout: 5))
        tokenID.tap()
        tokenID.typeText("ci")
        app.buttons["token.create"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["token.secret"].waitForExistence(timeout: 10))
        snapshot("91-token-secret")
        app.buttons["token.done"].tap()

        app.buttons["permission.add"].tap()
        let path = app.textFields["permission.path"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.tap()
        path.typeText("vms/103")
        app.buttons["permission.role"].tap()
        app.buttons["PVEVMUser"].firstMatch.tap()
        app.buttons["save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["permission./vms/103.bob@pve.PVEVMUser"].waitForExistence(timeout: 10))
        snapshot("92-user-detail")
    }

    @MainActor
    func testBuiltInRolesAreReadOnly() {
        app.launch()
        let entry = app.buttons["datacenter.access"]
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        for _ in 0..<10 where !entry.isHittable { app.swipeUp() }
        entry.tap()
        app.buttons["access.roles"].tap()
        app.buttons["role.PVEAuditor"].tap()
        XCTAssertTrue(app.staticTexts["Built-in roles cannot be changed. Create a custom role to combine privileges differently."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save"].exists)
    }

    @MainActor
    func testTwoFactorAuthentication() {
        app.launch()
        openAccess()
        app.buttons["access.tfa"].tap()
        XCTAssertTrue(app.buttons["tfa.anna@pve.totp-1"].waitForExistence(timeout: 10))
        snapshot("93-two-factor")

        // The demo account is not a datacenter user, so new second factors go to the first user, root@pam.
        app.buttons["tfa.add"].tap()
        app.buttons["tfa.add.totp"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["tfa.secret"].waitForExistence(timeout: 5))
        snapshot("94-add-authenticator")
        type("123456", into: app.textFields["tfa.code"])
        type("demo", into: app.secureTextFields["Your Password"])
        app.buttons["save"].tap()
        let added = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tfa.root@pam.totp-'")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 10))

        app.buttons["tfa.add"].tap()
        app.buttons["tfa.add.recovery"].tap()
        type("demo", into: app.secureTextFields["Your Password"])
        app.buttons["tfa.recovery.create"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["tfa.recovery.keys"].waitForExistence(timeout: 10))
        snapshot("95-recovery-keys")
        app.buttons["done"].tap()
        XCTAssertTrue(app.buttons["tfa.root@pam.recovery"].waitForExistence(timeout: 10))

        let unlock = app.buttons["tfa.unlock.auditor@pve"]
        for _ in 0..<5 where !unlock.isHittable { app.swipeUp() }
        unlock.tap()
        XCTAssertTrue(unlock.waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testRealms() {
        app.launch()
        openAccess()
        app.buttons["access.realms"].tap()
        XCTAssertTrue(app.buttons["realm.corp"].waitForExistence(timeout: 10))
        snapshot("96-realms")

        app.buttons["realm.corp"].tap()
        let domain = app.textFields["realm.domain"]
        XCTAssertTrue(domain.waitForExistence(timeout: 10))
        XCTAssertEqual(domain.value as? String, "corp.example.com")
        snapshot("97-realm-editor")
        let sync = app.buttons["realm.sync"]
        for _ in 0..<10 where !sync.isHittable { app.swipeUp() }
        sync.tap()
        app.buttons["sync.preview"].tap()
        XCTAssertTrue(app.buttons["sync.log"].waitForExistence(timeout: 10))
        snapshot("98-realm-sync")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["realm.add"].tap()
        app.buttons["realm.add.ldap"].tap()
        type("lab", into: app.textFields["realm.id"])
        type("dc=lab", into: app.textFields["realm.baseDN"])
        type("uid", into: app.textFields["realm.userAttribute"])
        type("ldap.lab", into: app.textFields["realm.server"])
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["realm.lab"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testRealmSyncJobs() {
        app.launch()
        openAccess()
        app.buttons["access.realms"].tap()
        let jobs = app.buttons["realm.syncjobs"]
        XCTAssertTrue(jobs.waitForExistence(timeout: 10))
        jobs.tap()
        XCTAssertTrue(app.buttons["syncjob.realmsync-corp"].waitForExistence(timeout: 10))

        app.buttons["syncjob.add"].tap()
        type("nightly", into: app.textFields["syncjob.id"])
        let schedule = app.textFields["syncjob.schedule"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5))
        schedule.tap()
        schedule.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        schedule.typeText("02:00")
        snapshot("99-realm-sync-job")
        app.buttons["save"].tap()
        let created = app.buttons["syncjob.nightly"]
        XCTAssertTrue(created.waitForExistence(timeout: 10))
        XCTAssertTrue(created.label.contains("02:00"))

        created.swipeRight()
        app.buttons["Run Now"].firstMatch.tap()
        XCTAssertTrue(app.alerts["Sync Started"].waitForExistence(timeout: 10))
        app.alerts["Sync Started"].buttons["OK"].tap()
    }

    private func openAccess() {
        let entry = app.buttons["datacenter.access"]
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        for _ in 0..<10 where !entry.isHittable { app.swipeUp() }
        entry.tap()
    }

    /// Scrolls the form until the field is visible, then types into it.
    private func type(_ text: String, into field: XCUIElement) {
        for _ in 0..<10 where !(field.exists && field.isHittable) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        for _ in 0..<3 {
            field.tap()
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
        }
        field.typeText(text)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
