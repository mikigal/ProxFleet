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
    func testSDNControllerEVPNZoneAndFabric() {
        app.launch()
        open("datacenter.sdn")
        XCTAssertTrue(app.buttons["sdn.zone.lab"].waitForExistence(timeout: 10))
        reveal(app.buttons["sdn.controllers"]).tap()
        openAddMenu(showing: app.buttons["sdn.add.controller.evpn"], menu: "sdn.add.controller")
        type("evpn1", into: app.textFields["sdn.controller.id"])
        type("10.0.10.11, 10.0.10.12", into: app.textFields["sdn.controller.peers"])
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["sdn.controller.evpn1"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openAddMenu(showing: app.buttons["sdn.add.zone"])
        type("evz", into: app.textFields["sdn.zone.id"])
        app.buttons["sdn.zone.type"].tap()
        app.buttons["EVPN"].firstMatch.tap()
        XCTAssertTrue(app.buttons["sdn.zone.controller"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sdn.zone.controller"].label.contains("evpn1"))
        type("10000", into: app.textFields["sdn.zone.vrfvxlan"])
        snapshot("85-sdn-evpn-zone")
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["sdn.zone.evz"].waitForExistence(timeout: 10))

        reveal(app.buttons["sdn.fabrics"]).tap()
        openAddMenu(showing: app.buttons["sdn.add.fabric.openfabric"], menu: "sdn.add.fabric")
        type("under", into: app.textFields["sdn.fabric.id"])
        type("10.255.0.0/24", into: app.textFields["sdn.fabric.prefix"])
        app.buttons["save"].tap()
        let fabric = app.buttons["sdn.fabric.under"]
        XCTAssertTrue(fabric.waitForExistence(timeout: 10))
        fabric.tap()
        app.buttons["sdn.fabricnode.add"].tap()
        type("10.255.0.1", into: app.textFields["sdn.fabricnode.ip"])
        let interface = app.switches["sdn.fabricnode.iface.nic1"]
        XCTAssertTrue(interface.waitForExistence(timeout: 10))
        interface.switches.firstMatch.tap()
        snapshot("86-sdn-fabric-node")
        app.buttons["save"].tap()
        let node = app.buttons["sdn.fabricnode.pve1"]
        XCTAssertTrue(node.waitForExistence(timeout: 10))
        XCTAssertTrue(node.label.contains("nic1"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let apply = app.buttons["sdn.apply"]
        reveal(apply).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: apply)
        waitForExpectations(timeout: 15)
        snapshot("87-sdn-routing")
    }

    @MainActor
    func testSDNPrefixListsRouteMapsAndIPAM() {
        app.launch()
        open("datacenter.sdn")
        XCTAssertTrue(app.buttons["sdn.zone.lab"].waitForExistence(timeout: 10))
        reveal(app.buttons["sdn.prefixlists"]).tap()
        app.buttons["sdn.prefixlist.private"].tap()
        XCTAssertTrue(app.buttons["sdn.prefixentry.5"].waitForExistence(timeout: 10))
        app.buttons["sdn.prefixentry.add"].tap()
        type("100.64.0.0/10", into: app.textFields["sdn.prefixentry.prefix"])
        type("24", into: app.textFields["sdn.prefixentry.le"])
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["sdn.prefixentry.20"].waitForExistence(timeout: 10))
        snapshot("88-sdn-prefix-list")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        reveal(app.buttons["sdn.routemaps"]).tap()
        app.buttons["sdn.routemap.uplink-in"].tap()
        app.buttons["sdn.routemapentry.add"].tap()
        app.buttons["match.add"].tap()
        let list = app.buttons["match.0.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.tap()
        app.buttons["private"].firstMatch.tap()
        snapshot("89-sdn-route-map-entry")
        app.buttons["save"].tap()
        let entry = app.buttons["sdn.routemapentry.20"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(entry.label.contains("private"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        reveal(app.buttons["sdn.ipam.pve"]).tap()
        let add = app.buttons["ipam.add.labnet"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        type("BC:24:11:00:00:30", into: app.textFields["ipam.mac"])
        type("10.50.0.30", into: app.textFields["ipam.ip"])
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["ipam.10.50.0.30"].waitForExistence(timeout: 10))
        snapshot("90-sdn-ipam")
    }

    /// Scrolls the list until the element can be tapped, first down, then back up.
    private func reveal(_ element: XCUIElement) -> XCUIElement {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeDown() }
        return element
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
