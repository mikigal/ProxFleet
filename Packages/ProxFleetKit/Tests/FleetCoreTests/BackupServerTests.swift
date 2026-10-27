import DemoServer
@testable import FleetCore
import Foundation
import PBSKit
import ProxmoxCore
import PVEKit
import Testing

/// Port 8007 reaches a demo backup server, any other port the demo cluster; listed addresses are unreachable.
private final class ProductRouter: HTTPTransport {
    let cluster = DemoTransport()
    let backupServer: DemoBackupServerTransport
    let unreachable: Set<String>

    init(backupServer: DemoBackupServer = .homelab, unreachable: Set<String> = []) {
        self.backupServer = DemoBackupServerTransport(server: backupServer)
        self.unreachable = unreachable
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let address = "\(request.url.host() ?? ""):\(request.url.port ?? 443)"
        if unreachable.contains(address) { throw ProxmoxError.transport("Could not connect to the server.") }
        return try await (request.url.port == 8007 ? backupServer.send(request) : cluster.send(request))
    }
}

private func environment(_ router: ProductRouter) -> FleetEnvironment {
    FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in router }
}

@MainActor
struct BackupServerOnboardingTests {
    @Test func addsABackupServerChosenByTheUser() async throws {
        let fleet = Fleet(environment: environment(ProductRouter()))
        let onboarding = fleet.makeOnboarding()
        onboarding.product = .backupServer
        onboarding.addressText = "pbs.lan"
        await onboarding.submitAddress()
        #expect(onboarding.step == .credentials)
        #expect(!onboarding.switchedProduct)
        #expect(onboarding.realms.map(\.realm) == ["pam", "pbs", "home"])

        onboarding.username = "root"
        onboarding.password = "secret"
        await onboarding.signIn()
        guard case .finished(let profile) = onboarding.step else {
            Issue.record("expected finished, got \(onboarding.step)")
            return
        }
        #expect(profile.product == .backupServer)
        #expect(profile.addresses == [ServerAddress(host: "pbs.lan", port: 8007)])
        #expect(profile.name == "pbs")
        #expect(profile.clusterName == nil)

        let connection = try #require(fleet.connection(for: profile.id))
        await connection.refresh()
        #expect(connection.state == .connected)
        let snapshot = try #require(connection.backupServer)
        #expect(snapshot.datastores.map(\.store) == ["main", "offsite", "s3-archive"])
        #expect(snapshot.version?.displayVersion == "4.2.1")
        #expect(snapshot.status?.cpuCount == 8)
        #expect(snapshot.usage(of: "main")?.estimatedFullDate != nil)
        #expect(snapshot.usage(of: "offsite")?.error != nil)
        #expect(connection.snapshot == nil)
    }

    @Test func recognizesABackupServerAtATypedPort() async {
        let fleet = Fleet(environment: environment(ProductRouter()))
        let onboarding = fleet.makeOnboarding()
        onboarding.addressText = "pbs.lan:8007"
        await onboarding.submitAddress()
        #expect(onboarding.step == .credentials)
        #expect(onboarding.product == .backupServer)
        #expect(onboarding.switchedProduct)
    }

    @Test func triesTheOtherProductsPortWithoutATypedOne() async throws {
        let fleet = Fleet(environment: environment(ProductRouter(unreachable: ["pbs.lan:8006"])))
        let onboarding = fleet.makeOnboarding()
        onboarding.addressText = "pbs.lan"
        await onboarding.submitAddress()
        #expect(onboarding.step == .credentials)
        #expect(onboarding.product == .backupServer)
        #expect(onboarding.switchedProduct)

        onboarding.password = "secret"
        await onboarding.signIn()
        guard case .finished(let profile) = onboarding.step else {
            Issue.record("expected finished, got \(onboarding.step)")
            return
        }
        #expect(profile.addresses == [ServerAddress(host: "pbs.lan", port: 8007)])
    }

    @Test func aTypedPortIsNotChanged() async {
        let fleet = Fleet(environment: environment(ProductRouter(unreachable: ["pbs.lan:8006"])))
        let onboarding = fleet.makeOnboarding()
        onboarding.addressText = "pbs.lan:8006"
        await onboarding.submitAddress()
        #expect(onboarding.step == .address)
        #expect(onboarding.errorMessage == "Could not connect to the server.")
        #expect(onboarding.product == .virtualEnvironment)
    }

