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
        app.buttons["next"].tap()
        XCTAssertTrue(app.staticTexts["Installation Media"].waitForExistence(timeout: 10))
        snapshot("31-create-vm-os")

        // The steps keep their values when going back.
        app.buttons["back"].tap()
        XCTAssertTrue(app.textFields["name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["name"].value as? String, "web-01")

        nextUntilConfirm()
        XCTAssertTrue(app.staticTexts["Summary"].waitForExistence(timeout: 5))
        toggle("startAfterCreation")
        snapshot("32-create-vm-confirm")
        app.buttons["create"].tap()

        // The new VM opens once its task finished, already running.
        XCTAssertTrue(app.staticTexts["web-01"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10))
        snapshot("33-created-vm")
    }

    @MainActor
    func testVMWithTwoDisks() {
        app.launch()
        open("create.vm")
        XCTAssertTrue(app.textFields["vmid"].waitForExistence(timeout: 5))
        for _ in 0..<3 { app.buttons["next"].tap() }
        tapScrolling(app.buttons["disk.add"])
        // The form loads rows lazily, so the new disk exists only once it is scrolled into view.
        XCTAssertTrue(scroll(to: app.buttons["disk.remove.scsi1"]))
        snapshot("37-create-vm-disks")

        nextUntilConfirm()
        XCTAssertTrue(scroll(to: app.staticTexts["scsi1"]))
        app.buttons["create"].tap()
        XCTAssertTrue(app.staticTexts["Stopped"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testInvalidNameStopsOnItsStep() {
        app.launch()
        open("create.vm")
        let name = app.textFields["name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("bad name")
        app.buttons["next"].tap()
        XCTAssertTrue(app.staticTexts["Use letters, digits, hyphens and dots only."].waitForExistence(timeout: 5))
        XCTAssertTrue(name.exists)
        // Later steps stay locked until this one is fixed.
        XCTAssertFalse(app.buttons["step.1"].isEnabled)
    }

    @MainActor
    func testCreateContainerWithDownloadedTemplate() {
        app.launch()
        open("create.ct")
        XCTAssertTrue(app.staticTexts["New Container"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["hostname"].waitForExistence(timeout: 5))
        app.textFields["hostname"].tap()
        app.textFields["hostname"].typeText("alpine-01")
        type("secret1", into: app.secureTextFields["password"])
        type("secret1", into: app.secureTextFields["passwordConfirmation"])
        snapshot("34-create-container")
        app.buttons["next"].tap()

        // Without a template the wizard does not go on.
        XCTAssertTrue(app.buttons["Download Templates"].waitForExistence(timeout: 5))
        app.buttons["next"].tap()
        XCTAssertTrue(app.staticTexts["Choose a template."].waitForExistence(timeout: 5))

        // Download a template; it is selected once the download finished.
        app.buttons["Download Templates"].tap()
        let alpine = app.buttons["template.alpine-3.22-default_20250617_amd64.tar.xz"]
        XCTAssertTrue(alpine.waitForExistence(timeout: 10))
        snapshot("35-templates")
        alpine.tap()
        let download = app.buttons["Download to local"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        // The picker can be in the hierarchy while the download screen is still open, so wait for its value.
        let template = app.buttons["template"]
        expectation(for: NSPredicate(format: "value BEGINSWITH 'alpine-3.22'"), evaluatedWith: template)
        waitForExpectations(timeout: 20)

        // A mount point needs a path before the wizard goes on.
        app.buttons["next"].tap()
        tapScrolling(app.buttons["mountPoint.add"])
        app.buttons["next"].tap()
        XCTAssertTrue(scroll(to: app.staticTexts["Enter a path in the container, e.g. /data."]))
        let path = app.textFields["mountPoint.path.mp0"]
        XCTAssertTrue(scroll(to: path))
        type("/data", into: path)

        nextUntilConfirm()
        XCTAssertTrue(app.staticTexts["Summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(scroll(to: app.staticTexts["mp0"]))
        snapshot("36-create-container-confirm")
        app.buttons["create"].tap()
        XCTAssertTrue(app.staticTexts["alpine-01"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Stopped"].waitForExistence(timeout: 10))
    }

    /// Taps Next until the Confirm step with its Create button shows.
    private func nextUntilConfirm() {
        for _ in 0..<10 where !app.buttons["create"].exists {
            app.buttons["next"].tap()
        }
        XCTAssertTrue(app.buttons["create"].waitForExistence(timeout: 5))
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
        // Small drags, so the field stops above the keyboard and the Back/Next bar instead of scrolling past them.
        let bar = app.buttons["next"]
        func isClear() -> Bool {
            field.exists && field.isHittable && (!bar.exists || field.frame.maxY < bar.frame.minY - 8)
        }
        for _ in 0..<15 where !isClear() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
        // A tap while the form still scrolls may not focus the field, so try again.
        for _ in 0..<3 {
            field.tap()
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { break }
        }
        field.typeText(text)
    }

    /// Scrolls the form down until the element is visible above the Back/Next bar.
    @discardableResult
    private func scroll(to element: XCUIElement) -> Bool {
        let bar = app.buttons["create"].exists ? app.buttons["create"] : app.buttons["next"]
        func isVisible() -> Bool {
            element.exists && element.isHittable && (!bar.exists || element.frame.maxY < bar.frame.minY - 8)
        }
        for _ in 0..<12 where !isVisible() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        return isVisible()
    }

    /// Scrolls the form until the element is visible, then taps it.
    private func tapScrolling(_ element: XCUIElement) {
        XCTAssertTrue(scroll(to: element))
        element.tap()
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
