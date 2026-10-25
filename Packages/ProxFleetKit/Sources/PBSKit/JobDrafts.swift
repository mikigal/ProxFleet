import Foundation
import ProxmoxCore

/// A rate such as `100 MiB` (per second), as the backup server writes rate limits.
public struct ByteRate: Sendable, Equatable {
    public enum Unit: String, Sendable, CaseIterable, Identifiable {
        case kib = "KiB", mib = "MiB", gib = "GiB"
        public var id: String { rawValue }
    }

    /// Empty for no limit.
    public var amount: String
    public var unit: Unit

    public init(amount: String = "", unit: Unit = .mib) {
        self.amount = amount
        self.unit = unit
    }

    /// Reads `100 MiB`, `1.5GiB` or a plain number of bytes.
    public init(parsing text: String?) {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        let suffix = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        if let unit = Unit.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(suffix) == .orderedSame }) {
            self.init(amount: String(number), unit: unit)
        } else if suffix.isEmpty, let bytes = Double(number), bytes > 0 {
            self.init(amount: (bytes / 1_048_576).formatted(.number.grouping(.never).precision(.fractionLength(0...2))), unit: .mib)
        } else {
            self.init(amount: String(number), unit: .mib)
        }
    }

    /// The setting's text, or nil without a limit.
    public var stringValue: String? {
        let amount = amount.trimmingCharacters(in: .whitespaces)
        guard let value = Double(amount), value > 0 else { return nil }
        return "\(amount) \(unit.rawValue)"
    }
}

/// One rule of a sync job's group filter: `type:vm`, `group:vm/100` or `regex:…`, optionally excluding instead.
public struct GroupFilter: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case type, group, regex
        public var id: String { rawValue }
    }

    public var kind: Kind
    public var value: String
    /// Leaves matching groups out instead of choosing them (3.2 and newer).
    public var excludes: Bool

    public init(kind: Kind, value: String, excludes: Bool = false) {
        self.kind = kind
        self.value = value
        self.excludes = excludes
    }

    public init?(parsing text: String) {
        var rest = Substring(text)
        excludes = rest.hasPrefix("exclude:")
        if excludes { rest = rest.dropFirst("exclude:".count) }
        guard let separator = rest.firstIndex(of: ":"), let kind = Kind(rawValue: String(rest[..<separator])) else { return nil }
        self.kind = kind
        value = String(rest[rest.index(after: separator)...])
    }

    public var id: String { stringValue }
    public var stringValue: String { (excludes ? "exclude:" : "") + "\(kind.rawValue):\(value)" }
}

/// IDs the web interface generates for jobs created without one: a prefix and the start of a UUID.
func generatedJobID(prefix: String) -> String {
    prefix + UUID().uuidString.lowercased().prefix(13)
}

private func text(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

private func number(_ value: Int?) -> String? {
    value.map(String.init)
}

/// Whether `id` is a valid ID of a job or remote: 3 to 32 letters, digits, dots, dashes or underscores.
private func isValidConfigID(_ id: String) -> Bool {
    id.count >= 3 && id.count <= 32 && id.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\-]*/) != nil
}

private func jobIDProblem(_ id: String) -> String? {
    let id = id.trimmingCharacters(in: .whitespaces)
    guard !id.isEmpty else { return nil }
    return isValidConfigID(id)
        ? nil : String(localized: "Use 3 to 32 letters, digits, dots, dashes or underscores, or leave it empty to generate one.")
}

// MARK: - Sync jobs

/// A sync job: pulls groups from a remote (or another local datastore) into a datastore, or pushes them to a remote.
public struct SyncJobDraft: Sendable, Equatable {
    /// Empty for a new job to get a generated ID.
    public var id = ""
    public var direction: SyncDirection = .pull
    public var store = ""
    public var namespace = ""
    /// Pull only: sync from another datastore of this server.
    public var isLocal = false
    public var remote = ""
    public var remoteStore = ""
    public var remoteNamespace = ""
    /// Pull: who owns the synced groups here. Push: whose groups are pushed.
    public var owner = ""
    public var schedule = "hourly"
    public var comment = ""
    public var removeVanished = false
    /// Namespace levels below to include; nil for all.
    public var maxDepth: Int?
    public var groupFilters: [GroupFilter] = []
    public var transferLast: Int?
    public var workerThreads: Int?
    public var resyncCorrupt = false
    public var encryptedOnly = false
    public var verifiedOnly = false
    public var runOnMount = false
    public var unmountOnDone = false
    /// Incoming for pull, outgoing for push.
    public var rateLimit = ByteRate()
    /// Push only: the key snapshots are encrypted with on the way (4.2 and newer).
    public var activeEncryptionKey = ""
    /// Keys that decrypt pulled snapshots, or the ones pushed before the active key changed.
    public var associatedKeys: [String] = []

