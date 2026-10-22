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
        case (.get, ["content"]):
            // Backups have their own route, which also serves the guests' backup screens.
            if parameters["content"] == "backup" { return nil }
            var volumes = storage == "local" ? fileVolumes(content: parameters["content"])
                : storage == "local-lvm" ? diskVolumes(node: node, content: parameters["content"]) : []
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
                    : file.volume.hasSuffix(".zst") ? "tzst" : "txz"
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
