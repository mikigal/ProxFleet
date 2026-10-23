import Foundation
import ProxmoxCore

/// Ceph in demo mode. The home lab cluster runs it, with pve3 down; the standalone node has not installed it yet.
struct DemoCeph: Sendable {
    struct OSD: Sendable {
        var id: Int
        var host: String
        var deviceClass: String
        var sizeGiB: Double
        var usedGiB: Double
        var isIn = true
        var isStopped = false
    }

    struct Pool: Sendable {
        var name: String
        var size = 3
        var minSize = 2
        var pgNum = 32
        var pgNumMin: Int?
        var autoscale = "on"
        var application: String
        var usedGiB: Double
        var targetRatio: Double?
        var targetSize: Int64?
    }

    var installed: Set<String>
    var initialized: Bool
    var network = ""
    var monitors: [String] = []
    var managers: [String] = []
    var metadataServers: [String] = []
    /// Services stopped in demo mode, like `mon.pve1`.
    var stopped: Set<String> = []
    var osds: [OSD] = []
    var pools: [Pool] = []
    var fileSystems: [String] = []
    var flags: Set<String> = []

    static func sample(for cluster: DemoCluster) -> DemoCeph {
        guard cluster.clusterName != nil else { return DemoCeph(installed: [], initialized: false) }
        return DemoCeph(
            installed: Set(cluster.nodes.map(\.name)), initialized: true, network: "10.0.10.0/24",
            monitors: ["pve1", "pve2", "pve3"], managers: ["pve1", "pve2"], metadataServers: ["pve1", "pve2"],
            osds: [
                OSD(id: 0, host: "pve1", deviceClass: "nvme", sizeGiB: 931, usedGiB: 402),
                OSD(id: 1, host: "pve1", deviceClass: "nvme", sizeGiB: 931, usedGiB: 389),
                OSD(id: 2, host: "pve2", deviceClass: "ssd", sizeGiB: 894, usedGiB: 371),
                OSD(id: 3, host: "pve2", deviceClass: "ssd", sizeGiB: 894, usedGiB: 366),
                OSD(id: 4, host: "pve3", deviceClass: "ssd", sizeGiB: 894, usedGiB: 360),
                OSD(id: 5, host: "pve3", deviceClass: "ssd", sizeGiB: 894, usedGiB: 352),
            ],
            pools: [
                Pool(name: ".mgr", pgNum: 1, application: "mgr", usedGiB: 0.02),
                Pool(name: "vm-pool", pgNum: 128, application: "rbd", usedGiB: 612, targetRatio: 0.8),
                Pool(name: "cephfs_data", pgNum: 64, application: "cephfs", usedGiB: 118),
                Pool(name: "cephfs_metadata", pgNum: 16, pgNumMin: 16, application: "cephfs", usedGiB: 0.4),
            ],
            fileSystems: ["cephfs"]
        )
    }
}

extension DemoState {
    private static let gib = 1_073_741_824.0
    private static let version = "ceph version 20.2.4 (a12e197e4613a9d6be90e8fb073ac4fc3656aee2) tentacle (stable)"

    private func isOnline(_ node: String) -> Bool {
        cluster.nodes.first { $0.name == node }?.isOnline ?? false
    }

    /// The shell's `ceph_install` command installs Ceph in demo mode right away.
    func noteCephInstall(on node: String) {
        ceph.installed.insert(node)
    }

