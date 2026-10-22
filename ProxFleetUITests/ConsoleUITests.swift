import XCTest

/// The VM console on the demo cluster: pointer, key bar, full screen and landscape.
final class ConsoleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo"]
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testConsoleFullScreenTurnsToLandscape() {
        app.launch()
        let guest = app.buttons["guest.100"]
        XCTAssertTrue(guest.waitForExistence(timeout: 10))
        guest.tap()
        app.buttons["tab.console"].tap()
        let screen = app.descendants(matching: .any)["vncScreen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 10))

        // Trackpad: a drag moves the pointer, a tap clicks; the console stays connected.
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)))
        screen.tap()
        XCTAssertFalse(app.staticTexts["Console Closed"].exists)
        snapshot("60-console")

        // Embedded, the app stays in portrait.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertFalse(isLaidOutInLandscape(), "the embedded console keeps the app in portrait")

        XCUIDevice.shared.orientation = .portrait
        app.buttons["vnc.fullScreen"].tap()
        XCTAssertTrue(app.buttons["Exit Full Screen"].firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = expectation(for: NSPredicate { _, _ in self.isLaidOutInLandscape() }, evaluatedWith: nil)
        wait(for: [landscape], timeout: 5)
        snapshot("61-console-landscape")
        XCTAssertFalse(app.staticTexts["Console Closed"].exists)

        // Leaving full screen brings back portrait.
        app.buttons["Exit Full Screen"].firstMatch.tap()
        let portrait = expectation(for: NSPredicate { _, _ in !self.isLaidOutInLandscape() }, evaluatedWith: nil)
        wait(for: [portrait], timeout: 5)

        app.buttons["vnc.settings"].tap()
        XCTAssertTrue(app.buttons["Touch"].waitForExistence(timeout: 5))
        app.buttons["Touch"].tap()
        XCTAssertFalse(app.staticTexts["Console Closed"].exists)
    }

    /// The key bar runs along the bottom of the app's own layout; laid out in landscape, it is wider than tall
    /// in the device's landscape coordinates and its buttons sit side by side.
    private func isLaidOutInLandscape() -> Bool {
        let window = app.windows.firstMatch.frame
        let fullScreen = app.buttons["vnc.fullScreen"].firstMatch.frame
        let keyboard = app.buttons["vnc.keyboard"].firstMatch.frame
        let sideBySide = abs(fullScreen.midY - keyboard.midY) < 4 && keyboard.minX > fullScreen.maxX
        return window.width > window.height && sideBySide
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
