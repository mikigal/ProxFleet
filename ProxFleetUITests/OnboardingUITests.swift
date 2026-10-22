import XCTest

final class OnboardingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory"]
    }

    @MainActor
    func testDemoClusterShowsNodesAndGuests() {
        app.launch()
        snapshot("01-welcome")

        app.buttons["welcome.addServer"].tap()
        let address = app.textFields["address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.typeText("demo.proxfleet\n")

        XCTAssertTrue(app.staticTexts["Cluster homelab"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["pve1"].exists)
        XCTAssertTrue(app.staticTexts["Offline"].exists)
        snapshot("02-demo-overview")

        app.swipeUp()
        XCTAssertTrue(app.staticTexts["pihole"].waitForExistence(timeout: 2))
        snapshot("03-demo-guests")
    }

    /// Uses a public host with a self-signed certificate to exercise the trust-on-first-use screen.
    @MainActor
    func testSelfSignedCertificateMustBeConfirmed() {
        app.launch()
        app.buttons["welcome.addServer"].tap()

        let address = app.textFields["address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.typeText("self-signed.badssl.com:443")
        snapshot("04-address")
        app.buttons["continue"].tap()

        let fingerprint = app.staticTexts["fingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 15))
        XCTAssertTrue(fingerprint.label.contains(":"))
        snapshot("05-certificate")

        app.buttons["trustCertificate"].tap()

        // Not a Proxmox server: the request now passes TLS but finds no API, and the user is sent back to the address.
        let error = app.descendants(matching: .any).matching(identifier: "errorMessage").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(error.label.contains("no Proxmox VE API"), error.label)
        XCTAssertTrue(app.textFields["address"].exists)
        snapshot("06-after-trust")
    }

    @MainActor
    func testUnreachableServerShowsError() {
        app.launch()
        app.buttons["welcome.addServer"].tap()
        let address = app.textFields["address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.typeText("does-not-exist.invalid")
        app.buttons["continue"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "errorMessage").firstMatch.waitForExistence(timeout: 20))
        snapshot("07-unreachable")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
