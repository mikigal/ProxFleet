import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import Synchronization
import Testing

/// Routes every server to the demo cluster, optionally failing for some hosts.
private func demoEnvironment(cluster: DemoCluster = .homelab, unreachableHosts: Set<String> = []) -> FleetEnvironment {
    FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in
        FlakyTransport(base: DemoTransport(cluster: cluster), unreachableHosts: unreachableHosts)
    }
}

private final class FlakyTransport: HTTPTransport, CertificatePinning {
    let base: DemoTransport
    let unreachableHosts: Set<String>
    let pinned = Mutex<Set<String>>([])

    init(base: DemoTransport, unreachableHosts: Set<String>) {
        self.base = base
        self.unreachableHosts = unreachableHosts
    }

    func pin(_ fingerprint: String) { pinned.withLock { _ = $0.insert(fingerprint) } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let host = request.url.host() ?? ""
        if unreachableHosts.contains(host) { throw ProxmoxError.transport("unreachable") }
        if host.hasPrefix("selfsigned"), pinned.withLock({ !$0.contains("AA:BB") }) {
            throw ProxmoxError.untrustedCertificate(CertificateDetails(sha256Fingerprint: "AA:BB", subject: host))
        }
        return try await base.send(request)
    }
}

@MainActor
struct OnboardingTests {
    @Test func addsServerAfterCertificateAndLogin() async throws {
        let fleet = Fleet(environment: demoEnvironment())
        let onboarding = fleet.makeOnboarding()

        onboarding.addressText = "selfsigned.lan"
        await onboarding.submitAddress()
        guard case .certificate(let certificate) = onboarding.step else {
            Issue.record("expected certificate step, got \(onboarding.step)")
            return
        }
        #expect(certificate.sha256Fingerprint == "AA:BB")

        await onboarding.trustCertificate(certificate)
        #expect(onboarding.step == .credentials)
        #expect(onboarding.realms.map(\.realm) == ["pam", "pve"])

        onboarding.username = "root"
        onboarding.password = "secret"
        await onboarding.signIn()

        guard case .finished(let profile) = onboarding.step else {
            Issue.record("expected finished, got \(onboarding.step)")
            return
        }
        #expect(profile.name == "homelab")
        #expect(profile.clusterName == "homelab")
        #expect(profile.trustedFingerprints == ["AA:BB"])
        #expect(profile.addresses == [ServerAddress(host: "selfsigned.lan", port: 8006)])
        #expect(fleet.profiles == [profile])
        #expect(fleet.environment.credentials.password(for: profile.id) == "secret")
        #expect(fleet.environment.credentials.ticket(for: profile.id) != nil)
        #expect(onboarding.password.isEmpty)

        let connection = try #require(fleet.connection(for: profile.id))
        #expect(connection.state == .connected)
        await connection.refresh()
        #expect(connection.snapshot?.nodes.count == 3)
    }

    @Test func wrongPasswordShowsError() async {
        let fleet = Fleet(environment: demoEnvironment())
        let onboarding = fleet.makeOnboarding()
        onboarding.addressText = "pve.lan"
        await onboarding.submitAddress()
        onboarding.password = "wrong"
        await onboarding.signIn()
        #expect(onboarding.step == .credentials)
        #expect(onboarding.errorMessage == "Authentication failed: authentication failure")
        #expect(fleet.profiles.isEmpty)
    }

    @Test func secondFactorCanBeRetried() async throws {
        let fleet = Fleet(environment: demoEnvironment())
        let onboarding = fleet.makeOnboarding()
        onboarding.addressText = "pve.lan"
        await onboarding.submitAddress()
        onboarding.username = "tfa-admin"
        onboarding.realm = "pve"
        onboarding.password = "secret"
        onboarding.rememberPassword = false
        await onboarding.signIn()

        guard case .secondFactor(let challenge) = onboarding.step else {
            Issue.record("expected second factor")
            return
        }
        await onboarding.submitSecondFactor(challenge, method: .totp, code: "111111")
        #expect(onboarding.errorMessage == "Authentication failed: The code was not accepted.")
        #expect(onboarding.step == .secondFactor(challenge))

        await onboarding.submitSecondFactor(challenge, method: .totp, code: DemoTransport.totpCode)
        guard case .finished(let profile) = onboarding.step else {
            Issue.record("expected finished")
            return
        }
        #expect(profile.username == "tfa-admin")
        #expect(profile.realm == "pve")
        #expect(fleet.environment.credentials.password(for: profile.id) == nil)
    }

