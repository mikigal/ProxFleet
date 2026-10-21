import Foundation
import ProxmoxCore

/// Creating VMs and containers, guest IDs, pools and container templates in demo mode.
extension DemoState {
    /// Returns nil for paths this part does not handle.
    func handleCreation(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        switch (method, parts) {
        case (.get, ["cluster", "nextid"]):
            if let text = parameters["vmid"] {
                guard let vmid = Int(text), vmid >= 100 else { return fieldFailure(["vmid": "value must have a minimum value of 100"]) }
                if cluster.guests.contains(where: { $0.vmid == vmid }) { return fieldFailure(["vmid": "VM \(vmid) already exists"]) }
                return success(.string(text))
            }
            let used = Set(cluster.guests.map(\.vmid))
            return success(.string(String((100...).first { !used.contains($0) }!)))
        case (.get, ["pools"]):
            return success([["poolid": "lab", "comment": "Experiments"]])
        case (.get, let path) where path.count == 3 && path[0] == "nodes" && path[2] == "aplinfo":
            return success(.array(Self.applianceTemplates.map { template in
                [
                    "template": .string(template.file), "section": .string(template.section), "package": .string(template.file),
                    "headline": .string(template.headline), "description": .string(template.description), "type": "lxc",
                ]
            }))
        case (.post, let path) where path.count == 3 && path[0] == "nodes" && path[2] == "aplinfo":
            return downloadTemplate(node: path[1], parameters: parameters, user: user)
        case (.post, let path) where path.count == 3 && path[0] == "nodes" && ["qemu", "lxc"].contains(path[2]):
            return createGuest(kind: path[2] == "qemu" ? .qemu : .lxc, node: path[1], parameters: parameters, user: user)
        default:
            return nil
        }
    }

    /// Templates downloaded in this session, available once their download task finished.
    func downloadedTemplateVolumes() -> [JSONValue] {
        let now = Date()
        return downloadedTemplates.filter { $0.availableAt <= now }.map { download in
            ["volid": .string(download.volume), "size": 134_217_728, "format": "tzst"]
        }
    }

    private static let applianceTemplates: [(file: String, section: String, headline: String, description: String)] = [
        ("debian-13-standard_13.1-2_amd64.tar.zst", "system", "Debian 13 (Standard)", "A small Debian Trixie system including all standard packages."),
        ("ubuntu-24.04-standard_24.04-2_amd64.tar.zst", "system", "Ubuntu 24.04 (Standard)", "A small Ubuntu 24.04 Noble Numbat system including all standard packages."),
        ("alpine-3.22-default_20250617_amd64.tar.xz", "system", "Alpine Linux 3.22", ""),
        ("rockylinux-10-default_20250701_amd64.tar.xz", "system", "Rocky Linux 10", ""),
        ("debian-12-turnkey-nextcloud_18.2-1_amd64.tar.gz", "turnkeylinux", "TurnKey Nextcloud", "TurnKey Nextcloud - Share and sync files, calendars and contacts"),
        ("debian-12-turnkey-wordpress_18.1-1_amd64.tar.gz", "turnkeylinux", "TurnKey WordPress", "TurnKey WordPress - Blog publishing platform"),
    ]

    private func downloadTemplate(node: String, parameters: [String: String], user: String) -> HTTPResponse {
        guard let storage = parameters["storage"], let template = parameters["template"],
              Self.applianceTemplates.contains(where: { $0.file == template })
        else { return fieldFailure(["template": "no such template"]) }
        let duration: TimeInterval = 3
        let start = Date()
        downloadedTemplates.append((volume: "\(storage):vztmpl/\(template)", availableAt: start.addingTimeInterval(duration)))
        return startTask(node: node, type: "download", objectID: template, user: user, duration: duration)
    }