    /// Routes below `/nodes/{node}/ceph` and `/cluster/ceph`. nil for other paths.
    func handleCeph(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        let rest: [String]
        let node: String
        if parts.count >= 2, parts[0] == "cluster", parts[1] == "ceph" {
            node = cluster.nodes.first(where: \.isOnline)?.name ?? "pve"
            rest = Array(parts.dropFirst(2))
            if rest == ["flags"] { return cephFlags(method, parameters: parameters, user: user) }
            if rest == ["status"] { return cephStatus(node: node) }
            return nil
        }
        guard parts.count >= 3, parts[0] == "nodes", parts[2] == "ceph" else { return nil }
        node = parts[1]
        rest = Array(parts.dropFirst(3))
        guard isOnline(node) else { return failure(595, "Connection refused: node '\(node)' seems to be offline") }
        if method != .get, !privileges(for: user).contains("Sys.Modify") { return failure(403, "Permission check failed (/, Sys.Modify)") }

        if rest == ["releases"] {
            return success([
                ["release": "squid", "version": "19.2", "available": 1, "is-default": 0, "unsupported": 0],
                ["release": "tentacle", "version": "20.2", "available": 1, "is-default": 1, "unsupported": 0],
            ])
        }
        guard ceph.installed.contains(node) else { return failure(500, "binary not installed: /usr/bin/ceph-mon") }
        if method == .post, rest == ["init"] {
            guard let network = parameters["network"], !network.isEmpty else { return fieldFailure(["network": "property is missing and it is not optional"]) }
            ceph.initialized = true
            ceph.network = network
            return success(nil)
        }
        guard ceph.initialized else {
            return failure(500, "pveceph configuration not initialized - missing '/etc/pve/ceph.conf', missing '/etc/pve/ceph'")
        }
        // Creating the first monitor is the only thing that works before one runs.
        if ceph.monitors.isEmpty, !(method == .post && rest.first == "mon") {
            if rest.isEmpty || ["status", "mon", "mgr", "mds", "osd", "pool", "fs"].contains(rest[0]) { return failure(500, "rados_connect failed - No such file or directory") }
        }

        switch (method, rest) {
        case (.get, ["status"]):
            return cephStatus(node: node)
        case (.get, let path) where path.count == 1 && ["mon", "mgr", "mds"].contains(path[0]):
            return success(.array(cephServices(path[0])))
        case (.post, let path) where path.count == 2 && ["mon", "mgr", "mds"].contains(path[0]):
            return createCephService(path[0], id: path[1], node: node, user: user)
        case (.delete, let path) where path.count == 2 && ["mon", "mgr", "mds"].contains(path[0]):
            return destroyCephService(path[0], id: path[1], node: node, user: user)
        case (.post, let path) where path.count == 1 && ["start", "stop", "restart"].contains(path[0]):
            return cephServiceAction(path[0], service: parameters["service"] ?? "", node: node, user: user)
        case (.get, ["cmd-safety"]):
            let stopping = parameters["service"] == "osd" && parameters["action"] == "stop"
            let degraded = ceph.osds.contains { !$0.isIn || $0.isStopped || !isOnline($0.host) }
            return success(stopping && degraded
                ? ["safe": 0, "status": "unsafe to stop osd(s) at this time (24 PGs are or would become offline)"]
                : ["safe": 1])
        case (.get, ["osd"]):
            return success(osdTree())
        case (.post, ["osd"]):
            return createOSD(node: node, parameters: parameters, user: user)
        case (.delete, let path) where path.count == 2 && path[0] == "osd":
            return destroyOSD(Int(path[1]) ?? -1, node: node, user: user)
        case (.post, let path) where path.count == 3 && path[0] == "osd":
            guard let index = ceph.osds.firstIndex(where: { String($0.id) == path[1] }) else { return failure(500, "osd.\(path[1]) does not exist") }
            switch path[2] {
            case "in": ceph.osds[index].isIn = true
            case "out": ceph.osds[index].isIn = false
            case "scrub": break
            default: return nil
            }
            return success(nil)
        case (.get, ["pool"]):
            return success(.array(ceph.pools.enumerated().map { poolJSON($0.element, number: $0.offset + 1) }))
        case (.post, ["pool"]):
            return createCephPool(parameters, node: node, user: user)
        case (.put, let path) where path.count == 2 && path[0] == "pool":
            return updateCephPool(path[1], parameters: parameters, node: node, user: user)
        case (.delete, let path) where path.count == 2 && path[0] == "pool":
            guard ceph.pools.contains(where: { $0.name == path[1] }) else { return failure(500, "pool '\(path[1])' does not exist") }
            if ceph.fileSystems.contains(where: { path[1].hasPrefix($0 + "_") }) { return failure(500, "pool '\(path[1])' is in use by a CephFS") }
            ceph.pools.removeAll { $0.name == path[1] }
            if parameters["remove_storages"] == "1" { storageConfigs.removeAll { $0.type == "rbd" && $0.values["pool"] == path[1] } }
            return startTask(node: node, type: "cephdestroypool", objectID: path[1], user: user, duration: 2)
        case (.get, ["rules"]):
            return success([["name": "replicated_rule"]])
        case (.get, ["fs"]):
            return success(.array(ceph.fileSystems.map { name in
                ["name": .string(name), "metadata_pool": .string("\(name)_metadata"), "data_pool": .string("\(name)_data"), "data_pools": [.string("\(name)_data")]]
            }))
        case (.post, let path) where path.count == 2 && path[0] == "fs":
            return createFileSystem(path[1], parameters: parameters, node: node, user: user)
        case (.get, ["cfg", "raw"]):
            return success(.string(cephConfigFile()))
        case (.get, ["cfg", "db"]):
            return success([
                ["section": "global", "name": "osd_pool_default_pg_autoscale_mode", "value": "on", "level": "advanced", "mask": "", "can_update_at_runtime": 1],
                ["section": "mon", "name": "auth_allow_insecure_global_id_reclaim", "value": "false", "level": "advanced", "mask": "", "can_update_at_runtime": 1],
            ])
        case (.get, ["crush"]):
            return success(.string(crushMap()))
        case (.get, ["log"]):
            return success(.array(cephLog().enumerated().map { ["n": .int($0.offset + 1), "t": .string($0.element)] }))
        default:
            return nil
        }
    }

