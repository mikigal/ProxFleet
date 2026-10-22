import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// Notification targets and matchers, and the datacenter options (`datacenter.cfg`).
@MainActor
@Observable
public final class DatacenterSettings {
    public let connection: ServerConnection

    public private(set) var targets: [NotificationTarget]?
    public private(set) var matchers: [NotificationMatcher]?
    public private(set) var fieldValues: [MatcherFieldValue] = []
    public private(set) var options: DatacenterOptionsConfig?
    /// Privileges on `/mapping/notifications` and on `/`.
    public private(set) var notificationPrivileges: Set<String>?
    public private(set) var rootPrivileges: Set<String>?
    public private(set) var loadError: String?

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    /// Changing notifications needs `Mapping.Modify`; endpoints also need `Sys.Modify` or `Sys.AccessNetwork` on `/`.
    public var canModifyNotifications: Bool { notificationPrivileges?.contains("Mapping.Modify") ?? true }
    public var canModifyEndpoints: Bool {
        canModifyNotifications && (rootPrivileges.map { $0.contains("Sys.Modify") || $0.contains("Sys.AccessNetwork") } ?? true)
    }
    /// Changing options needs `Sys.Modify` on `/`.
    public var canModifyOptions: Bool { rootPrivileges?.contains("Sys.Modify") ?? true }

    public func loadNotifications() async {
        async let privileges = try? connection.session.privileges(on: "/mapping/notifications")
        async let root = try? connection.session.privileges(on: "/")
        do {
            targets = try await connection.session.send(PVE.notificationTargets()).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            matchers = try await connection.session.send(PVE.notificationMatchers()).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            fieldValues = (try? await connection.session.send(PVE.matcherFieldValues())) ?? []
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { notificationPrivileges = privileges }
        if let root = await root { rootPrivileges = root }
    }

    public func loadOptions() async {
        async let root = try? connection.session.privileges(on: "/")
        do {
            options = try await connection.session.send(PVE.datacenterOptions())
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let root = await root { rootPrivileges = root }
    }

    // MARK: - Notifications

    public func endpointConfig(_ type: NotificationEndpointType, name: String) async throws(ConfigUpdateError) -> NotificationConfig {
        do {
            return try await connection.session.send(PVE.notificationEndpoint(type, name: name))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func createEndpoint(_ draft: NotificationEndpointDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createNotificationEndpoint(draft))
    }

    public func updateEndpoint(_ type: NotificationEndpointType, name: String, _ changes: APIParameters, digest: String?) async throws(ConfigUpdateError) {
        guard !changes.isEmpty else { return }
        try await perform(PVE.updateNotificationEndpoint(type, name: name, changes, digest: digest))
    }

    public func deleteEndpoint(_ target: NotificationTarget) async throws(ConfigUpdateError) {
        guard let type = target.endpointType else { return }
        try await perform(PVE.deleteNotificationEndpoint(type, name: target.name))
    }

    /// Sends a test notification; throws with the server's reason when it cannot be delivered.
    public func test(_ target: String) async throws(ConfigUpdateError) {
        try await perform(PVE.testNotificationTarget(target), reload: false)
    }

    public func createMatcher(_ draft: NotificationMatcherDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createNotificationMatcher(draft))
    }

    public func updateMatcher(_ name: String, _ changes: APIParameters, digest: String?) async throws(ConfigUpdateError) {
        guard !changes.isEmpty else { return }
        try await perform(PVE.updateNotificationMatcher(name, changes, digest: digest))
    }

    public func deleteMatcher(_ name: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteNotificationMatcher(name))
    }

    // MARK: - Options

    public func updateOptions(_ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        do {
            _ = try await connection.session.send(PVE.updateDatacenterOptions(update))
        } catch {
            throw ConfigUpdateError(error)
        }
        await loadOptions()
    }

    private func perform(_ request: APIRequest<Nothing>, reload: Bool = true) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
        if reload { await loadNotifications() }
    }
}
