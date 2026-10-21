import Foundation
import ProxmoxCore

/// A storage definition in demo mode, as in `storage.cfg`.
struct DemoStorageConfig: Sendable {
    var id: String
    var type: String
    var values: [String: String]

    var content: [String] { (values["content"] ?? "").split(separator: ",").map(String.init) }
    var isEnabled: Bool { values["disable"] != "1" }
    var isShared: Bool { ["nfs", "cifs", "pbs", "rbd", "cephfs"].contains(type) || values["shared"] == "1" }

    func isAvailable(on node: String) -> Bool {
        guard isEnabled else { return false }
        let nodes = (values["nodes"] ?? "").split(separator: ",").map(String.init)
        return nodes.isEmpty || nodes.contains(node)
    }

    /// Fake sizes in GiB, stable per storage.
    var usageGiB: (total: Double, used: Double) {
        switch id {
        case "local": (100, 23)
        case "local-lvm": (800, 310)
        default: Self.fakeUsage(id: id, type: type)
        }
    }

    private static func fakeUsage(id: String, type: String) -> (total: Double, used: Double) {
        let seed = Double(id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 50)
        return type == "pbs" ? (4000, 1200 + seed * 10) : (2000, 400 + seed * 12)
    }

    static func defaults(for cluster: DemoCluster) -> [DemoStorageConfig] {
        var configs = [
            DemoStorageConfig(id: "local", type: "dir", values: ["path": "/var/lib/vz", "content": "iso,vztmpl,backup,snippets,import"]),
            DemoStorageConfig(id: "local-lvm", type: "lvmthin", values: ["vgname": "pve", "thinpool": "data", "content": "images,rootdir"]),
        ]
        if cluster.clusterName != nil {
            configs += [
                DemoStorageConfig(id: "nas", type: "nfs", values: [
                    "server": "10.0.10.5", "export": "/mnt/tank/proxmox", "content": "iso,backup", "options": "vers=4.2",
                    "prune-backups": "keep-daily=7,keep-weekly=4,keep-monthly=6",
                ]),
                DemoStorageConfig(id: "pbs", type: "pbs", values: [
                    "server": "10.0.10.6", "datastore": "main", "username": "backup@pbs", "content": "backup",
                    "fingerprint": "6A:21:8B:4F:C2:93:1D:E0:57:AA:3C:66:0B:D4:91:7F:E2:48:C5:10:9D:73:2B:FA:84:06:CE:51:39:E7:12:AD",
                    "prune-backups": "keep-last=3,keep-daily=14",
                ]),
            ]
        }
        return configs
    }
}

/// `/storage` (the datacenter's storage definitions) and the node `scan` routes in demo mode.
extension DemoState {
    private static let editableKeys: Set<String> = [
        "content", "nodes", "disable", "shared", "prune-backups", "max-protected-backups", "options", "subdir", "domain",
        "username", "password", "smbversion", "namespace", "fingerprint", "port", "sparse", "blocksize",
    ]
    private static let creationKeys: Set<String> = editableKeys.union(["path", "server", "export", "share", "datastore", "vgname", "thinpool", "pool"])