    public init(direction: SyncDirection = .pull, store: String = "", owner: String = "") {
        self.direction = direction
        self.store = store
        self.owner = owner
    }

    /// Pulls from another datastore of this server, so there is no remote.
    public var pullsLocally: Bool { direction == .pull && isLocal }

    public init(_ job: SyncJob) {
        let values = job.values
        id = job.id
        direction = job.direction
        store = job.store
        namespace = job.namespace.path
        isLocal = job.isLocal
        remote = job.remote ?? ""
        remoteStore = job.remoteStore
        remoteNamespace = job.remoteNamespace.path
        owner = job.owner ?? ""
        schedule = job.schedule ?? ""
        comment = job.comment ?? ""
        removeVanished = job.removeVanished
        maxDepth = job.maxDepth
        groupFilters = job.groupFilters.compactMap(GroupFilter.init(parsing:))
        transferLast = job.transferLast
        workerThreads = values["worker-threads"].flatMap(Int.init)
        resyncCorrupt = values["resync-corrupt"] == "1"
        encryptedOnly = values["encrypted-only"] == "1"
        verifiedOnly = values["verified-only"] == "1"
        runOnMount = values["run-on-mount"] == "1"
        unmountOnDone = values["unmount-on-done"] == "1"
        rateLimit = ByteRate(parsing: values[direction == .pull ? "rate-in" : "rate-out"])
        activeEncryptionKey = values["active-encryption-key"] ?? ""
        associatedKeys = job.associatedKeys
    }

    /// The settings the form manages, in the same shape as `BackupServerDraft`; lists are compared separately.
    public func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        // `updateValue`: assigning nil to a `[String: String?]` subscript would drop the key, and the cleared
        // setting would not be sent.
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("ns", text(namespace))
        set("remote", pullsLocally ? nil : text(remote))
        set("remote-store", text(remoteStore))
        set("remote-ns", text(remoteNamespace))
        set("owner", text(owner))
        set("schedule", text(schedule))
        set("comment", text(comment))
        set("remove-vanished", removeVanished ? "1" : nil)
        set("max-depth", number(maxDepth))
        set("transfer-last", number(transferLast))
        set("worker-threads", number(workerThreads))
        set("resync-corrupt", resyncCorrupt && direction == .pull ? "1" : nil)
        set("encrypted-only", encryptedOnly ? "1" : nil)
        set("verified-only", verifiedOnly ? "1" : nil)
        set("run-on-mount", runOnMount ? "1" : nil)
        set("unmount-on-done", unmountOnDone ? "1" : nil)
        set(direction == .pull ? "rate-in" : "rate-out", pullsLocally ? nil : rateLimit.stringValue)
        set("active-encryption-key", direction == .push ? text(activeEncryptionKey) : nil)
        return values
    }

    public func changes(from original: SyncJobDraft, digest: String? = nil) -> BackupServerConfigUpdate {
        var update = BackupServerConfigUpdate(digest: digest)
        let old = original.serialized()
        for (key, value) in serialized() where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        if groupFilters != original.groupFilters {
            update.setList("group-filter", groupFilters.map(\.stringValue))
        }
        if associatedKeys != original.associatedKeys {
            update.setList("associated-key", associatedKeys)
        }
        return update
    }

    /// Parameters of `POST /config/sync`. The direction is sent only for push jobs, as releases before 3.3 know no
    /// direction.
    public var creationParameters: APIParameters {
        var parameters: APIParameters = ["id": .string(text(id) ?? generatedJobID(prefix: "s-")), "store": .string(store)]
        if direction == .push { parameters["sync-direction"] = "push" }
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        for filter in groupFilters { parameters.append("group-filter", .string(filter.stringValue)) }
        for key in associatedKeys { parameters.append("associated-key", .string(key)) }
        return parameters
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, let problem = jobIDProblem(id) { problems["id"] = problem }
        if store.isEmpty { problems["store"] = String(localized: "Choose the local datastore.") }
        if !pullsLocally, remote.isEmpty { problems["remote"] = String(localized: "Choose the remote.") }
        if remoteStore.isEmpty { problems["remote-store"] = String(localized: "Choose the datastore.") }
        if pullsLocally, remoteStore == store, remoteNamespace == namespace {
            problems["remote-store"] = String(localized: "A datastore cannot sync into the same namespace of itself.")
        }
        if groupFilters.contains(where: { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }) {
            problems["group-filter"] = String(localized: "Fill in every filter or remove it.")
        }
        return problems
    }
}

