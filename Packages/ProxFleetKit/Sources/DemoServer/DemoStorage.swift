import Foundation
import ProxmoxCore

/// A file on the `local` storage in demo mode: ISO images, templates, snippets and uploads.
struct DemoFile: Sendable {
    var volume: String
    var content: String
    var size: Int
    var created: Date
    /// Downloads show up once their task finished.
    var availableAt: Date = .distantPast
}

/// Storage status and content in demo mode: `local` holds files and backups, `local-lvm` the guests' disks.
extension DemoState {
    static func sampleFiles(now: Date) -> [DemoFile] {
        [
            DemoFile(volume: "local:iso/debian-13.1.0-amd64-netinst.iso", content: "iso", size: 790_626_304, created: now.addingTimeInterval(-86_400 * 40)),
            DemoFile(volume: "local:iso/ubuntu-24.04.3-live-server-amd64.iso", content: "iso", size: 3_213_064_192, created: now.addingTimeInterval(-86_400 * 21)),
            DemoFile(volume: "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst", content: "vztmpl", size: 128_974_848, created: now.addingTimeInterval(-86_400 * 30)),
            DemoFile(volume: "local:import/debian-13-genericcloud-amd64.qcow2", content: "import", size: 424_673_280, created: now.addingTimeInterval(-86_400 * 9)),
            DemoFile(volume: "local:import/windows-server-2025-eval.vmdk", content: "import", size: 11_811_160_064, created: now.addingTimeInterval(-86_400 * 6)),
            DemoFile(volume: "local:import/home-assistant-16.2.ova", content: "import", size: 563_609_600, created: now.addingTimeInterval(-86_400 * 3)),
            DemoFile(volume: "local:snippets/hookscript.pl", content: "snippets", size: 1_204, created: now.addingTimeInterval(-86_400 * 12)),
            DemoFile(volume: "local:snippets/user-data.yaml", content: "snippets", size: 512, created: now.addingTimeInterval(-86_400 * 12)),
        ]
    }

