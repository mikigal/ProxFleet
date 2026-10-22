import XCTest

/// Pools, SDN and resource mappings on the demo cluster.
final class DatacenterResourcesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demo"]
    }

    @MainActor
    func testPools() {
        app.launch()
        open("datacenter.pools")
        XCTAssertTrue(app.buttons["pool.lab"].waitForExistence(timeout: 10))
        app.buttons["pool.add"].tap()
        type("prod", into: app.textFields["pool.name"])
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["pool.prod"].waitForExistence(timeout: 10))
        snapshot("80-pools")

        app.buttons["pool.prod"].tap()
        app.buttons["pool.addGuests"].tap()
        let guest = app.switches["pool.candidate.100"]
        XCTAssertTrue(guest.waitForExistence(timeout: 10))
        guest.switches.firstMatch.tap()
        app.buttons["save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pool.member.100"].waitForExistence(timeout: 10))
        snapshot("81-pool")
    }

    @MainActor
    func testSDN() {
        app.launch()
        open("datacenter.sdn")
        XCTAssertTrue(app.buttons["sdn.zone.lab"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sdn.vnet.labnet"].exists)

        openAddMenu(showing: app.buttons["sdn.add.zone"])
        type("office", into: app.textFields["sdn.zone.id"])
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["sdn.zone.office"].waitForExistence(timeout: 10))

        openAddMenu(showing: app.buttons["sdn.add.vnet"])
        type("desks", into: app.textFields["sdn.vnet.id"])
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["sdn.vnet.desks"].waitForExistence(timeout: 10))
        snapshot("82-sdn-pending")

        let apply = app.buttons["sdn.apply"]
        XCTAssertTrue(apply.exists)
        apply.tap()
        // Applied, nothing is pending any more.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: apply)
        waitForExpectations(timeout: 15)

        app.buttons["sdn.vnet.labnet"].tap()
        XCTAssertTrue(app.buttons["sdn.subnet.10.50.0.0/24"].waitForExistence(timeout: 10))
        snapshot("83-vnet")
    }

    @MainActor
    func testResourceMappings() {
        app.launch()
        open("datacenter.mappings")
        XCTAssertTrue(app.buttons["mapping.pci.gpu-a2000"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["mapping.dir.media"].exists)
        snapshot("84-mappings")

        openAddMenu(showing: app.buttons["mapping.add.usb"], menu: "mapping.add")
        type("ups", into: app.textFields["mapping.id"])
        let choose = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mapping.choose.'")).firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.tap()
        let device = app.buttons["mapping.usb.0463:ffff"]
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        device.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["mapping.usb.ups"].waitForExistence(timeout: 10))
    }

    /// Opens the Add menu, again if a closing sheet swallowed the tap, and picks an item.
    private func openAddMenu(showing item: XCUIElement, menu: String = "sdn.add") {
        for _ in 0..<5 where !item.exists {
            app.buttons[menu].tap()
            _ = item.waitForExistence(timeout: 2)
        }
        item.tap()
    }

    private func open(_ identifier: String) {
        let entry = app.buttons[identifier]
        XCTAssertTrue(app.buttons["node.pve1"].waitForExistence(timeout: 10))
        for _ in 0..<12 where !entry.isHittable { app.swipeUp() }
        entry.tap()
    }

    /// Scrolls the form until the field is visible, then types into it.
    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
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