// MARK: - Verify jobs

public struct VerifyJobDraft: BackupServerDraft, Sendable {
    public var id = ""
    public var store = ""
    public var namespace = ""
    public var maxDepth: Int?
    public var schedule = "daily"
    /// Skip snapshots verified before; the server's default.
    public var skipVerified = true
    /// Re-verify snapshots verified longer ago than this; nil never.
    public var reverifyAfterDays: Int?
    public var comment = ""
    public var readThreads: Int?
    public var verifyThreads: Int?

    public init(store: String = "") {
        self.store = store
    }

    public init(_ job: VerifyJob) {
        id = job.id
        store = job.store
        namespace = job.namespace.path
        maxDepth = job.maxDepth
        schedule = job.schedule ?? ""
        skipVerified = job.skipVerified
        reverifyAfterDays = job.reverifyAfterDays
        comment = job.comment ?? ""
        readThreads = job.values["read-threads"].flatMap(Int.init)
        verifyThreads = job.values["verify-threads"].flatMap(Int.init)
    }

    public func serialized() -> [String: String?] {
        [
            "ns": text(namespace), "max-depth": number(maxDepth), "schedule": text(schedule),
            // Skipping is the default, so only turning it off is stored.
            "ignore-verified": skipVerified ? nil : "0",
            "outdated-after": skipVerified ? number(reverifyAfterDays) : nil,
            "comment": text(comment), "read-threads": number(readThreads), "verify-threads": number(verifyThreads),
        ]
    }

    public var creationParameters: APIParameters {
        var parameters: APIParameters = ["id": .string(text(id) ?? generatedJobID(prefix: "v-")), "store": .string(store)]
        for item in creationValues.items { parameters[item.name] = item.value }
        return parameters
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, let problem = jobIDProblem(id) { problems["id"] = problem }
        if store.isEmpty { problems["store"] = String(localized: "Choose the datastore.") }
        return problems
    }
}

// MARK: - Prune jobs

public struct PruneJobDraft: BackupServerDraft, Sendable {
    public var id = ""
    public var store = ""
    public var namespace = ""
    public var maxDepth: Int?
    public var schedule = "hourly"
    public var retention = RetentionPolicy()
    public var isEnabled = true
    public var comment = ""

    public init(store: String = "") {
        self.store = store
    }

    public init(_ job: PruneJob) {
        id = job.id
        store = job.store
        namespace = job.namespace.path
        maxDepth = job.maxDepth
        schedule = job.schedule
        retention = job.retention
        isEnabled = !job.isDisabled
        comment = job.comment ?? ""
    }

    public func serialized() -> [String: String?] {
        var values: [String: String?] = [
            "ns": text(namespace), "max-depth": number(maxDepth), "schedule": text(schedule),
            "disable": isEnabled ? nil : "1", "comment": text(comment),
        ]
        for (key, value) in retention.serialized { values.updateValue(value, forKey: key) }
        return values
    }