    // MARK: - Status

    private func cephStatus(node: String) -> HTTPResponse {
        guard ceph.installed.contains(node) || node == cluster.nodes.first(where: \.isOnline)?.name else {
            return failure(500, "binary not installed: /usr/bin/ceph-mon")
        }
        let upMonitors = ceph.monitors.filter { isOnline($0) && !ceph.stopped.contains("mon.\($0)") }
        let upOSDs = ceph.osds.filter { isOnline($0.host) && !$0.isStopped }
        let inOSDs = ceph.osds.filter(\.isIn)
        let hosts = Set(upOSDs.map(\.host))
        var checks: [String: JSONValue] = [:]
        func check(_ code: String, _ severity: String, _ message: String, _ details: [String] = []) {
            checks[code] = [
                "severity": .string(severity), "summary": ["message": .string(message), "count": .int(max(details.count, 1))],
                "detail": .array(details.map { ["message": .string($0)] }), "muted": 0,
            ]
        }
        if upMonitors.count < ceph.monitors.count {
            let down = ceph.monitors.filter { !upMonitors.contains($0) }
            check("MON_DOWN", "HEALTH_WARN", "\(down.count)/\(ceph.monitors.count) mons down, quorum \(upMonitors.joined(separator: ","))", down.map { "mon.\($0) (rank \(ceph.monitors.firstIndex(of: $0) ?? 0)) is down (out of quorum)" })
        }
        let downOSDs = ceph.osds.filter { !isOnline($0.host) || $0.isStopped }
        if !downOSDs.isEmpty {
            check("OSD_DOWN", "HEALTH_WARN", "\(downOSDs.count) osds down", downOSDs.map { "osd.\($0.id) (root=default,host=\($0.host)) is down" })
            let downHosts = Set(downOSDs.map(\.host)).filter { host in !isOnline(host) }
            if !downHosts.isEmpty { check("OSD_HOST_DOWN", "HEALTH_WARN", "\(downHosts.count) host (\(downOSDs.count) osds) down") }
        }
        if !ceph.flags.isEmpty { check("OSDMAP_FLAGS", "HEALTH_WARN", "\(ceph.flags.sorted().joined(separator: ",")) flag(s) set") }
        if !ceph.osds.isEmpty, ceph.osds.count < 3 { check("TOO_FEW_OSDS", "HEALTH_WARN", "OSD count \(ceph.osds.count) < osd_pool_default_size 3") }
        let degraded = !ceph.pools.isEmpty && hosts.count < (ceph.pools.map(\.size).max() ?? 3)
        let pgs = ceph.pools.map(\.pgNum).reduce(0, +)
        if degraded, pgs > 0 {
            check("PG_DEGRADED", "HEALTH_WARN", "Degraded data redundancy: 33.333% objects degraded, \(pgs - ceph.pools.count) pgs degraded, \(pgs) pgs undersized")
        }
        let usedGiB = ceph.osds.map(\.usedGiB).reduce(0, +)
        let totalGiB = ceph.osds.map(\.sizeGiB).reduce(0, +)
        var pgStates: [JSONValue] = []
        if pgs > 0 {
            pgStates = degraded
                ? [["state_name": "active+undersized+degraded", "count": .int(pgs - ceph.pools.count)], ["state_name": "active+undersized", "count": .int(ceph.pools.count)]]
                : [["state_name": "active+clean", "count": .int(pgs)]]
        }
        var pgmap: [String: JSONValue] = [
            "num_pgs": .int(pgs), "num_pools": .int(ceph.pools.count), "num_objects": .int(Int(usedGiB * 256)),
            "bytes_used": .int(Int(usedGiB * Self.gib)), "bytes_total": .int(Int(totalGiB * Self.gib)), "bytes_avail": .int(Int((totalGiB - usedGiB) * Self.gib)),
            "pgs_by_state": .array(pgStates),
        ]
        if degraded, pgs > 0 { pgmap["degraded_ratio"] = .double(1.0 / 3) }
        let activeManager = ceph.managers.first { isOnline($0) && !ceph.stopped.contains("mgr.\($0)") }
        let activeMDS = ceph.fileSystems.isEmpty ? nil : ceph.metadataServers.first { isOnline($0) && !ceph.stopped.contains("mds.\($0)") }
        let standbyMDS = ceph.metadataServers.filter { isOnline($0) && !ceph.stopped.contains("mds.\($0)") && $0 != activeMDS }
        return success([
            "fsid": "8b3e2c1d-7f4a-4e2b-9c6d-1a5f0e3b7c9d",
            "health": ["status": .string(checks.isEmpty ? "HEALTH_OK" : "HEALTH_WARN"), "checks": .object(checks), "mutes": []],
            "quorum_names": .array(upMonitors.map { .string($0) }),
            "monmap": ["mons": .array(ceph.monitors.map { ["name": .string($0)] })],
            "osdmap": ["num_osds": .int(ceph.osds.count), "num_up_osds": .int(upOSDs.count), "num_in_osds": .int(inOSDs.count)],
            "pgmap": .object(pgmap),
            "mgrmap": [
                "active_name": .string(activeManager ?? ""),
                "standbys": .array(ceph.managers.filter { $0 != activeManager && isOnline($0) && !ceph.stopped.contains("mgr.\($0)") }.map { ["name": .string($0)] }),
            ],
            "fsmap": ["up": .int(activeMDS == nil ? 0 : 1), "up:standby": .int(standbyMDS.count)],
        ])
    }