    @Test func anUnreachableHostReportsTheChosenPort() async {
        let fleet = Fleet(environment: environment(ProductRouter(unreachable: ["gone.lan:8006", "gone.lan:8007"])))
        let onboarding = fleet.makeOnboarding()
        onboarding.addressText = "gone.lan"
        await onboarding.submitAddress()
        #expect(onboarding.step == .address)
        #expect(onboarding.product == .virtualEnvironment)
        #expect(!onboarding.switchedProduct)
    }

    @Test func clustersAreStillRecognized() async {
        let fleet = Fleet(environment: environment(ProductRouter()))
        let onboarding = fleet.makeOnboarding()
        onboarding.product = .backupServer
        onboarding.addressText = "pve.lan:8006"
        await onboarding.submitAddress()
        #expect(onboarding.step == .credentials)
        #expect(onboarding.product == .virtualEnvironment)
        #expect(onboarding.switchedProduct)
    }

    @Test func oldReleasesAreAddedOnlyAfterAWarning() async {
        var old = DemoBackupServer.homelab
        old.version = "2.4"
        old.release = "7"
        let fleet = Fleet(environment: environment(ProductRouter(backupServer: old)))
        let onboarding = fleet.makeOnboarding()
        onboarding.addressText = "pbs.lan:8007"
        await onboarding.submitAddress()
        onboarding.password = "secret"
        await onboarding.signIn()
        #expect(onboarding.step == .unsupportedRelease(version: "2.4.7"))
        onboarding.addUnsupportedRelease()
        guard case .finished = onboarding.step else {
            Issue.record("expected finished, got \(onboarding.step)")
            return
        }
    }

    @Test func secondFactorForTheBackupServer() async {
        let fleet = Fleet(environment: environment(ProductRouter()))
        let onboarding = fleet.makeOnboarding()
        onboarding.addressText = "pbs.lan:8007"
        await onboarding.submitAddress()
        onboarding.username = "tfa"
        onboarding.realm = "pbs"
        onboarding.password = "secret"
        await onboarding.signIn()
        guard case .secondFactor(let challenge) = onboarding.step else {
            Issue.record("expected a second factor, got \(onboarding.step)")
            return
        }
        await onboarding.submitSecondFactor(challenge, method: .totp, code: DemoTransport.totpCode)
        guard case .finished(let profile) = onboarding.step else {
            Issue.record("expected finished, got \(onboarding.step)")
            return
        }
        #expect(profile.userID == "tfa@pbs")
    }

    @Test func theDemoAddressAddsBothDemoServers() async throws {
        let fleet = Fleet(environment: .inMemory())
        let onboarding = fleet.makeOnboarding()
        onboarding.addressText = Fleet.demoHost
        await onboarding.submitAddress()
        guard case .finished(let opened) = onboarding.step else {
            Issue.record("expected finished, got \(onboarding.step)")
            return
        }
        #expect(opened.product == .virtualEnvironment)
        #expect(fleet.profiles.map(\.product) == [.virtualEnvironment, .backupServer])
        #expect(fleet.profiles.allSatisfy { $0.isDemo })
        // Adding them again changes nothing.
        fleet.addDemoServer()
        fleet.addDemoBackupServer()
        #expect(fleet.profiles.count == 2)

        // Both connect: the backup server through its own demo transport.
        for profile in fleet.profiles {
            let connection = try #require(fleet.connection(for: profile.id))
            await connection.connect()
            #expect(connection.state == .connected, "\(profile.name): \(connection.state)")
        }
        #expect(fleet.connection(for: fleet.profiles[1].id)?.backupServer?.datastores.isEmpty == false)
    }
}

@MainActor
struct BackupServerConnectionTests {
    private func connectedDemo(_ server: DemoBackupServer = .homelab) async throws -> ServerConnection {
        let fleet = Fleet(environment: environment(ProductRouter(backupServer: server)))
        let profile = fleet.addSaved(ServerProfile(name: "pbs.lan", product: .backupServer, addresses: [ServerAddress(host: "pbs.lan", port: 8007)],
                                                   username: "root", realm: "pam"), password: "secret")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        #expect(connection.state == .connected)
        return connection
    }