    func storageDigest() -> String {
        let text = storageConfigs.map { "\($0.id)\($0.type)\($0.values.sorted { $0.key < $1.key })" }.joined()
        return String(format: "%016llx", text.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 })
    }

    private func configJSON(_ config: DemoStorageConfig) -> JSONValue {
        var object = config.values.filter { $0.key != "password" }.mapValues { JSONValue.string($0) }
        object["storage"] = .string(config.id)
        object["type"] = .string(config.type)
        object["digest"] = .string(storageDigest())
        if config.values["disable"] == "1" { object["disable"] = 1 }
        return .object(object)
    }

    /// Routes below `/storage`. nil for other paths.
    func handleStorageConfig(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard parts.first == "storage", parts.count <= 2 else { return nil }
        if method != .get, !privileges(for: user).contains("Datastore.Allocate") {
            return failure(403, "Permission check failed (/storage, Datastore.Allocate)")
        }
        switch (method, parts.count) {
        case (.get, 1):
            return success(.array(storageConfigs.map(configJSON)))
        case (.get, 2):
            guard let config = storageConfigs.first(where: { $0.id == parts[1] }) else { return failure(500, "storage '\(parts[1])' does not exist") }
            return success(configJSON(config))
        case (.post, 1):
            guard let id = parameters["storage"], !id.isEmpty else { return fieldFailure(["storage": "property is missing and it is not optional"]) }
            guard let type = parameters["type"] else { return fieldFailure(["type": "property is missing and it is not optional"]) }
            guard !storageConfigs.contains(where: { $0.id == id }) else { return failure(500, "create storage failed: storage ID '\(id)' already defined") }
            let required: [String: [String]] = [
                "dir": ["path"], "btrfs": ["path"], "nfs": ["server", "export"], "cifs": ["server", "share"],
                "pbs": ["server", "datastore", "username", "password"], "lvm": ["vgname"], "lvmthin": ["vgname", "thinpool"], "zfspool": ["pool"],
            ]
            guard let keys = required[type] else { return fieldFailure(["type": "type '\(type)' is not supported in demo mode"]) }
            var missing: [String: String] = [:]
            for key in keys where (parameters[key] ?? "").isEmpty { missing[key] = "property is missing and it is not optional" }
            if !missing.isEmpty { return fieldFailure(missing) }
            if type == "pbs", parameters["password"] == "wrong" { return failure(500, "create storage failed: pbs error: authentication failed") }
            var values: [String: String] = [:]
            for (key, value) in parameters where Self.creationKeys.contains(key) { values[key] = value }
            if values["content"] == nil { values["content"] = type == "pbs" ? "backup" : ["lvm", "lvmthin", "zfspool"].contains(type) ? "images,rootdir" : "images,iso,vztmpl,backup,rootdir,snippets" }
            storageConfigs.append(DemoStorageConfig(id: id, type: type, values: values))
            return success(["storage": .string(id), "type": .string(type)])
        case (.put, 2):
            guard let index = storageConfigs.firstIndex(where: { $0.id == parts[1] }) else { return failure(500, "storage '\(parts[1])' does not exist") }
            if let digest = parameters["digest"], digest != storageDigest() {
                return failure(500, "update storage failed: detected modified configuration - file changed by other user? Try again.")
            }
            for key in parameters.keys where !Self.editableKeys.contains(key) && !["digest", "delete"].contains(key) {
                return fieldFailure([key: "property is not defined in schema and the schema does not allow additional properties"])
            }
            for key in (parameters["delete"] ?? "").split(separator: ",") { storageConfigs[index].values[String(key)] = nil }
            for (key, value) in parameters where Self.editableKeys.contains(key) { storageConfigs[index].values[key] = value }
            return success(["storage": .string(parts[1]), "type": .string(storageConfigs[index].type)])
        case (.delete, 2):
            guard let index = storageConfigs.firstIndex(where: { $0.id == parts[1] }) else { return failure(500, "storage '\(parts[1])' does not exist") }
            storageConfigs.remove(at: index)
            return success(nil)
        default:
            return nil
        }
    }

    /// `GET /nodes/{node}/scan/...`. nil for other paths.
    func handleScan(node: String, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        guard rest.count == 2, rest[0] == "scan" else { return nil }
        switch rest[1] {
        case "nfs":
            guard parameters["server"] == "10.0.10.5" else {
                return failure(500, "command '/sbin/showmount --no-headers --exports \(parameters["server"] ?? "")' failed: exit code 1")
            }
            return success([["path": "/mnt/tank/proxmox", "options": "10.0.10.0/24"], ["path": "/mnt/tank/media", "options": "10.0.10.0/24"]])
        case "cifs":
            return success([["share": "backups", "description": "Backup share"], ["share": "isos", "description": "Installation media"]])
        case "pbs":
            guard parameters["password"] == "secret" || parameters["password"]?.hasPrefix("PBS") == true else {
                return failure(500, "pbs error: authentication failed")
            }
            return success([["store": "main", "comment": "Daily backups"], ["store": "offsite", "comment": ""]])
        case "lvm":
            let groups = diskLayout(node).volumeGroups.map { group -> JSONValue in
                ["vg": .string(group.name), "size": .int(group.sizeGiB * 1_073_741_824), "free": .int(group.freeGiB * 1_073_741_824)]
            }
            return success(.array(groups))
        case "lvmthin":
            return success(.array(diskLayout(node).thinPools.filter { $0.volumeGroup == parameters["vg"] }.map { pool -> JSONValue in
                ["lv": .string(pool.name), "vg": .string(pool.volumeGroup), "lv_size": .int(pool.sizeGiB * 1_073_741_824)]
            }))
        case "zfs":
            return success(.array(diskLayout(node).pools.map { pool -> JSONValue in
                ["pool": .string(pool.name), "size": .int(pool.sizeGiB * 1_073_741_824), "free": .int(Int((Double(pool.sizeGiB) - pool.usedGiB) * 1_073_741_824))]
            }))
        default:
            return nil
        }
    }

    /// `GET /nodes/{node}/storage`: the enabled storages of the node, optionally with a content type.
    func nodeStorageList(node: String, content: String?) -> HTTPResponse {
        let gib = 1_073_741_824.0
        return success(.array(storageConfigs.filter { $0.isAvailable(on: node) && (content == nil || content == "" || $0.content.contains(content!)) }.map { config in
            let usage = config.usageGiB
            return [
                "storage": .string(config.id), "type": .string(config.type), "content": .string(config.content.joined(separator: ",")),
                "active": 1, "enabled": 1, "shared": .int(config.isShared ? 1 : 0),
                "total": .int(Int(usage.total * gib)), "used": .int(Int(usage.used * gib)), "avail": .int(Int((usage.total - usage.used) * gib)),
                // File-based storages hold images in several formats; block storages only raw ones.
                "formats": ["supported": ["dir", "nfs", "cifs", "cephfs", "btrfs"].contains(config.type) ? ["raw", "qcow2", "vmdk"] : ["raw"], "default": "raw"],
            ]
        }))
    }
}
