import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// Drives the "Add Server" flow: address, certificate confirmation, credentials and second factor.
@MainActor
@Observable
public final class ServerOnboarding {
    public enum Step: Equatable {
        case address
        case certificate(CertificateDetails)
        case credentials
        case secondFactor(SecondFactorChallenge)
        /// The server runs a Proxmox VE release older than ProxFleet supports; the user may add it anyway.
        case unsupportedRelease(version: String)
        /// The server belongs to a cluster that is already saved under another entry.
        case duplicateCluster(existing: ServerProfile)
        case finished(ServerProfile)
    }

    public private(set) var step: Step = .address
    public private(set) var isWorking = false
    public var errorMessage: String?

    public var addressText = ""
    public private(set) var realms: [Realm] = []
    public var realm = "pam"
    public var username = "root"
    public var password = ""
    public var rememberPassword = true

    private let fleet: Fleet
    private let product: ProxmoxProduct = .virtualEnvironment
    private var address: ServerAddress?
    private var transport: (any HTTPTransport)?
    private var session: ProxmoxSession?
    private var trustedFingerprints: [String] = []
    private var ticket: AuthTicket?
    /// Name of the node we signed in to, used as the default name of a standalone server.
    private var nodeName: String?

    init(fleet: Fleet) {
        self.fleet = fleet
    }

    public var canSubmitAddress: Bool {
        ServerAddress(parsing: addressText, defaultPort: product.defaultPort) != nil
    }

    public var canSignIn: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    // MARK: - Steps

    /// Connects to the address and loads the login realms.
    public func submitAddress() async {
        guard let parsed = ServerAddress(parsing: addressText, defaultPort: product.defaultPort) else {
            errorMessage = "Enter a host name or IP address, optionally with a port."
            return
        }
        if parsed.host.lowercased() == Fleet.demoHost {
            step = .finished(fleet.addDemoServer())
            return
        }
        if parsed != address {
            address = parsed
            trustedFingerprints = []
            let draft = draftProfile(address: parsed)
            let transport = fleet.environment.makeTransport(draft)
            self.transport = transport
            session = ProxmoxSession(address: parsed, product: product, transport: transport)
        }
        await loadRealms()
    }

    public func trustCertificate(_ certificate: CertificateDetails) async {
        (transport as? any CertificatePinning)?.pin(certificate.sha256Fingerprint)
        trustedFingerprints.append(certificate.sha256Fingerprint)
        await loadRealms()
    }

    public func signIn() async {
        guard let session else { return }
        await run {
            let user = self.username.trimmingCharacters(in: .whitespaces)
            switch try await session.login(username: user, password: self.password, realm: self.realm) {
            case .authenticated(let ticket):
                await self.didAuthenticate(ticket)
            case .needsSecondFactor(let challenge):
                self.step = .secondFactor(challenge)
            }
        }
    }

    public func submitSecondFactor(_ challenge: SecondFactorChallenge, method: SecondFactorMethod, code: String) async {
        guard let session else { return }
        await run {
            do {
                let ticket = try await session.completeLogin(challenge, method: method, code: code)
                await self.didAuthenticate(ticket)
            } catch ProxmoxError.unauthorized {
                throw ProxmoxError.unauthorized("The code was not accepted.")
            }
        }
    }

    /// Adds this address to the existing entry of the same cluster instead of creating a second entry.
    public func mergeIntoExisting(_ existing: ServerProfile) {
        guard let address else { return }
        var merged = existing
        if !merged.addresses.contains(address) { merged.addresses.append(address) }
        for fingerprint in trustedFingerprints where !merged.trustedFingerprints.contains(fingerprint) {
            merged.trustedFingerprints.append(fingerprint)
        }
        fleet.update(merged)
        step = .finished(merged)
    }

    /// Adds the server although its release is older than ProxFleet supports.
    public func addUnsupportedRelease() {
        guard let ticket else { return }
        proceed(with: ticket)
    }

    public func addSeparately() {
        guard let ticket else { return }
        save(ticket)
    }

    public func goBack() {
        errorMessage = nil
        switch step {
        case .certificate, .credentials: step = .address
        case .secondFactor, .unsupportedRelease, .duplicateCluster: step = .credentials
        case .address, .finished: break
        }
    }

    // MARK: - Internals

    private func loadRealms() async {
        guard let session else { return }
        await run {
            do {
                let realms = try await session.sendUnauthenticated(ProxmoxAccess.realms())
                self.realms = realms
                if !realms.contains(where: { $0.realm == self.realm }) {
                    self.realm = realms.first(where: \.isDefault)?.realm ?? realms.first?.realm ?? "pam"
                }
                self.step = .credentials
            } catch ProxmoxError.untrustedCertificate(let details) {
                self.step = .certificate(details)
            } catch ProxmoxError.api(let status, _, _) where status == 404 || status == 501 {
                self.step = .address
                throw ProxmoxError.invalidResponse("no Proxmox VE API at this address, check the port")
            } catch ProxmoxError.invalidResponse {
                self.step = .address
                throw ProxmoxError.invalidResponse("no Proxmox VE API at this address, check the port")
            } catch {
                // Errors are shown on the address step, where the user can correct the input.
                self.step = .address
                throw error
            }
        }
    }

    private func didAuthenticate(_ ticket: AuthTicket) async {
        self.ticket = ticket
        if ticket.clusterName == nil, let session {
            let status = try? await session.send(PVE.clusterStatus())
            nodeName = status?.first { $0.kind == .node && $0.isLocal == true }?.name
        }
        // Older releases may work in parts, so the user decides after a warning.
        if let version = try? await session?.send(PVE.version()), !version.isSupported {
            step = .unsupportedRelease(version: version.version)
            return
        }
        proceed(with: ticket)
    }

    private func proceed(with ticket: AuthTicket) {
        if let cluster = ticket.clusterName, let existing = fleet.profile(inCluster: cluster) {
            step = .duplicateCluster(existing: existing)
            return
        }
        save(ticket)
    }

    private func save(_ ticket: AuthTicket) {
        guard let address else { return }
        var profile = draftProfile(address: address)
        profile.clusterName = ticket.clusterName
        profile.name = ticket.clusterName ?? nodeName ?? address.host
        fleet.environment.credentials.setTicket(ticket, for: profile.id)
        if rememberPassword {
            fleet.environment.credentials.setPassword(password, for: profile.id)
        }
        fleet.add(profile, session: session, transport: transport)
        password = ""
        step = .finished(profile)
    }

    private func draftProfile(address: ServerAddress) -> ServerProfile {
        let user = username.trimmingCharacters(in: .whitespaces)
        return ServerProfile(
            name: address.host,
            product: product,
            addresses: [address],
            username: user.split(separator: "@").first.map(String.init) ?? user,
            realm: user.contains("@") ? String(user.split(separator: "@").last ?? "") : realm,
            trustedFingerprints: trustedFingerprints
        )
    }

    private func run(_ work: @MainActor () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch let error as ProxmoxError {
            errorMessage = error.localizedDescription
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