    /// Routes below `/nodes/{node}/storage/{storage}` other than backups, and `query-url-metadata`. nil for other paths.
    func handleStorage(_ method: HTTPMethod, node: String, rest: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        if method == .get, rest == ["query-url-metadata"] {
            let name = URLComponents(string: parameters["url"] ?? "")?.path.split(separator: "/").last.map(String.init) ?? ""
            return success(["filename": .string(name), "size": 734_003_200, "mimetype": "application/octet-stream"])
        }
        if method == .get, rest == ["storage"] {
            return nodeStorageList(node: node, content: parameters["content"])
        }
        if method == .get, rest == ["query-oci-repo-tags"] {
            guard let reference = parameters["reference"], !reference.isEmpty else { return fieldFailure(["reference": "property is missing and it is not optional"]) }
            return success(["3.20", "3.21", "3.22", "edge", "latest"])
        }
        guard rest.count >= 2, rest[0] == "storage", let config = storageConfigs.first(where: { $0.id == rest[1] }) else { return nil }
        let storage = rest[1]
        let isOnline = cluster.nodes.first { $0.name == node }?.isOnline ?? false
        guard isOnline else { return failure(595, "Connection refused: node '\(node)' seems to be offline") }
        guard config.isAvailable(on: node) else { return failure(500, "storage '\(storage)' is not available on node '\(node)'") }

        switch (method, Array(rest.dropFirst(2))) {
        case (.get, ["status"]):
            let usage = config.usageGiB
            return success([
                "type": .string(config.type), "content": .string(config.content.joined(separator: ",")), "active": 1, "enabled": 1,
                "shared": .int(config.isShared ? 1 : 0), "total": .int(Int(usage.total * 1_073_741_824)),
                "used": .int(Int(usage.used * 1_073_741_824)), "avail": .int(Int((usage.total - usage.used) * 1_073_741_824)),
            ])
        case (.get, ["rrddata"]):
            return success(storageHistory(config, timeframe: parameters["timeframe"] ?? "hour"))
        case (.get, ["prunebackups"]), (.delete, ["prunebackups"]):
            return prune(storage: config, node: node, method: method, parameters: parameters, user: user)
        case (.post, ["oci-registry-pull"]):
            return pullOCIImage(node: node, storage: storage, parameters: parameters, user: user)
        case (.get, ["import-metadata"]):
            return importMetadata(storage: storage, volume: parameters["volume"] ?? "")
        case (.get, ["content"]):
            // Backups have their own route, which also serves the guests' backup screens.
            if parameters["content"] == "backup" { return nil }
            var volumes = storage == "local" ? fileVolumes(content: parameters["content"])
                : storage == "local-lvm" ? diskVolumes(node: node, content: parameters["content"])
                : config.type == "esxi" ? esxiGuests(storage: storage, content: parameters["content"]) : []
            if parameters["content"] == nil, config.content.contains("backup") {
                volumes += backupVolumes(storage: storage, vmid: nil)
            }
            return success(.array(volumes))
        case (.delete, let path) where path.count >= 2 && path[0] == "content":
            let volume = path.dropFirst().joined(separator: "/")
            if backups.contains(where: { $0.volume == volume }) { return nil }
            guard privileges(for: user).contains("Datastore.AllocateSpace") else { return failure(403, "Permission check failed (/storage/\(storage), Datastore.Allocate)") }
            if let guest = cluster.guests.first(where: { volume.hasPrefix("\(storage):vm-\($0.vmid)-") || volume.hasPrefix("\(storage):base-\($0.vmid)-") }) {
                return startTask(node: node, type: "imgdel", objectID: "", user: user, duration: 1,
                                 error: "unable to delete volume '\(volume)' - volume is used by \(guest.kind == .qemu ? "VM" : "CT") \(guest.vmid)")
            }
            guard let index = files.firstIndex(where: { $0.volume == volume }) else { return failure(500, "volume '\(volume)' does not exist") }
            files.remove(at: index)
            return startTask(node: node, type: "imgdel", objectID: "", user: user, duration: 1)
        case (.post, ["download-url"]), (.post, ["upload"]):
            guard storage == "local" else { return failure(500, "storage '\(storage)' does not support content type '\(parameters["content"] ?? "")'") }
            guard privileges(for: user).contains("Datastore.AllocateSpace") else { return failure(403, "Permission check failed (/storage/\(storage), Datastore.AllocateTemplate)") }
            guard let content = parameters["content"], ["iso", "vztmpl", "import"].contains(content),
                  let name = parameters["filename"], !name.isEmpty
            else { return fieldFailure(["filename": "property is missing and it is not optional"]) }
            let folder = content == "iso" ? "iso" : content == "vztmpl" ? "vztmpl" : "import"
            let volume = "\(storage):\(folder)/\(name)"
            guard !files.contains(where: { $0.volume == volume }) else { return failure(500, "refusing to override existing file '\(name)'") }
            let isDownload = rest.last == "download-url"
            let duration: TimeInterval = isDownload ? 4 : 1
            let now = Date()
            files.append(DemoFile(volume: volume, content: content, size: Int(parameters["size"] ?? "") ?? 734_003_200, created: now,
                                  availableAt: now.addingTimeInterval(duration)))
            return startTask(node: node, type: isDownload ? "download" : "imgcopy", objectID: isDownload ? name : "", user: user, duration: duration)
        default:
            return nil
        }
    }

    private func fileVolumes(content: String?) -> [JSONValue] {
        let now = Date()
        let downloaded = downloadedTemplates.filter { $0.availableAt <= now }.map {
            DemoFile(volume: $0.volume, content: "vztmpl", size: 134_217_728, created: $0.availableAt)
        }
        return (files.filter { $0.availableAt <= now } + downloaded)
            .filter { content == nil || $0.content == content }
            .map { file in
                let format = file.content == "iso" ? "iso" : file.content == "snippets" ? "snippet"
                    : file.content == "import" ? String(file.volume.split(separator: ".").last ?? "raw")
                    : file.volume.hasSuffix(".zst") ? "tzst" : file.volume.hasSuffix(".tar") ? "tar" : "txz"
                return [
                    "volid": .string(file.volume), "content": .string(file.content), "size": .int(file.size),
                    "ctime": .int(Int(file.created.timeIntervalSince1970)), "format": .string(format),
                ]
            }
    }

    private func diskVolumes(node: String, content: String?) -> [JSONValue] {
        cluster.guests.filter { $0.node == node }.compactMap { guest in
            let type = guest.kind == .qemu ? "images" : "rootdir"
            guard content == nil || content == type else { return nil }
            let prefix = guest.isTemplate ? "base" : "vm"
            return [
                "volid": .string("local-lvm:\(prefix)-\(guest.vmid)-disk-0"), "content": .string(type), "vmid": .int(guest.vmid),
                "size": .int(guest.diskGiB * 1_073_741_824), "format": "raw",
                "ctime": .int(Int(started.timeIntervalSince1970) - 86_400 * (guest.vmid % 30 + 5)),
            ]
        }
    }
}

