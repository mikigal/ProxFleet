import Foundation
import ProxmoxCore

/// Answers API requests from an in-memory `DemoCluster`, in the same `extjs` format a real server uses.
///
/// Any username and password are accepted, except the password `wrong`. Usernames containing `tfa`
/// require a second factor; the TOTP code `123456` and any recovery key are accepted.
public final class DemoTransport: HTTPTransport {
    private let state: DemoState

    public init(cluster: DemoCluster = .homelab) {
        state = DemoState(cluster: cluster)
    }

    public static let totpCode = "123456"

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        // Small delay so loading states are visible, like on a real network.
        try await Task.sleep(for: .milliseconds(150))
        return await state.handle(request)
    }
}

extension DemoTransport: WebSocketTransport {
    /// Consoles connect to an in-process fake: a shell for terminals, a text-mode screen for VNC.
    public func openWebSocket(_ request: HTTPRequest, protocols: [String]) async throws -> any WebSocketConnection {
        let ticket = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "vncticket" }?.value ?? ""
        guard let console = await state.takeConsole(ticket: ticket) else {
            throw ProxmoxError.unauthorized("invalid console ticket")
        }
        return DemoConsoleServer.start(console)
    }
}

actor DemoState {
    var cluster: DemoCluster
    var tasks: [DemoTask] = []
    /// Configuration edits per VMID, applied on top of the generated configuration. nil marks a deleted key.
    var configEdits: [Int: [String: String?]] = [:]
    /// Changes of running guests that wait for a restart.
    var pendingEdits: [Int: [String: String?]] = [:]
    var configRevisions: [Int: Int] = [:]
    /// Configurations of guests created in demo mode, used instead of the generated ones.
    var createdConfigs: [Int: [String: String]] = [:]
    var downloadedTemplates: [(volume: String, availableAt: Date)] = []
    /// Snapshots per VMID, oldest first, and the snapshot each guest's current state is based on.
    var snapshots: [Int: [DemoSnapshot]] = [:]
    var currentSnapshot: [Int: String] = [:]
    var backups: [DemoBackup]
    /// ISO images, templates, snippets and uploads on `local`.
    var files: [DemoFile]
    /// Services started or stopped in demo mode, by `node/service`.
    var serviceStates: [String: Bool] = [:]
    /// Nodes rebooting until a time, and when they last booted.
    var nodeReboots: [String: Date] = [:]
    var nodeBootTimes: [String: Date] = [:]
    /// Node settings changed in demo mode, by node. Unchanged nodes use generated defaults.
    var nodeDNS: [String: [String: String]] = [:]
    var nodeHosts: [String: String] = [:]
    var nodeTimeZones: [String: String] = [:]
    var activeNetworks: [String: [DemoInterface]] = [:]
    /// Network configuration waiting for Apply Configuration, by node.
    var pendingNetworks: [String: [DemoInterface]] = [:]
    /// Disks and storage built on them, by node, once changed in demo mode.
    var diskLayouts: [String: DemoDiskLayout] = [:]
    /// The datacenter's storage definitions.
    var storageConfigs: [DemoStorageConfig]
    var backupJobs: [DemoBackupJob]
    var access = DemoAccess.sample
    /// Repositories enabled or disabled by `path#index`, and standard repositories added, by node.
    var repositoryStates: [String: [String: Bool]] = [:]
    var addedRepositories: [String: [String]] = [:]
    /// When a custom certificate was uploaded, by node.
    var customCertificates: [String: Date] = [:]
    /// Console proxies started but not yet connected, by ticket.
    var consoles: [String: DemoConsoleRequest] = [:]
    private var ticketCounter = 0
    let started = Date()

    init(cluster: DemoCluster) {
        self.cluster = cluster
        backups = Self.sampleBackups(for: cluster, now: started)
        files = Self.sampleFiles(now: started)
        storageConfigs = DemoStorageConfig.defaults(for: cluster)
        backupJobs = Self.sampleBackupJobs(for: cluster)
    }

    func takeConsole(ticket: String) -> DemoConsoleRequest? {
        consoles.removeValue(forKey: ticket)
    }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let prefix = APIFormat.pathPrefix
        let fullPath = request.url.path(percentEncoded: false)
        if fullPath == "/pve-docs/api-viewer/apidoc.js" {
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/javascript"], body: DemoAPISchema.apidoc)
        }
        guard fullPath.hasPrefix(prefix) else { return failure(404, "Not found") }
        let path = String(fullPath.dropFirst(prefix.count))
        let parameters = Self.parameters(of: request)

        switch (request.method, path) {
        case (.post, "/access/ticket"):
            return ticket(parameters)
        case (.get, "/access/domains"):
            return success([
                ["realm": "pam", "type": "pam", "comment": "Linux PAM standard authentication"],
                ["realm": "pve", "type": "pve", "comment": "Proxmox VE authentication server", "default": 1],
            ])
        default:
            break
        }

        guard request.headers["Cookie"]?.contains("PVEAuthCookie=") == true else {
            return failure(401, "No ticket")
        }

        settleNodeReboots()
        switch (request.method, path) {
        case (.get, "/version"):
            return success(["version": .string(cluster.version), "release": "9.0", "repoid": "demo"])
        case (.get, "/cluster/status"):
            return success(clusterStatus())
        case (.get, "/cluster/resources"):
            return success(resources())
        case (.get, "/nodes"):
            return success(.array(cluster.nodes.map { ["node": .string($0.name), "status": $0.isOnline ? "online" : "offline"] }))
        default:
            let user = Self.userID(fromCookie: request.headers["Cookie"]) ?? "root@pam"
            return handleGuestOrTask(request.method, path: path, parameters: parameters, user: user)
                ?? failure(501, "Method '\(request.method.rawValue) \(path)' is not available in demo mode")
        }
    }

    /// `PVEAuthCookie=PVE%3Aroot%40pam%3A...` → `root@pam`.
    private static func userID(fromCookie cookie: String?) -> String? {
        guard let cookie, let range = cookie.range(of: "PVEAuthCookie=") else { return nil }
        let ticket = String(cookie[range.upperBound...]).removingPercentEncoding ?? ""
        let parts = ticket.split(separator: ":")
        return parts.count > 1 ? String(parts[1]) : nil
    }

    // MARK: - Authentication

    private func ticket(_ parameters: [String: String]) -> HTTPResponse {
        let username = parameters["username"] ?? "root"
        let realm = parameters["realm"]
        let userid = username.contains("@") ? username : "\(username)@\(realm ?? "pam")"
        let password = parameters["password"] ?? ""

        if let challenge = parameters["tfa-challenge"] {
            guard challenge.hasPrefix("PVE:!tfa!") else { return failure(401, "authentication failure") }
            let accepted = password == "totp:\(DemoTransport.totpCode)" || (password.hasPrefix("recovery:") && password.count > 9)
            return accepted ? fullTicket(for: userid) : failure(401, "authentication failure")
        }
        if password.hasPrefix("PVE:") {
            return fullTicket(for: userid) // ticket renewal
        }
        if password == "wrong" || password.isEmpty {
            return failure(401, "authentication failure")
        }
        if username.contains("tfa") {
            let challenge = #"{"totp":true,"recovery":"available"}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return success(["username": .string(userid), "ticket": .string("PVE:!tfa!\(challenge):DEMO::sig"), "NeedTFA": 1])
        }
        return fullTicket(for: userid)
    }

    private func fullTicket(for userid: String) -> HTTPResponse {
        ticketCounter += 1
        var data: [String: JSONValue] = [
            "username": .string(userid),
            "ticket": .string("PVE:\(userid):DEMO\(ticketCounter)::demo-signature"),
            "CSRFPreventionToken": .string("DEMO\(ticketCounter):csrf"),
            "cap": [:],
        ]
        if let name = cluster.clusterName { data["clustername"] = .string(name) }
        return success(.object(data))
    }

    // MARK: - Cluster

    private func clusterStatus() -> JSONValue {
        var entries: [JSONValue] = []
        if let name = cluster.clusterName {
            entries.append([
                "type": "cluster", "id": "cluster", "name": .string(name),
                "nodes": .int(cluster.nodes.count), "quorate": .int(quorate ? 1 : 0), "version": 7,
            ])
        }
        for (index, node) in cluster.nodes.enumerated() {
            entries.append([
                "type": "node", "id": .string("node/\(node.name)"), "name": .string(node.name), "ip": .string(node.ip),
                "online": .int(node.isOnline ? 1 : 0), "local": .int(index == 0 ? 1 : 0), "nodeid": .int(index + 1), "level": "",
            ])
        }
        return .array(entries)
    }

    private var quorate: Bool {
        cluster.nodes.filter(\.isOnline).count * 2 > cluster.nodes.count
    }

    private func resources() -> JSONValue {
        let elapsed = Date().timeIntervalSince(started)
        var items: [JSONValue] = []
        let gib = 1_073_741_824.0

        for node in cluster.nodes {
            let guestsHere = cluster.guests.filter { $0.node == node.name && $0.isRunning }
            let memory = guestsHere.reduce(2.5) { $0 + $1.memoryGiB * 0.8 }
            var item: [String: JSONValue] = [
                "id": .string("node/\(node.name)"), "type": "node", "node": .string(node.name),
                "status": node.isOnline ? "online" : "offline", "maxcpu": .int(node.cores),
                "maxmem": .int(Int(Double(node.memoryGiB) * gib)), "maxdisk": .int(Int(100 * gib)),
            ]
            if node.isOnline {
                item["cpu"] = .double(Self.load(seed: node.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }, elapsed: elapsed, base: 0.12, swing: 0.08))
                item["mem"] = .int(Int(memory * gib))
                item["disk"] = .int(Int(23 * gib))
                item["uptime"] = .int(1_814_400 + Int(elapsed))
            }
            items.append(.object(item))
        }

        for guest in cluster.guests {
            let nodeOnline = cluster.nodes.first { $0.name == guest.node }?.isOnline ?? false
            let running = guest.isRunning && nodeOnline
            var item: [String: JSONValue] = [
                "id": .string("\(guest.kind.rawValue)/\(guest.vmid)"), "type": .string(guest.kind.rawValue),
                "vmid": .int(guest.vmid), "name": .string(guest.name), "node": .string(guest.node),
                "status": nodeOnline ? (running ? "running" : "stopped") : "unknown",
                "maxcpu": .int(guest.cores), "maxmem": .int(Int(guest.memoryGiB * gib)), "maxdisk": .int(Int(Double(guest.diskGiB) * gib)),
                "template": .int(guest.isTemplate ? 1 : 0),
                "cpu": .double(running ? Self.load(seed: guest.vmid, elapsed: elapsed, base: 0.08, swing: 0.06) : 0),
                "mem": .int(running ? Int(guest.memoryGiB * gib * 0.6) : 0),
                "disk": 0,
                "uptime": .int(running ? uptime(of: guest) : 0),
            ]
            if !guest.tags.isEmpty { item["tags"] = .string(guest.tags.joined(separator: ";")) }
            items.append(.object(item))
        }

        for node in cluster.nodes {
            for config in storageConfigs where config.isAvailable(on: node.name) {
                let usage = config.usageGiB
                items.append([
                    "id": .string("storage/\(node.name)/\(config.id)"), "type": "storage", "storage": .string(config.id),
                    "node": .string(node.name), "status": node.isOnline ? "available" : "unknown", "plugintype": .string(config.type),
                    "content": .string(config.content.joined(separator: ",")), "shared": .int(config.isShared ? 1 : 0),
                    "maxdisk": .int(Int(usage.total * gib)), "disk": .int(Int(usage.used * gib)),
                ])
            }
        }
        return .array(items)
    }

    /// Smoothly varying fake CPU load so the UI looks alive.
    static func load(seed: Int, elapsed: TimeInterval, base: Double, swing: Double) -> Double {
        let phase = Double(abs(seed) % 360) * .pi / 180
        return max(0, base + swing * sin(elapsed / 7 + phase))
    }

    // MARK: - Helpers

    func success(_ data: JSONValue) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: JSONValue.object(["data": data, "success": 1]).encoded())
    }

    func failure(_ status: Int, _ message: String) -> HTTPResponse {
        let body: JSONValue = ["data": nil, "success": 0, "status": .int(status), "message": .string(message)]
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body.encoded())
    }

    private static func parameters(of request: HTTPRequest) -> [String: String] {
        let encoded = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? request.url.query(percentEncoded: true) ?? ""
        var result: [String: String] = [:]
        for pair in encoded.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }
}
