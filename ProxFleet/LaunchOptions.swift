import FleetCore
import Foundation
import ProxmoxCore

/// Launch arguments and environment used by UI tests, screenshots and development.
///
/// - `-demo`: add the demo cluster and open it.
/// - `-inMemory`: do not read or write saved servers.
/// - DEBUG builds only: `PROXFLEET_DEBUG_ADDRESS`, `PROXFLEET_DEBUG_USER`, `PROXFLEET_DEBUG_REALM`,
///   `PROXFLEET_DEBUG_PASSWORD` and optionally `PROXFLEET_DEBUG_FINGERPRINT` add a test server and open it.
///   See `scripts/run-simulator.sh`.
struct LaunchOptions {
    var demo: Bool
    var inMemory: Bool
    var debugServer: DebugServer?

    struct DebugServer {
        var address: ServerAddress
        var username: String
        var realm: String
        var password: String
        var fingerprint: String?
    }

    init(arguments: [String], environment: [String: String]) {
        demo = arguments.contains("-demo")
        inMemory = arguments.contains("-inMemory")
        #if DEBUG
        if let text = environment["PROXFLEET_DEBUG_ADDRESS"],
           let address = ServerAddress(parsing: text, defaultPort: ProxmoxProduct.virtualEnvironment.defaultPort),
           let password = environment["PROXFLEET_DEBUG_PASSWORD"] {
            debugServer = DebugServer(
                address: address,
                username: environment["PROXFLEET_DEBUG_USER"] ?? "root",
                realm: environment["PROXFLEET_DEBUG_REALM"] ?? "pam",
                password: password,
                fingerprint: environment["PROXFLEET_DEBUG_FINGERPRINT"].flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        #endif
    }

    /// Applies the options and returns the server to open, if any.
    @MainActor
    func apply(to fleet: Fleet) -> UUID? {
        if let debugServer {
            return fleet.addDebugServer(debugServer)
        }
        if demo {
            return fleet.addDemoServer().id
        }
        return nil
    }
}

extension Fleet {
    fileprivate func addDebugServer(_ server: LaunchOptions.DebugServer) -> UUID {
        if let existing = profiles.first(where: { $0.addresses.contains(server.address) && $0.username == server.username }) {
            return existing.id
        }
        let profile = ServerProfile(
            name: server.address.host,
            addresses: [server.address],
            username: server.username,
            realm: server.realm,
            trustedFingerprints: server.fingerprint.map { [$0] } ?? []
        )
        return addSaved(profile, password: server.password).id
    }
}