extension DemoTransport: FileUploadTransport {
    /// Reads the form fields from the multipart body and answers like the form-encoded call.
    public func upload(_ request: HTTPRequest, bodyFile: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> HTTPResponse {
        let boundary = request.headers["Content-Type"]?.components(separatedBy: "boundary=").last ?? ""
        let total = (try? FileManager.default.attributesOfItem(atPath: bodyFile.path)[.size] as? Int64) ?? 0
        for step in 1...4 {
            try await Task.sleep(for: .milliseconds(250))
            progress(total * Int64(step) / 4, total)
        }
        var fields = MultipartBody.fields(of: bodyFile, boundary: boundary)
        fields["size"] = String(max(0, total - 512))
        var formRequest = request
        formRequest.headers["Content-Type"] = "application/x-www-form-urlencoded"
        formRequest.body = Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").utf8)
        return try await send(formRequest)
    }
}

/// Storage history, pruning, OCI images and guest imports in demo mode.
extension DemoState {
    /// Usage that grows slowly towards the current value.
    fileprivate func storageHistory(_ config: DemoStorageConfig, timeframe: String) -> JSONValue {
        let step: TimeInterval = ["day": 1800, "week": 10_800, "month": 43_200, "year": 604_800][timeframe] ?? 60
        let usage = config.usageGiB
        guard usage.total > 0 else { return [] }
        let end = (Date().timeIntervalSince1970 / step).rounded(.down) * step
        let gib = 1_073_741_824.0
        return .array((0..<70).map { index in
            let used = usage.used * (0.8 + 0.2 * Double(index) / 69) + sin(Double(index) / 5) * usage.used * 0.01
            return ["time": .int(Int(end - Double(69 - index) * step)), "used": .double(used * gib), "total": .double(usage.total * gib)]
        })
    }

    /// `GET` previews and `DELETE` removes, by the retention rules sent or those of the storage.
    fileprivate func prune(storage config: DemoStorageConfig, node: String, method: HTTPMethod, parameters: [String: String], user: String) -> HTTPResponse {
        guard let vmid = parameters["vmid"].flatMap(Int.init) else { return fieldFailure(["vmid": "property is missing and it is not optional"]) }
        let options = PropertyString(parsing: parameters["prune-backups"] ?? config.values["prune-backups"] ?? "keep-all=1")
        let now = Date()
        let candidates = backups.filter { $0.volume.hasPrefix(config.id + ":") && $0.vmid == vmid && $0.availableAt <= now }
            .sorted { $0.date > $1.date }
        var marks: [String: String] = [:]
        for backup in candidates where backup.isProtected { marks[backup.volume] = "protected" }
        if options["keep-all"] == "1" {
            for backup in candidates where marks[backup.volume] == nil { marks[backup.volume] = "keep" }
        } else {
            // Like Proxmox: each rule keeps the newest backup of each period that no earlier rule kept, up to its count.
            let calendar = Calendar(identifier: .gregorian)
            let periods: [(String, (Date) -> String)] = [
                ("keep-last", { "\($0.timeIntervalSince1970)" }),
                ("keep-hourly", { let c = calendar.dateComponents([.year, .month, .day, .hour], from: $0); return "\(c.year!)-\(c.month!)-\(c.day!)-\(c.hour!)" }),
                ("keep-daily", { let c = calendar.dateComponents([.year, .month, .day], from: $0); return "\(c.year!)-\(c.month!)-\(c.day!)" }),
                ("keep-weekly", { let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0); return "\(c.yearForWeekOfYear!)-\(c.weekOfYear!)" }),
                ("keep-monthly", { let c = calendar.dateComponents([.year, .month], from: $0); return "\(c.year!)-\(c.month!)" }),
                ("keep-yearly", { "\(calendar.component(.year, from: $0))" }),
            ]
            for (key, period) in periods {
                guard let limit = options[key].flatMap(Int.init), limit > 0 else { continue }
                let alreadyKept = Set(candidates.filter { marks[$0.volume] == "keep" }.map { period($0.date) })
                var included = Set<String>()
                for backup in candidates where marks[backup.volume] == nil {
                    let id = period(backup.date)
                    if alreadyKept.contains(id) || included.contains(id) { continue }
                    if included.count >= limit { break }
                    included.insert(id)
                    marks[backup.volume] = "keep"
                }
            }
        }
        if method == .get {
            return success(.array(candidates.map { backup in
                [
                    "volid": .string(backup.volume), "ctime": .int(Int(backup.date.timeIntervalSince1970)),
                    "mark": .string(marks[backup.volume] ?? "remove"), "type": .string(backup.kind.rawValue), "vmid": .int(backup.vmid),
                ]
            }))
        }
        guard privileges(for: user).contains("Datastore.AllocateSpace") else { return failure(403, "Permission check failed (/storage/\(config.id), Datastore.AllocateSpace)") }
        let removed = Set(candidates.filter { marks[$0.volume] == nil }.map(\.volume))
        backups.removeAll { removed.contains($0.volume) }
        return startTask(node: node, type: "prunebackups", objectID: config.id, user: user, duration: 1)
    }