    /// The web interface gives prune jobs the same `s-` prefix as sync jobs.
    public var creationParameters: APIParameters {
        var parameters: APIParameters = ["id": .string(text(id) ?? generatedJobID(prefix: "s-")), "store": .string(store)]
        for item in creationValues.items { parameters[item.name] = item.value }
        return parameters
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew, let problem = jobIDProblem(id) { problems["id"] = problem }
        if store.isEmpty { problems["store"] = String(localized: "Choose the datastore.") }
        if text(schedule) == nil { problems["schedule"] = String(localized: "Prune jobs need a schedule.") }
        if retention.keepsEverything { problems["keep-last"] = String(localized: "Set at least one rule; without rules nothing is removed.") }
        return problems
    }
}

// MARK: - Remotes

public struct RemoteDraft: BackupServerDraft, Sendable {
    public var name = ""
    /// `host` or `host:port`, as the web interface takes it.
    public var address = ""
    public var authID = ""
    /// Write-only: empty keeps the stored password or token secret.
    public var password = ""
    public var fingerprint = ""
    public var comment = ""
    public var usesNodeProxy = false

    public init() {}

    public init(_ remote: BackupRemote) {
        name = remote.name
        address = remote.address
        authID = remote.authID
        fingerprint = remote.fingerprint ?? ""
        comment = remote.comment ?? ""
        usesNodeProxy = remote.usesNodeProxy
    }

    /// The host and port typed in `address`; brackets around IPv6 addresses are removed.
    var hostAndPort: (host: String, port: Int?) {
        let parsed = ServerAddress(parsing: address, defaultPort: 8007)
        guard let parsed else { return (address.trimmingCharacters(in: .whitespaces), nil) }
        return (parsed.host, parsed.port == 8007 ? nil : parsed.port)
    }

    public func serialized() -> [String: String?] {
        let (host, port) = hostAndPort
        return [
            "host": text(host), "port": number(port), "auth-id": text(authID), "fingerprint": text(fingerprint),
            "comment": text(comment), "use-node-proxy": usesNodeProxy ? "1" : nil,
        ]
    }

    public var creationParameters: APIParameters {
        var parameters: APIParameters = ["name": .string(name.trimmingCharacters(in: .whitespaces)), "password": .string(password)]
        for item in creationValues.items { parameters[item.name] = item.value }
        return parameters
    }

    /// The changes, with the password only when one was typed.
    public func update(from original: RemoteDraft, digest: String?) -> BackupServerConfigUpdate {
        var update = changes(from: original, digest: digest)
        if !password.isEmpty { update.set("password", password) }
        return update
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew {
            let name = name.trimmingCharacters(in: .whitespaces)
            if !isValidConfigID(name) {
                problems["name"] = String(localized: "Use 3 to 32 letters, digits, dots, dashes or underscores.")
            }
            if password.isEmpty { problems["password"] = String(localized: "Enter the password or the token's secret.") }
        }
        if ServerAddress(parsing: address, defaultPort: 8007) == nil { problems["host"] = String(localized: "Enter a host name or IP address, optionally with a port.") }
        if !authID.contains("@") { problems["auth-id"] = String(localized: "Enter a user or API token, e.g. sync@pbs or sync@pbs!token.") }
        return problems
    }
}

extension PBS {
    public static func createSyncJob(_ parameters: APIParameters) -> APIRequest<Nothing> {
        APIRequest(.post, "/config/sync", parameters: parameters)
    }

    public static func updateSyncJob(_ id: String, _ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/config/sync/\(escapePath(id))", parameters: update.parameters)
    }

    public static func createVerifyJob(_ parameters: APIParameters) -> APIRequest<Nothing> {
        APIRequest(.post, "/config/verify", parameters: parameters)
    }

    public static func updateVerifyJob(_ id: String, _ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/config/verify/\(escapePath(id))", parameters: update.parameters)
    }

    public static func createPruneJob(_ parameters: APIParameters) -> APIRequest<Nothing> {
        APIRequest(.post, "/config/prune", parameters: parameters)
    }

    public static func updatePruneJob(_ id: String, _ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/config/prune/\(escapePath(id))", parameters: update.parameters)
    }

    public static func createRemote(_ parameters: APIParameters) -> APIRequest<Nothing> {
        APIRequest(.post, "/config/remote", parameters: parameters)
    }

    public static func updateRemote(_ name: String, _ update: BackupServerConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/config/remote/\(escapePath(name))", parameters: update.parameters)
    }
}
