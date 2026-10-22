import XCTest

final class AppLockUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory"]
    }

    @MainActor
    func testFourDigitPINLocksAndUnlocks() {
        app.launch()
        turnOnLock(pin: "1234", lengthButton: "4 Digits")
        snapshot("01-settings-lock-on")
        app.buttons["settings.done"].tap()

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["lock.forgot"].waitForExistence(timeout: 5))
        snapshot("02-lock-screen")

        type("0000")
        let message = app.staticTexts["lock.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 2))
        XCTAssertTrue(message.label.contains("Wrong PIN"), message.label)

        type("1234")
        XCTAssertTrue(app.buttons["lock.forgot"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings"].isHittable)

        // Turning the lock off asks for the PIN.
        app.buttons["settings"].tap()
        app.switches["settings.appLock"].switches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Enter Your Current PIN"].waitForExistence(timeout: 5))
        type("1234")
        XCTAssertTrue(app.buttons["settings.changePIN"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.switches["settings.appLock"].value as? String, "0")
    }

    @MainActor
    func testMismatchedConfirmationStartsOver() {
        app.launch()
        app.buttons["settings"].tap()
        app.switches["settings.appLock"].switches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Choose a PIN"].waitForExistence(timeout: 5))
        type("123456")
        XCTAssertTrue(app.staticTexts["Enter the PIN Again"].waitForExistence(timeout: 2))
        type("654321")
        XCTAssertTrue(app.staticTexts["The PINs did not match. Try again."].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Choose a PIN"].exists)
    }

    @MainActor
    func testForgottenPINRemovesServers() {
        app.launchArguments.append("-demo")
        app.launch()
        XCTAssertTrue(app.staticTexts["Cluster homelab"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        turnOnLock(pin: "123456", lengthButton: "6 Digits")
        app.buttons["settings.done"].tap()

        XCUIDevice.shared.press(.home)
        app.activate()
        let forgot = app.buttons["lock.forgot"]
        XCTAssertTrue(forgot.waitForExistence(timeout: 5))
        forgot.tap()
        app.buttons["Remove All Servers and Unlock"].tap()

        XCTAssertTrue(app.buttons["welcome.demo"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertFalse(app.buttons["lock.forgot"].waitForExistence(timeout: 2))
    }

    private func turnOnLock(pin: String, lengthButton: String) {
        app.buttons["settings"].tap()
        let toggle = app.switches["settings.appLock"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Choose a PIN"].waitForExistence(timeout: 5))
        app.buttons[lengthButton].tap()
        type(pin)
        XCTAssertTrue(app.staticTexts["Enter the PIN Again"].waitForExistence(timeout: 2))
        type(pin)
        XCTAssertTrue(app.buttons["settings.changePIN"].waitForExistence(timeout: 5))
    }

    private func type(_ pin: String) {
        for digit in pin {
            app.buttons["pin.\(digit)"].tap()
        }
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
