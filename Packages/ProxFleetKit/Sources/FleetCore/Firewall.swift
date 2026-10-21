import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// The firewall of the datacenter, a node, a guest or a security group: rules, options, aliases and IP sets.
@MainActor
@Observable
public final class Firewall {
    public let connection: ServerConnection
    public let scope: FirewallScope

    public private(set) var rules: [FirewallRule]?
    public private(set) var options: FirewallOptions?
    public private(set) var aliases: [FirewallAlias]?
    public private(set) var ipSets: [FirewallIPSet]?
    /// Security groups, for the datacenter and for picking a group in rules.
    public private(set) var groups: [FirewallGroup]?
    /// Entries of the IP sets opened so far, by set name.
    public private(set) var ipSetEntries: [String: [FirewallIPSetEntry]] = [:]
    public private(set) var references: [FirewallReference] = []
    public private(set) var macros: [FirewallMacro] = []
    /// Whether the datacenter firewall is on; nodes and guests only filter when it is. nil when unknown.
    public private(set) var isDatacenterEnabled: Bool?
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?

    public init(connection: ServerConnection, scope: FirewallScope) {
        self.connection = connection
        self.scope = scope
    }

    public var canModify: Bool { privileges?.contains(scope.modifyPrivilege) ?? true }
    public var isEnabled: Bool { options?.isEnabled(in: scope) ?? false }