    private func createGuest(kind: DemoCluster.Guest.Kind, node: String, parameters: [String: String], user: String) -> HTTPResponse {
        guard privileges(for: user).contains("VM.Allocate") else {
            return failure(403, "Permission check failed (/vms/\(parameters["vmid"] ?? ""), VM.Allocate)")
        }
        guard cluster.nodes.first(where: { $0.name == node })?.isOnline == true else {
            return failure(595, "Connection refused: node '\(node)' seems to be offline")
        }
        guard let vmid = parameters["vmid"].flatMap(Int.init), vmid >= 100 else {
            return fieldFailure(["vmid": "value must have a minimum value of 100"])
        }
        guard !cluster.guests.contains(where: { $0.vmid == vmid }) else {
            return fieldFailure(["vmid": "VM \(vmid) already exists on node '\(node)'"])
        }
        if kind == .lxc {
            guard let template = parameters["ostemplate"] else { return fieldFailure(["ostemplate": "property is missing and it is not optional"]) }
            guard availableTemplates.contains(template) else { return failure(500, "volume '\(template)' does not exist") }
            if let password = parameters["password"], password.count < 5 {
                return fieldFailure(["password": "value must be at least 5 characters long"])
            }
        }

        let isVM = kind == .qemu
        let name = parameters[isVM ? "name" : "hostname"] ?? (isVM ? "VM \(vmid)" : "CT\(vmid)")
        let diskKey = parameters.keys.sorted().first { key in
            ["scsi", "virtio", "sata", "ide"].contains { key.hasPrefix($0) } && !(parameters[key] ?? "").contains("media=cdrom")
        }
        let disk = (isVM ? diskKey.flatMap { parameters[$0] } : parameters["rootfs"]).flatMap { value in
            PropertyString(parsing: value).defaultValue?.split(separator: ":").last.flatMap { Int($0) }
        }
        let guest = DemoCluster.Guest(
            vmid, kind, name, on: node, running: false,
            cores: parameters["cores"].flatMap(Int.init) ?? 1,
            memoryGiB: (parameters["memory"].flatMap(Double.init) ?? 512) / 1024,
            diskGiB: disk ?? 0
        )
        cluster.guests.append(guest)

        // The configuration is what was sent, minus creation-only options, with disks allocated.
        let creationOnly: Set<String> = ["vmid", "start", "pool", "password", "ssh-public-keys", "ostemplate", "storage"]
        createdConfigs[vmid] = [:]
        for key in parameters.keys.sorted() where !creationOnly.contains(key) {
            let value = allocateVolume(parameters[key]!, key: key, guest: guest)
            createdConfigs[vmid]?[key] = value
        }
        if !isVM {
            createdConfigs[vmid]?["arch"] = "amd64"
            createdConfigs[vmid]?["ostype"] = parameters["ostemplate"].map(Self.osType(ofTemplate:)) ?? "unmanaged"
            if createdConfigs[vmid]?["hostname"] == nil { createdConfigs[vmid]?["hostname"] = name }
        }

        let start = parameters["start"] == "1"
        return startTask(node: node, type: isVM ? "qmcreate" : "vzcreate", objectID: String(vmid), user: user, duration: isVM ? 2 : 4) { guest in
            if start {
                guest.isRunning = true
                guest.bootedAt = Date()
            }
        }
    }

    private var availableTemplates: Set<String> {
        let downloaded = downloadedTemplates.filter { $0.availableAt <= Date() }.map(\.volume)
        return Set(downloaded + ["local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"])
    }

    /// `local:vztmpl/debian-13-standard_…` → `debian`, as Proxmox detects it after extracting.
    private static func osType(ofTemplate volume: String) -> String {
        let file = volume.split(separator: "/").last.map(String.init) ?? volume
        let known = ["debian", "ubuntu", "alpine", "centos", "rockylinux", "almalinux", "fedora", "archlinux", "opensuse", "gentoo", "devuan", "nixos"]
        guard let match = known.first(where: { file.hasPrefix($0) }) else { return "debian" }
        return ["rockylinux", "almalinux"].contains(match) ? "centos" : match
    }

    private func startTask(node: String, type: String, objectID: String, user: String, duration: TimeInterval, apply: (@Sendable (inout DemoCluster.Guest) -> Void)? = nil) -> HTTPResponse {
        let start = Date()
        let upid = String(format: "UPID:%@:%08X:%08X:%08X:%@:%@:%@:", node, 4000 + tasks.count, 100_000 + tasks.count, Int(start.timeIntervalSince1970), type, objectID, user)
        tasks.append(DemoTask(upid: upid, node: node, type: type, objectID: objectID, user: user, startedAt: start, duration: duration, error: nil, apply: apply))
        return success(.string(upid))
    }

    private func fieldFailure(_ errors: [String: String]) -> HTTPResponse {
        let body: JSONValue = [
            "data": nil, "success": 0, "status": "400", "message": "Parameter verification failed.",
            "errors": .object(errors.mapValues { .string($0) }),
        ]
        return HTTPResponse(statusCode: 200, body: body.encoded())
    }
}
