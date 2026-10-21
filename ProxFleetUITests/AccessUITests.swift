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

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