    @Test func secondNodeOfSavedClusterCanBeMerged() async throws {
        let fleet = Fleet(environment: demoEnvironment())
        let first = fleet.makeOnboarding()
        first.addressText = "10.0.10.11"
        await first.submitAddress()
        first.password = "secret"
        await first.signIn()

        let second = fleet.makeOnboarding()
        second.addressText = "10.0.10.12"
        await second.submitAddress()
        second.password = "secret"
        await second.signIn()

        guard case .duplicateCluster(let existing) = second.step else {
            Issue.record("expected duplicate detection, got \(second.step)")
            return
        }
        second.mergeIntoExisting(existing)
        #expect(fleet.profiles.count == 1)
        #expect(fleet.profiles[0].addresses.map(\.host) == ["10.0.10.11", "10.0.10.12"])
    }
}

@MainActor
struct ConnectionTests {
    private func profile(addresses: [String] = ["pve.lan"]) -> ServerProfile {
        ServerProfile(name: "lab", addresses: addresses.map { ServerAddress(host: $0, port: 8006) }, username: "root", realm: "pam")
    }

    @Test func asksForPasswordWhenNoneIsSaved() async throws {
        let environment = demoEnvironment()
        let profile = profile()
        environment.profiles.save([profile])
        let fleet = Fleet(environment: environment)
        let connection = try #require(fleet.connection(for: profile.id))

        await connection.connect()
        #expect(connection.state == .needsPassword(message: nil))

        await connection.signIn(password: "pw", remember: true)
        #expect(connection.state == .connected)
        #expect(connection.snapshot?.clusterName == "homelab")
        #expect(fleet.profile(id: profile.id)?.clusterName == "homelab")
        #expect(environment.credentials.password(for: profile.id) == "pw")
    }

    @Test func connectsWithSavedPasswordAndFailsOverToNextAddress() async throws {
        let environment = demoEnvironment(unreachableHosts: ["down.lan"])
        let profile = profile(addresses: ["down.lan", "up.lan"])
        environment.profiles.save([profile])
        environment.credentials.setPassword("pw", for: profile.id)
        let fleet = Fleet(environment: environment)
        let connection = try #require(fleet.connection(for: profile.id))

        await connection.connect()
        #expect(connection.state == .connected)
        #expect(connection.currentAddress.host == "up.lan")
    }

    @Test func rejectedSavedPasswordIsForgotten() async throws {
        let environment = demoEnvironment()
        let profile = profile()
        environment.profiles.save([profile])
        environment.credentials.setPassword("wrong", for: profile.id)
        let connection = try #require(Fleet(environment: environment).connection(for: profile.id))

        await connection.connect()
        #expect(connection.state == .needsPassword(message: "The user name or password was not accepted."))
        #expect(environment.credentials.password(for: profile.id) == nil)
    }

    @Test func unreachableServerFails() async throws {
        let environment = demoEnvironment(unreachableHosts: ["pve.lan"])
        let profile = profile()
        environment.profiles.save([profile])
        environment.credentials.setPassword("pw", for: profile.id)
        let connection = try #require(Fleet(environment: environment).connection(for: profile.id))
        await connection.connect()
        #expect(connection.state == .failed("unreachable"))
    }

    @Test func demoServerConnectsWithoutPrompt() async throws {
        let fleet = Fleet(environment: .inMemory())
        let demo = fleet.addDemoServer()
        #expect(fleet.addDemoServer() == demo)
        let connection = try #require(fleet.connection(for: demo.id))
        await connection.connect()
        #expect(connection.state == .connected)
        #expect(connection.snapshot?.guests.isEmpty == false)
    }

    @Test func removingServerDeletesSecrets() async throws {
        let environment = demoEnvironment()
        let profile = profile()
        environment.profiles.save([profile])
        environment.credentials.setPassword("pw", for: profile.id)
        let fleet = Fleet(environment: environment)
        fleet.remove(profile.id)
        #expect(fleet.profiles.isEmpty)
        #expect(environment.profiles.load().isEmpty)
        #expect(environment.credentials.password(for: profile.id) == nil)
    }
}