    fileprivate func pullOCIImage(node: String, storage: String, parameters: [String: String], user: String) -> HTTPResponse {
        guard let reference = parameters["reference"], let colon = reference.lastIndex(of: ":") else {
            return fieldFailure(["reference": "invalid OCI reference"])
        }
        guard storage == "local" else { return failure(500, "storage '\(storage)' does not support content type 'vztmpl'") }
        let name = reference[..<colon].split(separator: "/").last.map(String.init) ?? "image"
        let file = (parameters["filename"].map { $0.hasSuffix(".tar") ? $0 : "\($0).tar" }) ?? "\(name)_\(reference[reference.index(after: colon)...]).tar"
        let now = Date()
        files.append(DemoFile(volume: "local:vztmpl/\(file)", content: "vztmpl", size: 3_984_384, created: now, availableAt: now.addingTimeInterval(3)))
        return startTask(node: node, type: "download", objectID: file, user: user, duration: 3)
    }

    /// Guests on the demo's ESXi host.
    fileprivate func esxiGuests(storage: String, content: String?) -> [JSONValue] {
        guard content == nil || content == "import" else { return [] }
        return ["ha-datacenter/datastore1/win2022-dc/win2022-dc.vmx", "ha-datacenter/datastore1/debian-web/debian-web.vmx"].map { path in
            ["volid": .string("\(storage):\(path)"), "content": "import", "format": "vmx", "size": 0]
        }
    }

    /// What the demo's OVA and ESXi guests would become.
    fileprivate func importMetadata(storage: String, volume: String) -> HTTPResponse {
        if volume.hasSuffix(".ova") {
            let name = volume.split(separator: "/").last.map { String($0.dropLast(4)) } ?? "appliance"
            return success([
                "type": "vm", "source": .string(volume),
                "create-args": ["name": .string(name), "ostype": "l26", "memory": "4096", "cores": "2", "bios": "ovmf", "boot": "order=scsi0"],
                "disks": ["scsi0": ["volid": .string("\(storage):\(volume)/\(name)-disk1.vmdk"), "size": 34_359_738_368], "efidisk0": ["volid": .string("\(storage):\(volume)/\(name)-nvram")]],
                "net": ["net0": ["model": "vmxnet3"]],
                "warnings": [["type": "ova-needs-extracting"]],
            ])
        }
        if volume.hasSuffix(".vmx") {
            let isWindows = volume.contains("win")
            let name = volume.split(separator: "/").last.map { String($0.dropLast(4)) } ?? "guest"
            var arguments: [String: JSONValue] = ["name": .string(name), "memory": "8192", "cores": "4", "sockets": "1", "boot": "order=scsi0;ide0"]
            arguments["ostype"] = isWindows ? "win11" : "l26"
            if isWindows {
                arguments["bios"] = "ovmf"
                arguments["machine"] = "q35"
            }
            arguments["ide0"] = "none,media=cdrom"
            var warnings: [JSONValue] = [["type": "cdrom-image-ignored", "key": "ide0", "value": "[datastore1] iso/server.iso"]]
            if isWindows { warnings.append(["type": "efi-state-lost", "key": "bios", "value": "efi"]) }
            return success([
                "type": "vm", "source": "esxi",
                "create-args": .object(arguments),
                "disks": ["scsi0": ["volid": .string("\(storage):\(volume.replacingOccurrences(of: ".vmx", with: ".vmdk"))"), "size": 64_424_509_440]],
                "net": ["net0": ["model": isWindows ? "e1000e" : "vmxnet3", "macaddr": isWindows ? "00:50:56:9A:1B:2C" : "00:50:56:9A:3D:4E"]],
                "warnings": .array(warnings),
            ])
        }
        return failure(500, "unable to parse directory volume name '\(volume)'")
    }
}