    @Test func connectsAndNamesTheServer() async throws {
        let connection = try await connectedDemo()
        #expect(connection.isBackupServer)
        #expect(connection.profile.name == "pbs")
        #expect(connection.backupServer?.datastores.count == 3)
        #expect(connection.supports(backupServer: .moveGroupsAndNamespaces))
        #expect(await connection.canStopTask(startedBy: "someone@pbs", node: "localhost"))
        await connection.signOut()
        #expect(connection.backupServer == nil)
    }

    /// A screen that appears twice in a row cancels its first `connect()`; the attempt goes on and both callers end
    /// connected, instead of the first ending disconnected after the second returned early.
    @Test func aCancelledCallerDoesNotLeaveTheServerDisconnected() async throws {
        let fleet = Fleet(environment: environment(ProductRouter()))
        let profile = fleet.addSaved(ServerProfile(name: "pbs.lan", product: .backupServer, addresses: [ServerAddress(host: "pbs.lan", port: 8007)],
                                                   username: "root", realm: "pam"), password: "secret")
        let connection = try #require(fleet.connection(for: profile.id))
        let first = Task { await connection.connect() }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        await connection.connect()
        #expect(connection.state == .connected)
    }

    @Test func featuresFollowTheRelease() async throws {
        var old = DemoBackupServer.homelab
        old.version = "3.2"
        let connection = try await connectedDemo(old)
        #expect(connection.supports(backupServer: .notifications))
        #expect(!connection.supports(backupServer: .pushSync))
    }

    @Test func dashboardSummarizesTheTasksLikeTheWebInterface() async throws {
        let connection = try await connectedDemo()
        let dashboard = BackupServerDashboard(connection: connection)
        await dashboard.load()
        #expect(dashboard.hasLoaded)
        #expect(dashboard.tasksError == nil)
        #expect(!dashboard.history.isEmpty)
        #expect(dashboard.subscription?.isActive == true)

        let backups = try #require(dashboard.summary.first { $0.kind == .backup })
        #expect(backups.succeeded > 100)
        #expect(backups.failed == 1)
        #expect(dashboard.summary.first { $0.kind == .sync }?.warnings == 1)
        #expect(dashboard.summary.first { $0.kind == .verify }?.failed == 1)
        #expect(dashboard.summary.first { $0.kind == .garbageCollection }?.total ?? 0 >= 29)
        #expect(dashboard.runningTasks.count == 1)
        #expect(dashboard.longestTasks.count == 10)
        #expect(dashboard.longestTasks.first?.type == "syncjob")

        dashboard.days = 7
        try await Task.sleep(for: .seconds(1))
        #expect(dashboard.summary.first { $0.kind == .backup }?.failed == 0)
    }

    @Test func stopsTheRunningVerification() async throws {
        let connection = try await connectedDemo()
        let dashboard = BackupServerDashboard(connection: connection)
        await dashboard.load()
        let running = try #require(dashboard.runningTasks.first)
        try await connection.stopTask(node: running.node, upid: running.upid)
        let status = try await connection.send(PVE.taskStatus(node: running.node, upid: running.upid))
        #expect(!status.isRunning)
        #expect(status.exitStatus == "abort requested - aborting task")
        await dashboard.load()
        #expect(dashboard.runningTasks.isEmpty)
    }

    @Test func summaryCategoriesFollowTheWebInterface() {
        #expect(TaskSummaryRow.kind(of: "syncjob") == .sync)
        #expect(TaskSummaryRow.kind(of: "verificationjob") == .verify)
        #expect(TaskSummaryRow.kind(of: "verify_snapshot") == .verify)
        #expect(TaskSummaryRow.kind(of: "prunejob") == .prune)
        #expect(TaskSummaryRow.kind(of: "garbage_collection") == .garbageCollection)
        #expect(TaskSummaryRow.kind(of: "reader") == nil)
        #expect(TaskSummaryRow.kind(of: "logrotate") == nil)
    }
}
