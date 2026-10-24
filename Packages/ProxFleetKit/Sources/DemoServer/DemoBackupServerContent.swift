import Foundation
import ProxmoxCore

/// Backup groups, snapshots, their files and the file archives inside them on the demo backup server.
extension DemoBackupServerState {
    // MARK: - Model

    /// The snapshot's backup time: its age counted from when the demo started, so it stays the same while running.
    func time(of snapshot: DemoBackupServer.Snapshot) -> Int {
        Int(started.timeIntervalSince1970 - snapshot.daysAgo * 86_400)
    }

    private func groupIndex(_ datastore: Int, _ parameters: [String: String]) -> Int? {
        let namespace = parameters["ns"] ?? ""
        return server.datastores[datastore].groups.firstIndex {
            $0.namespace == namespace && $0.type == parameters["backup-type"] && $0.id == parameters["backup-id"]
        }
    }

    private func snapshotIndex(_ datastore: Int, _ group: Int, _ parameters: [String: String]) -> Int? {
        guard let time = parameters["backup-time"].flatMap(Int.init) else { return nil }
        return server.datastores[datastore].groups[group].snapshots.firstIndex { self.time(of: $0) == time }
    }

    /// Files of a snapshot, as a backup of that kind of guest has them.
    private static func files(of group: DemoBackupServer.Group, _ snapshot: DemoBackupServer.Snapshot) -> [(name: String, size: Int?)] {
        let gib = 1_073_741_824.0
        switch group.type {
        case "vm":
            return [("qemu-server.conf.blob", 512), ("drive-scsi0.img.fidx", Int(snapshot.sizeGiB * gib)), ("index.json.blob", 580), ("client.log.blob", nil)]
        case "ct":
            return [("pct.conf.blob", 260), ("root.pxar.didx", Int(snapshot.sizeGiB * gib)), ("catalog.pcat1.didx", 48_200), ("index.json.blob", 560), ("client.log.blob", nil)]
        default:
            let archive = group.id == "pbs" ? "etc.pxar.didx" : "home.pxar.didx"
            return [("catalog.pcat1.didx", 220_000), (archive, Int(snapshot.sizeGiB * gib)), ("index.json.blob", 420)]
        }
    }

    private func groupJSON(_ group: DemoBackupServer.Group) -> JSONValue {
        let newest = group.snapshots.min { $0.daysAgo < $1.daysAgo }
        var entry: [String: JSONValue] = [
            "backup-type": .string(group.type), "backup-id": .string(group.id), "backup-count": .int(group.snapshots.count),
            "owner": .string(group.owner),
            "files": .array(newest.map { Self.files(of: group, $0).map { .string($0.name) } } ?? []),
        ]
        if let newest { entry["last-backup"] = .int(time(of: newest)) }
        if let comment = group.notes.split(separator: "\n").first { entry["comment"] = .string(String(comment)) }
        return .object(entry)
    }

    private func snapshotJSON(_ group: DemoBackupServer.Group, _ snapshot: DemoBackupServer.Snapshot) -> JSONValue {
        let files = Self.files(of: group, snapshot)
        var entry: [String: JSONValue] = [
            "backup-type": .string(group.type), "backup-id": .string(group.id), "backup-time": .int(time(of: snapshot)),
            "owner": .string(group.owner), "protected": .bool(snapshot.isProtected),
            "size": .int(files.compactMap(\.size).reduce(0, +)),
            "files": .array(files.map { file in
                var item: [String: JSONValue] = ["filename": .string(file.name)]
                if let size = file.size {
                    item["size"] = .int(size)
                    item["crypt-mode"] = group.id == "anna-macbook" ? "encrypt" : "none"
                }
                return .object(item)
            }),
        ]
        if group.id == "anna-macbook" { entry["fingerprint"] = "a7:3f:91:0c:5e:22:d8:41" }
        if let comment = snapshot.notes.split(separator: "\n").first { entry["comment"] = .string(String(comment)) }
        if let verified = snapshot.verified {
            entry["verification"] = ["state": verified ? "ok" : "failed", "upid": .string(tasks.first { $0.type == "verificationjob" }?.upid ?? "")]
        }
        return .object(entry)
    }

    // MARK: - Routes