    // MARK: - Services

    private func cephServices(_ type: String) -> [JSONValue] {
        let names = type == "mon" ? ceph.monitors : type == "mgr" ? ceph.managers : ceph.metadataServers
        let activeManager = ceph.managers.first { isOnline($0) && !ceph.stopped.contains("mgr.\($0)") }
        let activeMDS = ceph.fileSystems.isEmpty ? nil : ceph.metadataServers.first { isOnline($0) && !ceph.stopped.contains("mds.\($0)") }
        return names.map { name in
            let running = isOnline(name) && !ceph.stopped.contains("\(type).\(name)")
            let state: String = switch type {
            case "mon": running ? "running" : "stopped"
            case "mgr": running ? (name == activeManager ? "active" : "standby") : "stopped"
            default: running ? (name == activeMDS ? "up:active" : "up:standby") : "stopped"
            }
            var entry: [String: JSONValue] = [
                "name": .string(name), "host": .string(name), "state": .string(state), "service": 1, "direxists": 1,
                "ceph_version": .string(Self.version), "ceph_version_short": "20.2.4",
                "addr": .string((cluster.nodes.first { $0.name == name }?.ip ?? "10.0.10.10") + (type == "mon" ? ":6789/0" : "")),
            ]
            if type == "mon" { entry["quorum"] = .int(running ? 1 : 0) }
            if type == "mds", name == activeMDS, let fs = ceph.fileSystems.first { entry["fs_name"] = .string(fs) }
            return .object(entry)
        }
    }

