import XCTest

/// Creating VMs and containers on the demo cluster.
final class CreationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo"]
    }

    @MainActor
    func testCreateVM() {
        app.launch()
        open("create.vm")
        XCTAssertTrue(app.staticTexts["New Virtual Machine"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["vmid"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == '106'"), evaluatedWith: app.textFields["vmid"])
        waitForExpectations(timeout: 5)

        app.textFields["name"].tap()
        app.textFields["name"].typeText("web-01")
        snapshot("30-create-vm")
        toggle("startAfterCreation")
        app.buttons["create"].tap()

        // The new VM opens once its task finished, already running.
        XCTAssertTrue(app.staticTexts["web-01"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10))
        snapshot("31-created-vm")
    }

    @MainActor
    func testInvalidNameIsShownBeforeSending() {
        app.launch()
        open("create.vm")
        let name = app.textFields["name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("bad name")
        app.buttons["create"].tap()
        XCTAssertTrue(app.staticTexts["Use letters, digits, hyphens and dots only."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["New Virtual Machine"].exists)
    }

    @MainActor
    func testCreateContainerWithDownloadedTemplate() {
        app.launch()
        open("create.ct")
        XCTAssertTrue(app.staticTexts["New Container"].waitForExistence(timeout: 5))

        // Download a template; it is selected once the download finished.
        app.buttons["Download Templates"].tap()
        let alpine = app.buttons["template.alpine-3.22-default_20250617_amd64.tar.xz"]
        XCTAssertTrue(alpine.waitForExistence(timeout: 10))
        snapshot("32-templates")
        alpine.tap()
        let download = app.buttons["Download to local"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        XCTAssertTrue(app.staticTexts["New Container"].waitForExistence(timeout: 15))
        let template = app.buttons["template"]
        XCTAssertTrue(template.waitForExistence(timeout: 5))
        XCTAssertTrue((template.value as? String)?.hasPrefix("alpine-3.22") == true)
        app.textFields["hostname"].tap()
        app.textFields["hostname"].typeText("alpine-01")
        type("secret1", into: app.secureTextFields["password"])
        type("secret1", into: app.secureTextFields["passwordConfirmation"])
        snapshot("33-create-container")

        app.buttons["create"].tap()
        XCTAssertTrue(app.staticTexts["alpine-01"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Stopped"].waitForExistence(timeout: 10))
    }

    private func open(_ identifier: String) {
        let create = app.buttons["create.menu"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        // Wait for the cluster to load, so the menu opens on a connected server.
        XCTAssertTrue(app.buttons["guest.100"].waitForExistence(timeout: 10))
        create.tap()
        let item = app.buttons[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    /// Scrolls the form until the field is visible, then types into it.
    private func type(_ text: String, into field: XCUIElement) {
        // Small drags, so the field stops above the keyboard instead of scrolling past it.
        for _ in 0..<15 where !(field.exists && field.isHittable) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
        field.tap()
        field.typeText(text)
    }

    /// Scrolls the form until the switch is visible, then flips it.
    private func toggle(_ identifier: String) {
        let element = app.switches[identifier]
        for _ in 0..<10 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        let wasOn = (element.value as? String) == "1"
        element.switches.firstMatch.tap()
        XCTAssertEqual((element.value as? String) == "1", !wasOn)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