    /// Routes below `/admin/datastore/{store}` for its content. nil for other paths.
    func handleContent(_ method: HTTPMethod, index: Int, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        let store = server.datastores[index].name
        let namespace = parameters["ns"] ?? ""
        switch (method, rest) {
        case (.get, ["groups"]):
            return success(.array(server.datastores[index].groups.filter { $0.namespace == namespace }.map(groupJSON)))
        case (.get, ["snapshots"]):
            let groups = server.datastores[index].groups.filter { group in
                group.namespace == namespace && (parameters["backup-type"].map { $0 == group.type } ?? true)
                    && (parameters["backup-id"].map { $0 == group.id } ?? true)
            }
            return success(.array(groups.flatMap { group in group.snapshots.map { snapshotJSON(group, $0) } }))
        case (.post, ["namespace"]):
            guard let name = parameters["name"], name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\-]*/) != nil else {
                return fieldFailure(["name": "value does not match the regex pattern"])
            }
            let parent = parameters["parent"] ?? ""
            let path = parent.isEmpty ? name : "\(parent)/\(name)"
            guard !server.datastores[index].namespaces.contains(path) else { return failure(400, "namespace '\(path)' already exists") }
            server.datastores[index].namespaces.append(path)
            return success(.string(path))
        case (.delete, ["namespace"]):
            return deleteNamespace(index, namespace, deleteGroups: parameters["delete-groups"] == "1")
        case (.post, ["move-namespace"]):
            let target = parameters["target-ns"] ?? ""
            for (offset, path) in server.datastores[index].namespaces.enumerated() where path == namespace || path.hasPrefix(namespace + "/") {
                server.datastores[index].namespaces[offset] = target + path.dropFirst(namespace.count)
            }
            for (offset, group) in server.datastores[index].groups.enumerated() where group.namespace == namespace || group.namespace.hasPrefix(namespace + "/") {
                server.datastores[index].groups[offset].namespace = target + group.namespace.dropFirst(namespace.count)
            }
            if !server.datastores[index].namespaces.contains(target) { server.datastores[index].namespaces.append(target) }
            return startTask("move-namespace", "\(store):\(namespace):\(target)", duration: 1.5)
        case (.post, ["prune-datastore"]):
            if parameters["dry-run"] != "1" {
                for group in server.datastores[index].groups.indices
                    where namespace.isEmpty || server.datastores[index].groups[group].namespace == namespace || server.datastores[index].groups[group].namespace.hasPrefix(namespace + "/") {
                    prune(index, group, parameters)
                }
            }
            return startTask("prune", "\(store):\(namespace)", duration: 2)
        case (.post, ["verify"]):
            return verify(index, parameters)
        default:
            break
        }
        // Everything below names a group.
        guard let group = groupIndex(index, parameters) else {
            return failure(400, "unable to find backup group \(parameters["backup-type"] ?? "")/\(parameters["backup-id"] ?? "")")
        }
        switch (method, rest) {
        case (.get, ["group-notes"]):
            return success(.string(server.datastores[index].groups[group].notes))
        case (.put, ["group-notes"]):
            server.datastores[index].groups[group].notes = parameters["notes"] ?? ""
            return success(nil)
        case (.post, ["change-owner"]):
            server.datastores[index].groups[group].owner = parameters["new-owner"] ?? ""
            return success(nil)
        case (.delete, ["groups"]):
            let protected = server.datastores[index].groups[group].snapshots.filter(\.isProtected).count
            let removed = server.datastores[index].groups[group].snapshots.count - protected
            if protected > 0 {
                server.datastores[index].groups[group].snapshots.removeAll { !$0.isProtected }
                if parameters["error-on-protected"] != "0" { return failure(400, "group only partially deleted due to protected snapshots") }
            } else {
                server.datastores[index].groups.remove(at: group)
            }
            return success(["removed-groups": .int(protected == 0 ? 1 : 0), "removed-snapshots": .int(removed), "protected-snapshots": .int(protected)])
        case (.post, ["prune"]):
            let decisions = pruneDecisions(server.datastores[index].groups[group], parameters)
            let reference = server.datastores[index].groups[group]
            if parameters["dry-run"] == "1" {
                return success(.array(reference.snapshots.map { snapshot in
                    ["backup-type": .string(reference.type), "backup-id": .string(reference.id), "backup-time": .int(time(of: snapshot)),
                     "keep": .bool(decisions[time(of: snapshot)] ?? true), "protected": .bool(snapshot.isProtected)]
                }))
            }
            prune(index, group, parameters)
            return startTask("prune", "\(store):\(namespace):\(reference.type)/\(reference.id)", duration: 1)
        case (.post, ["move-group"]):
            let target = parameters["target-ns"] ?? ""
            server.datastores[index].groups[group].namespace = target
            if !server.datastores[index].namespaces.contains(target) { server.datastores[index].namespaces.append(target) }
            let reference = server.datastores[index].groups[group]
            return startTask("move-group", "\(store):/\(reference.type)/\(reference.id):\(target)", duration: 1.5)
        default:
            break
        }
        guard let snapshot = snapshotIndex(index, group, parameters) else { return failure(400, "unable to find snapshot") }
        let reference = server.datastores[index].groups[group]
        switch (method, rest) {
        case (.get, ["files"]):
            return success(.array(Self.files(of: reference, reference.snapshots[snapshot]).map { file in
                var item: [String: JSONValue] = ["filename": .string(file.name)]
                if let size = file.size { item["size"] = .int(size); item["crypt-mode"] = "none" }
                return .object(item)
            }))
        case (.get, ["notes"]):
            return success(.string(reference.snapshots[snapshot].notes))
        case (.put, ["notes"]):
            server.datastores[index].groups[group].snapshots[snapshot].notes = parameters["notes"] ?? ""
            return success(nil)
        case (.put, ["protected"]):
            server.datastores[index].groups[group].snapshots[snapshot].isProtected = parameters["protected"] == "1"
            return success(nil)
        case (.delete, ["snapshots"]):
            guard !reference.snapshots[snapshot].isProtected else {
                return failure(400, "failed to delete snapshot - \"cannot remove protected snapshot\"")
            }
            server.datastores[index].groups[group].snapshots.remove(at: snapshot)
            return success(nil)
        case (.get, ["catalog"]):
            return catalog(reference, parameters["filepath"] ?? "/")
        default:
            return nil
        }
    }

    private func verify(_ index: Int, _ parameters: [String: String]) -> HTTPResponse {
        let store = server.datastores[index].name
        let namespace = parameters["ns"] ?? ""
        let nsPath = namespace.isEmpty ? "" : namespace.split(separator: "/").map { "ns/\($0)" }.joined(separator: "/")
        guard let group = groupIndex(index, parameters) else {
            return startTask("verify", nsPath.isEmpty ? store : "\(store):\(nsPath)", duration: 3)
        }
        let reference = server.datastores[index].groups[group]
        let groupPath = "\(nsPath)/\(reference.type)/\(reference.id)"
        if let snapshot = snapshotIndex(index, group, parameters) {
            server.datastores[index].groups[group].snapshots[snapshot].verified = true
            let time = String(format: "%08X", self.time(of: reference.snapshots[snapshot]))
            return startTask("verify_snapshot", "\(store):\(groupPath)/\(time)", duration: 2)
        }
        for snapshot in server.datastores[index].groups[group].snapshots.indices {
            server.datastores[index].groups[group].snapshots[snapshot].verified = true
        }
        return startTask("verify_group", "\(store):\(groupPath)", duration: 2.5)
    }

    private func deleteNamespace(_ index: Int, _ namespace: String, deleteGroups: Bool) -> HTTPResponse {
        guard !namespace.isEmpty else { return failure(400, "cannot delete the root namespace") }
        func isBelow(_ path: String) -> Bool { path == namespace || path.hasPrefix(namespace + "/") }
        let groups = server.datastores[index].groups.filter { isBelow($0.namespace) }
        if !groups.isEmpty, !deleteGroups { return failure(400, "namespace '\(namespace)' is not empty") }
        let protected = groups.flatMap(\.snapshots).filter(\.isProtected).count
        let removed = groups.flatMap(\.snapshots).count - protected
        server.datastores[index].groups = server.datastores[index].groups.compactMap { group in
            guard isBelow(group.namespace) else { return group }
            var kept = group
            kept.snapshots.removeAll { !$0.isProtected }
            return kept.snapshots.isEmpty ? nil : kept
        }
        let remaining = Set(server.datastores[index].groups.map(\.namespace))
        server.datastores[index].namespaces.removeAll { path in
            isBelow(path) && !remaining.contains { $0 == path || $0.hasPrefix(path + "/") }
        }
        return success(["removed-groups": .int(groups.count - remaining.filter(isBelow).count), "removed-snapshots": .int(removed),
                        "protected-snapshots": .int(protected)])
    }

    // MARK: - Prune

    /// Which snapshots of a group the rules keep, by backup time, like the backup server decides it: each rule in turn
    /// keeps the newest snapshot of each period not yet covered, older ones of a covered period are removed, and
    /// protected snapshots always stay. Without any rule everything is kept.
    func pruneDecisions(_ group: DemoBackupServer.Group, _ parameters: [String: String]) -> [Int: Bool] {
        let rules: [(key: String, period: (Date) -> String)] = [
            ("keep-last", { "\($0.timeIntervalSince1970)" }),
            ("keep-hourly", { Self.period($0, "yyyy/MM/dd/HH") }),
            ("keep-daily", { Self.period($0, "yyyy/MM/dd") }),
            ("keep-weekly", { Self.period($0, "YYYY/ww") }),
            ("keep-monthly", { Self.period($0, "yyyy/MM") }),
            ("keep-yearly", { Self.period($0, "yyyy") }),
        ]
        let counts = rules.map { parameters[$0.key].flatMap(Int.init) ?? 0 }
        let snapshots = group.snapshots.sorted { $0.daysAgo < $1.daysAgo }
        var marks: [Int: Bool] = [:]
        guard counts.contains(where: { $0 > 0 }) else {
            for snapshot in snapshots { marks[time(of: snapshot)] = true }
            return marks
        }
        for (rule, keep) in zip(rules, counts) where keep > 0 {
            var included: Set<String> = []
            var alreadyIncluded: Set<String> = []
            for snapshot in snapshots where marks[time(of: snapshot)] == true {
                alreadyIncluded.insert(rule.period(Date(timeIntervalSince1970: TimeInterval(time(of: snapshot)))))
            }
            for snapshot in snapshots {
                let key = time(of: snapshot)
                guard marks[key] == nil else { continue }
                if snapshot.isProtected {
                    marks[key] = true
                    continue
                }
                let period = rule.period(Date(timeIntervalSince1970: TimeInterval(key)))
                if alreadyIncluded.contains(period) { continue }
                if !included.contains(period) {
                    if included.count >= keep { break }
                    included.insert(period)
                    marks[key] = true
                } else {
                    marks[key] = false
                }
            }
        }
        for snapshot in snapshots where marks[time(of: snapshot)] == nil {
            marks[time(of: snapshot)] = snapshot.isProtected
        }
        return marks
    }

    private static func period(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func prune(_ index: Int, _ group: Int, _ parameters: [String: String]) {
        let decisions = pruneDecisions(server.datastores[index].groups[group], parameters)
        server.datastores[index].groups[group].snapshots.removeAll { decisions[time(of: $0)] == false }
    }

    // MARK: - Files

    /// Files inside the archives of the demo backups: a container's root file system and a laptop's home folder.
    private static func tree(for group: DemoBackupServer.Group) -> (archive: String, paths: [String: String])? {
        switch (group.type, group.id) {
        case ("ct", _):
            return ("root.pxar.didx", [
                "etc/hostname": "\(group.notes.split(separator: "\n").first ?? "ct")\n",
                "etc/hosts": "127.0.0.1 localhost\n10.0.10.53 pihole.home.arpa pihole\n",
                "etc/resolv.conf": "nameserver 127.0.0.1\nsearch home.arpa\n",
                "etc/pihole/pihole.toml": "[dns]\nupstreams = [\"9.9.9.9\", \"149.112.112.112\"]\n\n[webserver]\nport = \"80o,443os\"\n",
                "etc/pihole/custom.list": "10.0.10.11 pve1.home.arpa\n10.0.10.6 pbs.home.arpa\n",
                "var/log/pihole/pihole.log": "Oct 24 02:00:01 dnsmasq[312]: query[A] proxmox.com from 10.0.10.20\n",
                "root/.ash_history": "pihole -up\nreboot\n",
            ])
        case ("host", "pbs"):
            return ("etc.pxar.didx", ["hostname": "pbs\n", "hosts": "127.0.0.1 localhost\n10.0.10.6 pbs.home.arpa pbs\n",
                                      "proxmox-backup/datastore.cfg": "datastore: main\n\tpath /mnt/datastore/main\n\tgc-schedule daily\n"])
        default:
            return nil
        }
    }

    private func catalog(_ group: DemoBackupServer.Group, _ filePath: String) -> HTTPResponse {
        guard let tree = Self.tree(for: group) else { return failure(400, "no catalog for this backup") }
        let decoded = filePath == "/" ? "/" : (Data(base64Encoded: filePath).map { String(decoding: $0, as: UTF8.self) } ?? "")
        if decoded == "/" {
            return success([["filepath": .string(Data("/\(tree.archive)".utf8).base64EncodedString()), "text": .string(tree.archive), "type": "d", "leaf": false]])
        }
        // Paths look like `/root.pxar.didx` for the archive, then `root.pxar.didx/etc` below it.
        let trimmed = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        guard trimmed.hasPrefix(tree.archive) else { return failure(400, "path \"\(decoded)\" not found in catalog") }
        let directory = String(trimmed.dropFirst(tree.archive.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var children: [String: (isDirectory: Bool, size: Int)] = [:]
        for (path, content) in tree.paths {
            let prefix = directory.isEmpty ? "" : directory + "/"
            guard path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefix.count)
            let name = String(rest.prefix { $0 != "/" })
            let isDirectory = rest.contains("/")
            children[name] = (isDirectory, isDirectory ? 0 : content.utf8.count)
        }
        guard !children.isEmpty || directory.isEmpty else { return failure(400, "path \"\(decoded)\" not found in catalog") }
        let modified = Int(started.timeIntervalSince1970) - 86_400 * 3
        return success(.array(children.keys.sorted().map { name in
            let child = children[name]!
            let path = [tree.archive, directory, name].filter { !$0.isEmpty }.joined(separator: "/")
            var entry: [String: JSONValue] = ["filepath": .string(Data(path.utf8).base64EncodedString()), "text": .string(name),
                                              "type": child.isDirectory ? "d" : "f", "leaf": .bool(!child.isDirectory)]
            if !child.isDirectory { entry["size"] = .int(child.size); entry["mtime"] = .int(modified) }
            return .object(entry)
        }))
    }

    /// `pxar-file-download` and `download-decoded`: a file's bytes, a directory as zip, or a whole file of the snapshot.
    func handleDownload(_ request: HTTPRequest) -> HTTPResponse {
        let parameters = Self.parameters(of: request)
        let parts = request.url.path(percentEncoded: false).split(separator: "/").map(String.init)
        guard parts.count == 6, parts[2] == "admin", parts[3] == "datastore", let index = datastoreIndex(parts[4]),
              let group = groupIndex(index, parameters)
        else { return HTTPResponse(statusCode: 400, body: Data("no such backup".utf8)) }
        let reference = server.datastores[index].groups[group]
        switch parts[5] {
        case "download-decoded":
            let text: String
            switch parameters["file-name"] ?? "" {
            case "pct.conf.blob": text = "arch: amd64\ncores: 1\nhostname: \(reference.notes.split(separator: "\n").first ?? "ct")\nmemory: 512\nnet0: name=eth0,bridge=vmbr0,ip=dhcp,type=veth\nostype: debian\nrootfs: local-lvm:vm-\(reference.id)-disk-0,size=8G\nunprivileged: 1\n"
            case "qemu-server.conf.blob": text = "boot: order=scsi0;net0\ncores: 2\nmemory: 4096\nname: \(reference.notes.split(separator: "\n").first ?? "vm")\nnet0: virtio=BC:24:11:6A:2F:10,bridge=vmbr0\nostype: l26\nscsi0: local-lvm:vm-\(reference.id)-disk-0,size=32G\nscsihw: virtio-scsi-single\n"
            case "client.log.blob": text = "INFO: starting new backup job\nINFO: backup finished successfully\n"
            default: text = #"{"backup-type":"\#(reference.type)","backup-id":"\#(reference.id)","files":[]}"#
            }
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: Data(text.utf8))
        case "pxar-file-download":
            guard let tree = Self.tree(for: reference), let encoded = parameters["filepath"],
                  let decoded = Data(base64Encoded: encoded).map({ String(decoding: $0, as: UTF8.self) })
            else { return HTTPResponse(statusCode: 400, body: Data("unable to read file".utf8)) }
            let trimmed = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
            let path = String(trimmed.dropFirst(tree.archive.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let content = tree.paths[path] {
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: Data(content.utf8))
            }
            let prefix = path.isEmpty ? "" : path + "/"
            let files = tree.paths.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
                .map { (path: String($0.key.dropFirst(prefix.count)), data: Data($0.value.utf8)) }
            guard !files.isEmpty else { return HTTPResponse(statusCode: 400, body: Data("error opening '\"\(path)\"'".utf8)) }
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: DemoZip.archive(files))
        default:
            return HTTPResponse(statusCode: 400, body: Data("not available in demo mode".utf8))
        }
    }
}

extension DemoBackupServerTransport: FileDownloadTransport {
    public func download(_ request: HTTPRequest, into directory: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> HTTPDownload {
        try await Task.sleep(for: .milliseconds(300))
        guard request.headers["Cookie"]?.contains("PBSAuthCookie=") == true else {
            throw ProxmoxError.unauthorized("authentication failed")
        }
        let response = await state.handleDownload(request)
        let file = directory.appending(path: "download-\(UUID().uuidString)")
        try response.body.write(to: file)
        progress(Int64(response.body.count), Int64(response.body.count))
        return HTTPDownload(statusCode: response.statusCode, headers: response.headers, file: file)
    }
}