    public func load() async {
        async let privileges = try? connection.session.privileges(on: scope.aclPath)
        do {
            rules = try await connection.session.send(PVE.firewallRules(scope))
            if scope.hasOptions {
                options = try await connection.session.send(PVE.firewallOptions(scope))
            }
            if scope.hasAliasesAndIPSets {
                aliases = try await connection.session.send(PVE.firewallAliases(scope)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                ipSets = try await connection.session.send(PVE.firewallIPSets(scope)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            if scope == .datacenter {
                groups = try await connection.session.send(PVE.firewallGroups()).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                isDatacenterEnabled = options?.isEnabled(in: .datacenter)
            } else if case .group = scope {
            } else {
                // Reading the datacenter options needs Sys.Audit on /, which guest administrators may lack.
                isDatacenterEnabled = (try? await connection.session.send(PVE.firewallOptions(.datacenter)))?.isEnabled(in: .datacenter)
            }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { self.privileges = privileges }
    }

    /// What a rule editor offers: macros, aliases and IP sets for addresses, and security groups.
    public func loadEditorChoices() async {
        if macros.isEmpty {
            macros = ((try? await connection.session.send(PVE.firewallMacros())) ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        references = ((try? await connection.session.send(PVE.firewallReferences(scope))) ?? [])
            .sorted { ($0.isIPSet ? 1 : 0, $0.scope, $0.name) < ($1.isIPSet ? 1 : 0, $1.scope, $1.name) }
        if groups == nil || scope != .datacenter {
            groups = ((try? await connection.session.send(PVE.firewallGroups())) ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// The firewall of one of the datacenter's security groups.
    public func group(_ name: String) -> Firewall {
        Firewall(connection: connection, scope: .group(name))
    }

    // MARK: - Rules

    private var rulesDigest: String? { rules?.first?.digest }

    public func createRule(_ draft: FirewallRuleDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createFirewallRule(scope, draft))
    }

    public func updateRule(_ rule: FirewallRule, _ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        var update = update
        update.digest = rule.digest
        try await perform(PVE.updateFirewallRule(scope, position: rule.position, update))
    }

    public func setEnabled(_ rule: FirewallRule, _ enabled: Bool) async throws(ConfigUpdateError) {
        var update = GuestConfigUpdate()
        update.set("enable", enabled)
        try await updateRule(rule, update)
    }

    /// Moves the rule at `position` in front of the rule now at `offset`, as SwiftUI's `onMove` reports it.
    public func moveRule(from position: Int, to offset: Int) async throws(ConfigUpdateError) {
        guard offset != position, offset != position + 1 else { return }
        // Shows the new order right away; the reload brings the server's.
        if var reordered = rules, reordered.indices.contains(position) {
            let rule = reordered.remove(at: position)
            reordered.insert(rule, at: offset > position ? offset - 1 : offset)
            rules = reordered
        }
        do {
            try await perform(PVE.moveFirewallRule(scope, position: position, to: offset, digest: rulesDigest))
        } catch {
            // Puts the rules back in the server's order.
            await load()
            throw error
        }
    }

    public func deleteRule(_ rule: FirewallRule) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteFirewallRule(scope, position: rule.position, digest: rule.digest))
    }

    // MARK: - Options

    public func saveOptions(_ update: GuestConfigUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        var update = update
        update.digest = options?.digest
        try await perform(PVE.updateFirewallOptions(scope, update))
    }

    public func setEnabled(_ enabled: Bool) async throws(ConfigUpdateError) {
        var update = GuestConfigUpdate()
        update.set("enable", enabled)
        try await saveOptions(update)
    }

    // MARK: - Aliases

    public func createAlias(name: String, cidr: String, comment: String) async throws(ConfigUpdateError) {
        try await perform(PVE.createFirewallAlias(scope, name: name, cidr: cidr, comment: comment))
    }

    public func updateAlias(_ alias: FirewallAlias, name: String, cidr: String, comment: String) async throws(ConfigUpdateError) {
        try await perform(PVE.updateFirewallAlias(scope, name: alias.name, newName: name, cidr: cidr, comment: comment, digest: alias.digest))
    }

    public func deleteAlias(_ alias: FirewallAlias) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteFirewallAlias(scope, name: alias.name))
    }

    // MARK: - IP sets

    public func saveIPSet(name: String, comment: String, renaming original: FirewallIPSet? = nil) async throws(ConfigUpdateError) {
        try await perform(PVE.saveFirewallIPSet(scope, name: name, comment: comment, renaming: original?.name))
        if let original, original.name != name {
            ipSetEntries[name] = ipSetEntries.removeValue(forKey: original.name)
        }
    }

    public func deleteIPSet(_ set: FirewallIPSet) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteFirewallIPSet(scope, name: set.name))
        ipSetEntries[set.name] = nil
    }

    public func loadEntries(of set: String) async throws(ConfigUpdateError) {
        do {
            ipSetEntries[set] = try await connection.session.send(PVE.firewallIPSetEntries(scope, set: set))
        } catch is CancellationError {
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func addEntry(to set: String, cidr: String, comment: String, excluded: Bool) async throws(ConfigUpdateError) {
        try await perform(PVE.addFirewallIPSetEntry(scope, set: set, cidr: cidr, comment: comment, excluded: excluded), reload: false)
        try await loadEntries(of: set)
    }

    public func updateEntry(_ entry: FirewallIPSetEntry, in set: String, comment: String, excluded: Bool) async throws(ConfigUpdateError) {
        try await perform(PVE.updateFirewallIPSetEntry(scope, set: set, cidr: entry.cidr, comment: comment, excluded: excluded, digest: entry.digest), reload: false)
        try await loadEntries(of: set)
    }

    public func deleteEntry(_ entry: FirewallIPSetEntry, from set: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteFirewallIPSetEntry(scope, set: set, cidr: entry.cidr), reload: false)
        try await loadEntries(of: set)
    }

    // MARK: - Security groups

    public func saveGroup(name: String, comment: String, renaming original: FirewallGroup? = nil) async throws(ConfigUpdateError) {
        try await perform(PVE.saveFirewallGroup(name: name, comment: comment, renaming: original?.name))
    }

    public func deleteGroup(_ group: FirewallGroup) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteFirewallGroup(group.name))
    }

    // MARK: - Log

    /// The last lines of the firewall log, oldest first. The server counts from the start of the file, so the
    /// first call only asks for the total.
    public func loadLog(lines count: Int = 500) async throws(ConfigUpdateError) -> [FirewallLog.Line] {
        do {
            let head = try await connection.session.send(PVE.firewallLog(scope, start: 0, limit: 1))
            guard head.total > 1 else { return head.lines }
            return try await connection.session.send(PVE.firewallLog(scope, start: max(0, head.total - count), limit: count)).lines
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    private func perform(_ request: APIRequest<Nothing>, reload: Bool = true) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            let failure = ConfigUpdateError(error)
            // Someone else changed the rules in the meantime: show the current ones.
            if failure == .conflict { await load() }
            throw failure
        }
        if reload { await load() }
    }
}