    private func createCephService(_ type: String, id: String, node: String, user: String) -> HTTPResponse {
        guard ceph.installed.contains(node) else { return failure(500, "binary not installed: /usr/bin/ceph-\(type)") }
        switch type {
        case "mon":
            guard !ceph.monitors.contains(node) else { return failure(500, "monitor 'mon.\(node)' already exists") }
            ceph.monitors.append(node)
            // The first monitor brings a manager.
            if ceph.managers.isEmpty { ceph.managers.append(node) }
        case "mgr":
            guard !ceph.managers.contains(node) else { return failure(500, "ceph manager directory '/var/lib/ceph/mgr/ceph-\(node)' already exists") }
            ceph.managers.append(node)
        default:
            guard !ceph.metadataServers.contains(id) else { return failure(500, "ceph MDS directory '/var/lib/ceph/mds/ceph-\(id)' already exists") }
            ceph.metadataServers.append(id)
        }
        return startTask(node: node, type: "cephcreate\(type)", objectID: "\(type).\(id)", user: user, duration: 2.5)
    }

    private func destroyCephService(_ type: String, id: String, node: String, user: String) -> HTTPResponse {
        switch type {
        case "mon":
            guard ceph.monitors.contains(id) else { return failure(500, "no such monitor id '\(id)'") }
            guard ceph.monitors.count > 1 else { return failure(500, "can't remove last monitor") }
            ceph.monitors.removeAll { $0 == id }
        case "mgr":
            guard ceph.managers.contains(id) else { return failure(500, "CephManager '\(id)' not found") }
            ceph.managers.removeAll { $0 == id }
        default:
            guard ceph.metadataServers.contains(id) else { return failure(500, "CephMDS '\(id)' not found") }
            ceph.metadataServers.removeAll { $0 == id }
        }
        ceph.stopped.remove("\(type).\(id)")
        return startTask(node: node, type: "cephdestroy\(type)", objectID: "\(type).\(id)", user: user, duration: 2)
    }

    private func cephServiceAction(_ action: String, service: String, node: String, user: String) -> HTTPResponse {
        let parts = service.split(separator: ".").map(String.init)
        guard parts.count == 2, ["mon", "mgr", "mds", "osd"].contains(parts[0]) else { return fieldFailure(["service": "invalid service name"]) }
        if parts[0] == "osd" {
            guard let index = ceph.osds.firstIndex(where: { String($0.id) == parts[1] }) else { return failure(500, "\(service) does not exist") }
            ceph.osds[index].isStopped = action == "stop"
        } else if action == "stop" {
            ceph.stopped.insert(service)
        } else {
            ceph.stopped.remove(service)
        }
        return startTask(node: node, type: "srv\(action)", objectID: service, user: user, duration: 1.5)
    }

    // MARK: - OSDs

    private func osdTree() -> JSONValue {
        let hosts = cluster.nodes.map(\.name).filter { host in ceph.osds.contains { $0.host == host } }
        let hostEntries: [JSONValue] = hosts.enumerated().map { index, host in
            .object([
                "id": .string(String(-(index + 2))), "name": .string(host), "type": "host", "leaf": 0, "reweight": -1, "version": "20.2.4",
                "children": .array(ceph.osds.filter { $0.host == host }.map { osd in
                    let up = isOnline(osd.host) && !osd.isStopped
                    return .object([
                        "id": .string(String(osd.id)), "name": .string("osd.\(osd.id)"), "host": .string(host), "type": "osd", "leaf": 1,
                        "status": .string(up ? "up" : "down"), "in": .int(osd.isIn ? 1 : 0), "device_class": .string(osd.deviceClass),
                        "osdtype": "bluestore", "crush_weight": .double(osd.sizeGiB / 1024), "reweight": 1,
                        "bytes_used": .int(Int(osd.usedGiB * Self.gib)), "total_space": .int(Int(osd.sizeGiB * Self.gib)),
                        "percent_used": .double(osd.usedGiB / osd.sizeGiB * 100), "pgs": .int(up ? 77 : 0),
                        "apply_latency_ms": .int(up ? 2 : 0), "commit_latency_ms": .int(up ? 2 : 0), "ceph_version_short": "20.2.4",
                        "ceph_version": .string(Self.version),
                    ])
                }),
            ])
        }
        return [
            "flags": .string((["sortbitwise", "recovery_deletes", "purged_snapdirs", "pglog_hardlimit"] + ceph.flags.sorted()).joined(separator: ",")),
            "root": ["leaf": 0, "children": [["id": "-1", "name": "default", "type": "root", "leaf": 0, "children": .array(hostEntries)]]],
        ]
    }

