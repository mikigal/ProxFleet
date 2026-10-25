import XCTest

/// The demo backup server: dashboard, datastores and tasks.
final class BackupServerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-inMemory", "-demoBackupServer"]
    }

    @MainActor
    func testDashboard() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        snapshot("pbs-dashboard-top")

        let main = app.descendants(matching: .any)["datastore.main"]
        for _ in 0..<8 where !main.exists { app.swipeUp() }
        XCTAssertTrue(main.exists)
        XCTAssertTrue(main.label.contains("of"), main.label)
        XCTAssertTrue(app.descendants(matching: .any)["datastore.offsite"].label.contains("Not Mounted"))
        snapshot("pbs-dashboard-datastores")

        let backups = app.descendants(matching: .any)["summary.backup"]
        for _ in 0..<6 where !backups.exists { app.swipeUp() }
        XCTAssertTrue(backups.exists)
        // A month of nightly backups of seven guests, one of them failed.
        XCTAssertTrue(backups.label.contains("Backups"), backups.label)
        snapshot("pbs-dashboard-tasks")
        let longest = app.staticTexts["Longest Tasks"]
        for _ in 0..<10 where !longest.exists { app.swipeUp() }
        XCTAssertTrue(longest.exists)
        snapshot("pbs-dashboard-longest")
        for _ in 0..<6 { app.swipeUp() }
        snapshot("pbs-dashboard-bottom")
    }

    @MainActor
    func testDatastoresAndTasks() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        app.buttons["tab.datastores"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["datastore.main"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["datastore.offsite"].exists)
        snapshot("pbs-datastores")

        app.buttons["tasks"].tap()
        let gc = app.staticTexts["main – Garbage Collection"].firstMatch
        XCTAssertTrue(gc.waitForExistence(timeout: 10))
        snapshot("pbs-tasks")
        gc.tap()
        // The output is one text of all lines.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'TASK OK'")).firstMatch.waitForExistence(timeout: 10))
        snapshot("pbs-task-log")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["tab.more"].tap()
        XCTAssertTrue(app.buttons["more.services"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '4.2.1'")).firstMatch.exists)
        snapshot("pbs-more")
        // Sign Out ends the list, below the administration rows.
        let signOut = app.buttons["signOut"]
        for _ in 0..<8 where !signOut.exists { app.swipeUp() }
        XCTAssertTrue(signOut.exists)
    }

    @MainActor
    func testDatastoreSummaryOptionsAndPermissions() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        app.buttons["tab.datastores"].tap()
        // In the list the row is a navigation link; its content carries the same identifier.
        let main = app.buttons["datastore.main"]
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        main.tap()

        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'groups'")).firstMatch.waitForExistence(timeout: 10))
        snapshot("pbs-datastore-summary")
        app.buttons["datastore.actions"].tap()
        app.buttons["datastore.gc"].tap()
        // The task starts without an error; it shows in the server's task list.
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 3))

        // Comment and verify-new, saved through the general and verification editors.
        app.buttons["tab.options"].tap()
        let general = app.buttons["options.general"]
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        general.tap()
        let comment = app.textFields["datastore.comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
        comment.tap()
        comment.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        comment.typeText("Nightly backups")
        app.buttons["save"].tap()
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        XCTAssertTrue(general.label.contains("Nightly backups"), general.label)

        app.buttons["options.maintenance"].tap()
        XCTAssertTrue(app.buttons["Read-Only"].waitForExistence(timeout: 5))
        app.buttons["Read-Only"].tap()
        app.textFields["datastore.maintenanceMessage"].tap()
        app.textFields["datastore.maintenanceMessage"].typeText("Disk swap")
        snapshot("pbs-datastore-maintenance")
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["options.maintenance"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["options.maintenance"].label.contains("Read-Only"))

        app.buttons["tab.permissions"].tap()
        XCTAssertTrue(app.staticTexts["anna@pbs"].waitForExistence(timeout: 10))
        app.buttons["permissions.add"].tap()
        XCTAssertTrue(app.buttons["permission.user"].waitForExistence(timeout: 5))
        app.buttons["permission.user"].tap()
        app.buttons["monitoring@pbs!zabbix"].tap()
        app.buttons["permission.save"].tap()
        XCTAssertTrue(app.staticTexts["monitoring@pbs!zabbix"].waitForExistence(timeout: 10))
        snapshot("pbs-datastore-permissions")
    }

    @MainActor
    func testJobsAndRemotes() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        app.buttons["tab.jobs"].tap()
        let verify = app.buttons["job.verify.weekly-verify"]
        XCTAssertTrue(verify.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["job.sync.offsite-copy"].exists)
        XCTAssertTrue(app.buttons["job.sync.cloud-push"].exists)
        snapshot("pbs-jobs")

        // Run Now from the editor; the log of the new run opens from there. (The verification job is already running
        // when the demo starts, so it cannot be started again.)
        app.buttons["job.prune.default-main-e0c4a2f1-3b8d"].tap()
        let run = app.buttons["job.run"]
        for _ in 0..<6 where !run.exists || !run.isHittable { app.swipeUp() }
        run.tap()
        let log = app.buttons["job.log"]
        XCTAssertTrue(log.waitForExistence(timeout: 10))
        // The run takes a few seconds in the demo; Run Now is enabled again when it ended.
        XCTAssertTrue(run.waitForEnabled(timeout: 15))
        snapshot("pbs-prune-job")
        log.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'TASK OK'")).firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()

        // A new pull job: a too short ID is caught before sending, then the job is added with a filter.
        app.buttons["job.add"].tap()
        app.buttons["job.add.pull"].tap()
        let id = app.textFields["syncjob.id"]
        XCTAssertTrue(id.waitForExistence(timeout: 5))
        id.tap()
        id.typeText("x")
        app.buttons["save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Use 3 to 32'")).firstMatch.waitForExistence(timeout: 5))
        // Selects the short ID and types over it; a tap would put the cursor before the right-aligned text.
        id.doubleTap()
        id.typeText("x-ui-pull\n")
        XCTAssertEqual(id.value as? String, "x-ui-pull")
        let addFilter = app.buttons["groupfilter.add"]
        for _ in 0..<8 where !addFilter.isHittable { app.swipeUp() }
        // A tap while the keyboard is still going away does not open the menu; try again.
        let typeFilter = app.buttons["groupfilter.add.type"]
        for _ in 0..<3 where !typeFilter.exists {
            addFilter.tap()
            _ = typeFilter.waitForExistence(timeout: 2)
        }
        typeFilter.tap()
        snapshot("pbs-sync-job-editor")
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["job.sync.x-ui-pull"].waitForExistence(timeout: 10))

        // The jobs of one datastore, with its garbage collection.
        app.buttons["tab.datastores"].tap()
        let main = app.buttons["datastore.main"]
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        main.tap()
        XCTAssertTrue(app.buttons["tab.jobs"].waitForExistence(timeout: 5))
        app.buttons["tab.jobs"].tap()
        XCTAssertTrue(app.buttons["job.gc.main"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["job.sync.offsite-copy"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        // A remote's connection check lists what its user sees there.
        app.buttons["tab.more"].tap()
        XCTAssertTrue(app.buttons["more.services"].waitForExistence(timeout: 5))
        openMoreRow("more.remotes")
        let cloud = app.buttons["remote.cloud"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 10))
        cloud.tap()
        let check = app.buttons["remote.check"]
        for _ in 0..<6 where !check.exists || !check.isHittable { app.swipeUp() }
        check.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'homelab-copy'")).firstMatch.waitForExistence(timeout: 10))
        snapshot("pbs-remote")
    }

    @MainActor
    func testAdministration() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        app.buttons["tab.more"].tap()
        let services = app.buttons["more.services"]
        XCTAssertTrue(services.waitForExistence(timeout: 5))
        services.tap()
        XCTAssertTrue(app.descendants(matching: .any)["service.proxmox-backup-proxy"].waitForExistence(timeout: 10))
        snapshot("pbs-services")
        app.navigationBars.buttons.firstMatch.tap()

        // A directory with a datastore on the unused disk.
        openMoreRow("more.disks")
        XCTAssertTrue(app.buttons["disk.sdd"].waitForExistence(timeout: 10))
        snapshot("pbs-disks")
        app.buttons["disks.add"].tap()
        app.buttons["disks.add.directory"].tap()
        let name = app.textFields["storage.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("usb-copy\n")
        app.buttons["candidate.sdd"].tap()
        snapshot("pbs-new-directory")
        app.buttons["storage.create"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["directory.usb-copy"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.firstMatch.tap()

        // A bridge, applied.
        openMoreRow("more.network")
        XCTAssertTrue(app.buttons["interface.vmbr0"].waitForExistence(timeout: 10))
        app.buttons["network.add"].tap()
        // A backup server has no Open vSwitch.
        XCTAssertFalse(app.buttons["network.add.OVSBridge"].exists)
        app.buttons["Linux Bridge"].firstMatch.tap()
        let comment = app.textFields["interface.comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
        comment.tap()
        comment.typeText("Backup network")
        app.buttons["save"].tap()
        let apply = app.buttons["network.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        apply.tap()
        let confirm = app.alerts.buttons["network.apply.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["interface.vmbr1"].waitForExistence(timeout: 10))
        let applied = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: applied, object: apply)], timeout: 10), .completed)
        snapshot("pbs-network")
        app.navigationBars.buttons.firstMatch.tap()

        // The server's options.
        openMoreRow("more.options")
        let proxy = app.textFields["options.httpProxy"]
        XCTAssertTrue(proxy.waitForExistence(timeout: 10))
        proxy.tap()
        proxy.typeText("http://proxy.home.arpa:3128")
        snapshot("pbs-options")
        app.buttons["save"].tap()
        XCTAssertTrue(app.buttons["more.options"].waitForExistence(timeout: 10))
        openMoreRow("more.options")
        XCTAssertTrue(proxy.waitForExistence(timeout: 10))
        XCTAssertEqual(proxy.value as? String, "http://proxy.home.arpa:3128")
    }

    /// Every screen of the backup server opens in demo mode, which App Review uses: no request the demo cannot answer,
    /// no error view and no alert.
    @MainActor
    func testEveryScreenOpensInDemoMode() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        let problems = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'demo mode' OR label BEGINSWITH 'Cannot '"))
        func check(_ screen: String) {
            // Loading spinners go away once the screen has its data.
            let loading = app.activityIndicators.firstMatch
            for _ in 0..<10 where loading.exists { usleep(500_000) }
            XCTAssertFalse(problems.firstMatch.exists, "\(screen): \(problems.firstMatch.label)")
            XCTAssertEqual(app.alerts.count, 0, screen)
        }
        // A tap right after a screen opened is sometimes lost; go back again until the list shows.
        func back(to element: XCUIElement) {
            for _ in 0..<3 where !element.waitForExistence(timeout: 2) || !element.isHittable {
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
        check("dashboard")

        app.buttons["tab.more"].tap()
        let rows = ["more.updates", "more.services", "more.log", "more.report", "more.network", "more.disks", "more.dns", "more.time",
                    "more.certificates", "more.options", "more.users", "more.permissions", "more.tfa", "more.realms", "more.remotes",
                    "more.traffic", "more.notifications", "more.metrics", "more.s3", "more.keys"]
        for identifier in rows {
            openMoreRow(identifier)
            check(identifier)
        }
        back(to: app.buttons["tab.more"])

        app.buttons["tab.jobs"].tap()
        check("jobs")
        for job in ["offsite-copy", "cloud-push", "weekly-verify", "main"] {
            let row = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", ".\(job)")).firstMatch
            guard row.waitForExistence(timeout: 5) else { XCTFail("job \(job)"); continue }
            row.tap()
            check("job \(job)")
            back(to: app.buttons["tab.jobs"])
        }

        app.buttons["tab.datastores"].tap()
        for store in ["main", "offsite"] {
            let row = app.buttons["datastore.\(store)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            for tab in ["summary", "content", "jobs", "options", "permissions"] {
                let button = app.buttons["tab.\(tab)"]
                XCTAssertTrue(button.waitForExistence(timeout: 5))
                button.tap()
                check("\(store) \(tab)")
            }
            back(to: app.buttons["datastore.offsite"])
        }
    }

    @MainActor
    func testConfiguration() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        app.buttons["tab.more"].tap()
        func open(_ identifier: String) { openMoreRow(identifier) }
        func back() { app.navigationBars.buttons.firstMatch.tap() }

        // A new user with a password, then an API token whose secret shows once.
        open("more.users")
        XCTAssertTrue(app.buttons["user.backup@pbs"].waitForExistence(timeout: 10))
        app.buttons["user.add"].tap()
        let userName = app.textFields["user.name"]
        XCTAssertTrue(userName.waitForExistence(timeout: 5))
        userName.tap()
        // The realm defaults to pbs, whose users have a password here.
        userName.typeText("sync")
        let password = app.secureTextFields["user.newPassword"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        password.typeText("a-long-password")
        let confirmation = app.secureTextFields["user.confirmPassword"]
        confirmation.tap()
        confirmation.typeText("a-long-password")
        snapshot("pbs-new-user")
        app.buttons["save"].tap()
        let user = app.buttons["user.sync@pbs"]
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        snapshot("pbs-users")
        user.tap()
        let addToken = app.buttons["token.add"]
        for _ in 0..<6 where !addToken.exists || !addToken.isHittable { app.swipeUp() }
        addToken.tap()
        let tokenName = app.textFields["token.name"]
        XCTAssertTrue(tokenName.waitForExistence(timeout: 5))
        tokenName.tap()
        tokenName.typeText("remote")
        app.buttons["token.create"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["token.secret"].waitForExistence(timeout: 10))
        snapshot("pbs-token-secret")
        app.buttons["token.done"].tap()
        XCTAssertTrue(app.buttons["token.sync@pbs!remote"].waitForExistence(timeout: 10))
        back()
        back()

        // Realms, traffic control, notifications and an S3 endpoint's buckets.
        open("more.realms")
        XCTAssertTrue(app.buttons["realm.home"].waitForExistence(timeout: 10))
        snapshot("pbs-realms")
        back()
        open("more.traffic")
        XCTAssertTrue(app.buttons["traffic.office-hours"].waitForExistence(timeout: 10))
        snapshot("pbs-traffic-control")
        back()
        open("more.notifications")
        XCTAssertTrue(app.buttons["target.mail-to-root"].waitForExistence(timeout: 10))
        snapshot("pbs-notifications")
        back()
        open("more.s3")
        let minio = app.buttons["s3.minio"]
        XCTAssertTrue(minio.waitForExistence(timeout: 10))
        minio.tap()
        let check = app.buttons["s3.check"]
        for _ in 0..<6 where !check.exists || !check.isHittable { app.swipeUp() }
        check.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'pbs-offsite'")).firstMatch.waitForExistence(timeout: 10))
        snapshot("pbs-s3-endpoint")
    }

    @MainActor
    func testAddAndRemoveDatastore() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        app.buttons["tab.datastores"].tap()
        let add = app.buttons["datastore.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let name = app.textFields["datastore.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("archive")
        // A relative path is refused before anything is sent.
        let path = app.textFields["datastore.path"]
        path.tap()
        path.typeText("archive")
        app.buttons["datastore.create"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'absolute path'")).firstMatch.waitForExistence(timeout: 5))
        snapshot("pbs-add-datastore-error")
        path.tap()
        path.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        path.typeText("/mnt/datastore/archive")
        app.buttons["datastore.create"].tap()

        let archive = app.buttons["datastore.archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 15))
        archive.tap()
        app.buttons["tab.options"].tap()
        let remove = app.buttons["datastore.remove"]
        for _ in 0..<6 where !remove.isHittable { app.swipeUp() }
        remove.tap()
        let confirm = app.textFields["remove.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["remove.submit"].isEnabled)
        confirm.tap()
        confirm.typeText("archive")
        app.buttons["remove.submit"].tap()
        XCTAssertTrue(app.buttons["datastore.main"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["datastore.archive"].exists)
    }

    /// Opens the content of the main datastore's homelab namespace.
    /// Opens a row of the More tab. Taps right after a screen changed are sometimes lost, so it goes back until the
    /// list shows, and taps the row again when nothing opened. The list may be scrolled anywhere after coming back:
    /// it looks below, then above. The floating tab bar covers the rows below its top edge, where a tap would switch
    /// tabs instead.
    private func openMoreRow(_ identifier: String) {
        let more = app.buttons["tab.more"]
        for _ in 0..<3 where !more.waitForExistence(timeout: 2) { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertTrue(more.exists, "the More list before \(identifier)")
        let row = app.buttons[identifier]
        func belowTabBar() -> Bool { row.frame.maxY > more.frame.minY }
        for _ in 0..<8 where !row.exists || !row.isHittable || belowTabBar() { app.swipeUp() }
        for _ in 0..<8 where !row.exists || !row.isHittable { app.swipeDown() }
        for _ in 0..<3 where belowTabBar() { app.swipeUp() }
        row.tap()
        sleep(1)
        if more.exists, more.isHittable, row.exists, row.isHittable { row.tap() }
    }

    private func openHomelabContent() {
        app.launch()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
        app.buttons["tab.datastores"].tap()
        let main = app.buttons["datastore.main"]
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        main.tap()
        app.buttons["tab.content"].tap()
        let homelab = app.buttons["namespace.homelab"]
        XCTAssertTrue(homelab.waitForExistence(timeout: 10))
        snapshot("pbs-content-root")
        homelab.tap()
    }

    @MainActor
    func testBrowseABackupAndDownloadAFile() {
        openHomelabContent()
        let container = app.buttons["group.ct/200"]
        XCTAssertTrue(container.waitForExistence(timeout: 10))
        snapshot("pbs-content-groups")
        container.tap()
        let newest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'snapshot.'")).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        snapshot("pbs-group")
        newest.tap()

        XCTAssertTrue(app.switches["snapshot.protected"].waitForExistence(timeout: 5))
        let archive = app.buttons["file.root.pxar.didx"]
        for _ in 0..<4 where !archive.isHittable { app.swipeUp() }
        snapshot("pbs-snapshot")
        archive.tap()
        let etc = app.buttons["catalog.etc"]
        XCTAssertTrue(etc.waitForExistence(timeout: 10))
        etc.tap()
        let hostname = app.buttons["catalog.hostname"]
        XCTAssertTrue(hostname.waitForExistence(timeout: 10))
        snapshot("pbs-catalog")
        hostname.tap()
        // Quick Look shows the downloaded file under the name the web interface gives it.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'ct-200-hostname'")).firstMatch.waitForExistence(timeout: 15))
        snapshot("pbs-download-preview")
    }

    @MainActor
    func testGroupNotesPruneAndNamespaces() {
        openHomelabContent()
        let group = app.buttons["group.vm/101"]
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        group.tap()
        let notes = app.buttons["group.notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.tap()
        let text = app.textViews["notes.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText(" checked")
        app.buttons["notes.save"].tap()
        XCTAssertTrue(app.buttons["group.notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["group.notes"].label.contains("checked"), app.buttons["group.notes"].label)

        app.buttons["group.actions"].tap()
        app.buttons["group.prune"].tap()
        // Keep the last three of the ten snapshots.
        XCTAssertTrue(app.staticTexts["Remove"].firstMatch.waitForExistence(timeout: 10))
        snapshot("pbs-prune-preview")
        app.buttons["prune.start"].tap()
        // The group's screen stays in the hierarchy under the sheet, so wait for the sheet to close.
        XCTAssertTrue(app.buttons["prune.start"].waitForNonExistence(timeout: 15))
        let snapshots = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'snapshot.'"))
        expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: snapshots)
        waitForExpectations(timeout: 10)
        snapshot("pbs-group-after-prune")

        app.navigationBars.buttons.firstMatch.tap()
        // Coming back shows the pruned group's new count.
        let pruned = app.buttons.matching(NSPredicate(format: "identifier == 'group.vm/101' AND label CONTAINS '3 snapshots'")).firstMatch
        XCTAssertTrue(pruned.waitForExistence(timeout: 10))
        app.buttons["namespace.actions"].tap()
        app.buttons["namespace.create"].tap()
        // Alerts drop the identifiers of their text fields.
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("archive")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["namespace.homelab/archive"].waitForExistence(timeout: 10))
    }

    /// The demo address adds both demo servers, so App Review finds the backup server too.
    @MainActor
    func testDemoAddressAddsBothServers() {
        app.launchArguments = ["-inMemory"]
        app.launch()
        app.buttons["welcome.addServer"].tap()
        let address = app.textFields["address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '8006'")).firstMatch.exists)
        app.buttons["Backup Server"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '8007'")).firstMatch.exists)
        snapshot("pbs-add-server")
        app.buttons["Proxmox VE"].tap()
        address.tap()
        address.typeText("demo.proxfleet\n")

        XCTAssertTrue(app.staticTexts["Cluster homelab"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        let backupServer = app.descendants(matching: .any)["server.Demo Backup Server"]
        XCTAssertTrue(backupServer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["server.Demo Cluster"].exists)
        snapshot("pbs-server-list")
        backupServer.tap()
        XCTAssertTrue(app.staticTexts["Proxmox Backup Server 4.2.1"].waitForExistence(timeout: 10))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    /// Waits until the element can be used again, e.g. after the task it started has ended.
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }
}