    private func createOSD(node: String, parameters: [String: String], user: String) -> HTTPResponse {
        guard let device = parameters["dev"], !device.isEmpty else { return fieldFailure(["dev": "property is missing and it is not optional"]) }
        var layout = diskLayout(node)
        guard let index = layout.disks.firstIndex(where: { $0.path == device }) else { return failure(500, "unable to get device info for '\(device)'") }
        guard layout.disks[index].usage == nil else { return failure(500, "device '\(device)' is already in use") }
        layout.disks[index].usage = "LVM"
        diskLayouts[node] = layout
        let id = (ceph.osds.map(\.id).max() ?? -1) + 1
        let disk = layout.disks[index]
        ceph.osds.append(DemoCeph.OSD(id: id, host: node, deviceClass: parameters["crush-device-class"] ?? disk.type, sizeGiB: Double(disk.sizeGiB), usedGiB: 0.03))
        return startTask(node: node, type: "cephcreateosd", objectID: device.replacingOccurrences(of: "/dev/", with: ""), user: user, duration: 4)
    }

    private func destroyOSD(_ id: Int, node: String, user: String) -> HTTPResponse {
        guard let osd = ceph.osds.first(where: { $0.id == id }) else { return failure(500, "osd.\(id) does not exist") }
        if osd.isIn { return failure(500, "osd is in - please mark it 'out' first") }
        if isOnline(osd.host), !osd.isStopped { return failure(500, "osd is still running - please stop it first") }
        ceph.osds.removeAll { $0.id == id }
        return startTask(node: node, type: "cephdestroyosd", objectID: String(id), user: user, duration: 3)
    }

    private func cephFlags(_ method: HTTPMethod, parameters: [String: String], user: String) -> HTTPResponse? {
        let all: [(String, String)] = [
            ("nobackfill", "Backfilling of PGs is suspended."), ("nodeep-scrub", "Deep Scrubbing is disabled."),
            ("nodown", "OSD failure reports are being ignored, such that the monitors will not mark OSDs down."),
            ("noin", "OSDs that were previously marked out will not be marked back in when they start."),
            ("noout", "OSDs will not automatically be marked out after the configured interval."), ("norebalance", "Rebalancing of PGs is suspended."),
            ("norecover", "Recovery of PGs is suspended."), ("noscrub", "Scrubbing is disabled."), ("notieragent", "Cache tiering activity is suspended."),
            ("noup", "OSDs are not allowed to start."), ("pause", "Pauses read and writes."),
        ]
        switch method {
        case .get:
            return success(.array(all.map { name, description in ["name": .string(name), "description": .string(description), "value": .int(ceph.flags.contains(name) ? 1 : 0)] }))
        case .put:
            guard privileges(for: user).contains("Sys.Modify") else { return failure(403, "Permission check failed (/, Sys.Modify)") }
            for (name, _) in all {
                if let value = parameters[name] {
                    if value == "1" { ceph.flags.insert(name) } else { ceph.flags.remove(name) }
                }
            }
            return startTask(node: cluster.nodes.first(where: \.isOnline)?.name ?? "pve", type: "cephsetflags", objectID: "", user: user, duration: 1)
        default:
            return nil
        }
    }

    // MARK: - Pools and file systems

    private func poolJSON(_ pool: DemoCeph.Pool, number: Int) -> JSONValue {
        let total = ceph.osds.map(\.sizeGiB).reduce(0, +)
        var object: [String: JSONValue] = [
            "pool": .int(number), "pool_name": .string(pool.name), "size": .int(pool.size), "min_size": .int(pool.minSize),
            "pg_num": .int(pool.pgNum), "pg_num_final": .int(max(pool.pgNum, pool.pgNumMin ?? 0)), "pg_autoscale_mode": .string(pool.autoscale),
            "crush_rule": 0, "crush_rule_name": "replicated_rule", "type": "replicated",
            "bytes_used": .int(Int(pool.usedGiB * Self.gib)), "percent_used": .double(total > 0 ? pool.usedGiB * Double(pool.size) / total : 0),
            "application_metadata": .object([pool.application: [:]]),
        ]
        if let min = pool.pgNumMin { object["pg_num_min"] = .int(min) }
        if let ratio = pool.targetRatio { object["target_size_ratio"] = .double(ratio) }
        if let size = pool.targetSize { object["target_size"] = .int(Int(size)) }
        return .object(object)
    }

    /// `10G`, `1.5T` or plain bytes.
    private static func bytes(_ text: String) -> Int64? {
        let units: [Character: Double] = ["K": 1024, "M": 1_048_576, "G": Self.gib, "T": Self.gib * 1024]
        if let unit = text.last, let factor = units[unit], let number = Double(text.dropLast()) { return Int64(number * factor) }
        return Int64(text)
    }

    private func createCephPool(_ parameters: [String: String], node: String, user: String) -> HTTPResponse {
        let name = parameters["name"] ?? ""
        guard !name.isEmpty else { return fieldFailure(["name": "property is missing and it is not optional"]) }
        guard !ceph.pools.contains(where: { $0.name == name }) else { return failure(500, "pool '\(name)' already exists") }
        var pool = DemoCeph.Pool(name: name, application: parameters["application"] ?? "rbd", usedGiB: 0)
        if let error = apply(parameters, to: &pool) { return error }
        ceph.pools.append(pool)
        if parameters["add_storages"] == "1", pool.application == "rbd", !storageConfigs.contains(where: { $0.id == name }) {
            storageConfigs.append(DemoStorageConfig(id: name, type: "rbd", values: ["pool": name, "content": "images,rootdir", "krbd": "0"]))
        }
        return startTask(node: node, type: "cephcreatepool", objectID: name, user: user, duration: 2)
    }

    private func updateCephPool(_ name: String, parameters: [String: String], node: String, user: String) -> HTTPResponse {
        guard let index = ceph.pools.firstIndex(where: { $0.name == name }) else { return failure(500, "pool '\(name)' does not exist") }
        var pool = ceph.pools[index]
        if let error = apply(parameters, to: &pool) { return error }
        ceph.pools[index] = pool
        return startTask(node: node, type: "cephsetpool", objectID: name, user: user, duration: 1)
    }

    private func apply(_ parameters: [String: String], to pool: inout DemoCeph.Pool) -> HTTPResponse? {
        if let size = parameters["size"] {
            guard let value = Int(size), (1...7).contains(value) else { return fieldFailure(["size": "value must have a maximum value of 7"]) }
            pool.size = value
        }
        if let minSize = parameters["min_size"] {
            guard let value = Int(minSize), (1...pool.size).contains(value) else { return fieldFailure(["min_size": "value must not be larger than size"]) }
            pool.minSize = value
        }
        if let pgs = parameters["pg_num"] {
            guard let value = Int(pgs), (1...32768).contains(value) else { return fieldFailure(["pg_num": "value must have a maximum value of 32768"]) }
            pool.pgNum = value
        }
        if let value = parameters["pg_num_min"] { pool.pgNumMin = Int(value) }
        if let mode = parameters["pg_autoscale_mode"] { pool.autoscale = mode }
        if let ratio = parameters["target_size_ratio"] { pool.targetRatio = Double(ratio) }
        if let size = parameters["target_size"] { pool.targetSize = Self.bytes(size) }
        return nil
    }

    private func createFileSystem(_ name: String, parameters: [String: String], node: String, user: String) -> HTTPResponse {
        guard !ceph.fileSystems.contains(name) else { return failure(500, "ceph fs '\(name)' already exists") }
        guard ceph.metadataServers.contains(where: { isOnline($0) && !ceph.stopped.contains("mds.\($0)") }) else {
            return failure(500, "need MDS to add storage, but none got active!")
        }
        let pgs = Int(parameters["pg_num"] ?? "") ?? 128
        ceph.fileSystems.append(name)
        ceph.pools += [
            DemoCeph.Pool(name: "\(name)_data", pgNum: pgs, application: "cephfs", usedGiB: 0),
            DemoCeph.Pool(name: "\(name)_metadata", pgNum: max(pgs / 4, 8), pgNumMin: 16, application: "cephfs", usedGiB: 0.01),
        ]
        if parameters["add-storage"] == "1", !storageConfigs.contains(where: { $0.id == name }) {
            storageConfigs.append(DemoStorageConfig(id: name, type: "cephfs", values: ["fs-name": name, "content": "iso,vztmpl,backup"]))
        }
        return startTask(node: node, type: "cephfscreate", objectID: name, user: user, duration: 3)
    }

    // MARK: - Configuration and log

    private func cephConfigFile() -> String {
        var lines = [
            "[global]", "\tauth_client_required = cephx", "\tauth_cluster_required = cephx", "\tauth_service_required = cephx",
            "\tcluster_network = \(ceph.network)", "\tfsid = 8b3e2c1d-7f4a-4e2b-9c6d-1a5f0e3b7c9d", "\tmon_allow_pool_delete = true",
            "\tmon_host = " + ceph.monitors.compactMap { name in cluster.nodes.first { $0.name == name }?.ip }.joined(separator: " "),
            "\tosd_pool_default_min_size = 2", "\tosd_pool_default_size = 3", "\tpublic_network = \(ceph.network)", "",
            "[client]", "\tkeyring = /etc/pve/priv/$cluster.$name.keyring", "",
        ]
        for name in ceph.monitors {
            lines += ["[mon.\(name)]", "\tpublic_addr = \(cluster.nodes.first { $0.name == name }?.ip ?? "")", ""]
        }
        return lines.joined(separator: "\n")
    }

    private func crushMap() -> String {
        var lines = ["# begin crush map", "tunable choose_total_tries 50", "tunable chooseleaf_descend_once 1", "", "# devices"]
        lines += ceph.osds.map { "device \($0.id) osd.\($0.id) class \($0.deviceClass)" }
        lines += ["", "# types", "type 0 osd", "type 1 host", "type 11 root", "", "# buckets"]
        for host in Set(ceph.osds.map(\.host)).sorted() {
            lines += ["host \(host) {", "\talg straw2", "\thash 0"] + ceph.osds.filter { $0.host == host }.map { "\titem osd.\($0.id) weight \(String(format: "%.3f", $0.sizeGiB / 1024))" } + ["}"]
        }
        lines += ["", "# rules", "rule replicated_rule {", "\tid 0", "\ttype replicated", "\tstep take default", "\tstep chooseleaf firstn 0 type host", "\tstep emit", "}", "", "# end crush map"]
        return lines.joined(separator: "\n")
    }

    private func cephLog() -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
        let now = Date()
        var lines: [(TimeInterval, String)] = [
            (-3600, "mon.pve1 (mon.0) 1021 : cluster [INF] overall HEALTH_OK"),
            (-1800, "mon.pve1 (mon.0) 1187 : cluster [DBG] pgmap v48211: 209 pgs: 209 active+clean; 1.1 TiB data, 2.2 TiB used, 3.1 TiB / 5.3 TiB avail"),
        ]
        if cluster.nodes.contains(where: { !$0.isOnline }) {
            lines += [
                (-900, "mon.pve1 (mon.0) 1201 : cluster [WRN] Health check failed: 1/3 mons down, quorum pve1,pve2 (MON_DOWN)"),
                (-890, "mon.pve1 (mon.0) 1203 : cluster [WRN] Health check failed: 2 osds down (OSD_DOWN)"),
                (-600, "mon.pve1 (mon.0) 1240 : cluster [WRN] Health check update: Degraded data redundancy (PG_DEGRADED)"),
            ]
        }
        lines.append((-60, "mgr.pve1 (mgr.14102) 9921 : cluster [DBG] pgmap v48390: \(ceph.pools.map(\.pgNum).reduce(0, +)) pgs"))
        return lines.map { "\(formatter.string(from: now.addingTimeInterval($0.0))) \($0.1)" }
    }
}
