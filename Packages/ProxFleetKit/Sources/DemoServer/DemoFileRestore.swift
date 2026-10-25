import Foundation
import ProxmoxCore

/// File restore from the backups on the `pbs` storage: a container's root file system, or a VM disk with its
/// partitions. The first look into a VM disk answers 503 for a few seconds, like the restore VM that boots first.
extension DemoState {
    private static let restoreVMStartup: TimeInterval = 3

    /// Files of a backup by path, from the archive or disk down.
    private func restoreTree(storage: String, volume: String?) -> (backup: DemoBackup, paths: [String: String])? {
        guard let volume, let backup = backups.first(where: { $0.volume == volume || $0.volume == "\(storage):\(volume)" }),
              backup.volume.hasPrefix("\(storage):"), storageConfigs.first(where: { $0.id == storage })?.type == "pbs"
        else { return nil }
        let name = cluster.guests.first { $0.vmid == backup.vmid }?.name ?? "guest"
        switch backup.kind {
        case .lxc:
            let root = "root.pxar.didx"
            return (backup, [
                "\(root)/etc/hostname": "\(name)\n",
                "\(root)/etc/hosts": "127.0.0.1 localhost\n10.0.10.\(backup.vmid % 200) \(name).home.arpa \(name)\n",
                "\(root)/etc/os-release": "PRETTY_NAME=\"Debian GNU/Linux 13 (trixie)\"\nID=debian\nVERSION_ID=\"13\"\n",
                "\(root)/root/.bash_history": "apt update\napt full-upgrade\n",
                "\(root)/var/log/apt/history.log": "Start-Date: 2026-10-20  02:00:04\nUpgrade: openssl:amd64 (3.5.1-1, 3.5.4-1)\n",
            ])
        case .qemu:
            let disk = "drive-scsi0.img.fidx"
            return (backup, [
                "\(disk)/part/1/EFI/BOOT/BOOTX64.EFI": "demo boot loader\n",
                "\(disk)/part/2/etc/hostname": "\(name)\n",
                "\(disk)/part/2/etc/fstab": "UUID=4f1c0d2e / ext4 errors=remount-ro 0 1\nUUID=7A2B-19C4 /boot/efi vfat umask=0077 0 1\n",
                "\(disk)/part/2/home/admin/notes.txt": "Back up the configuration before every update.\n",
                "\(disk)/part/2/var/log/syslog": "Oct 24 02:00:01 \(name) systemd[1]: Starting backup.service...\n",
            ])
        }
    }

    /// `/` for the top, otherwise the base64 path without a leading slash: `drive-scsi0.img.fidx/part/2/etc`.
    private static func restorePath(_ filePath: String) -> String? {
        if filePath == "/" { return "" }
        guard let data = Data(base64Encoded: filePath) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func fileRestoreList(storage: String, parameters: [String: String]) -> HTTPResponse {
        guard let (backup, paths) = restoreTree(storage: storage, volume: parameters["volume"]) else {
            return failure(400, "Only PBS storages supported for file-restore.")
        }
        guard let directory = Self.restorePath(parameters["filepath"] ?? "/") else { return failure(400, "invalid base64 path") }
        if backup.kind == .qemu, !directory.isEmpty {
            let now = Date()
            let started = restoreVMStarts[backup.volume] ?? now
            restoreVMStarts[backup.volume] = started
            if now.timeIntervalSince(started) < Self.restoreVMStartup { return failure(503, "starting VM for file-restore, try again") }
        }
        var children: [String: (isDirectory: Bool, size: Int)] = [:]
        let prefix = directory.isEmpty ? "" : directory + "/"
        for (path, content) in paths where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            let name = String(rest.prefix { $0 != "/" })
            children[name] = (rest.contains("/"), content.utf8.count)
        }
        guard !children.isEmpty else { return failure(500, "path '\(directory)' not found") }
        let modified = Int(backup.date.timeIntervalSince1970) - 3600
        return success(.array(children.keys.sorted().map { name in
            let child = children[name]!
            let path = directory.isEmpty ? "/\(name)" : "\(directory)/\(name)"
            let type: JSONValue = !child.isDirectory ? "f" : name.hasSuffix(".img.fidx") ? "v" : "d"
            var entry: [String: JSONValue] = ["filepath": .string(Data(path.utf8).base64EncodedString()), "text": .string(name), "type": type,
                                              "leaf": .bool(!child.isDirectory)]
            if !child.isDirectory { entry["size"] = .int(child.size); entry["mtime"] = .int(modified) }
            return .object(entry)
        }))
    }

    /// `GET /api2/json/nodes/{node}/storage/{storage}/file-restore/download`: a file's bytes or a folder as zip.
    func fileRestoreDownload(_ request: HTTPRequest) -> HTTPResponse {
        let parts = request.url.path(percentEncoded: false).split(separator: "/").map(String.init)
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let parameter = { (name: String) in query.first { $0.name == name }?.value }
        guard parts.count == 8, parts[2] == "nodes", parts[4] == "storage", parts[6] == "file-restore", parts[7] == "download",
              let (_, paths) = restoreTree(storage: parts[5], volume: parameter("volume")),
              let path = parameter("filepath").flatMap(Self.restorePath)
        else { return HTTPResponse(statusCode: 400, body: Data("no such backup".utf8)) }
        if parameter("tar") == "1" { return HTTPResponse(statusCode: 400, body: Data("tar.zst is not available in demo mode".utf8)) }
        if let content = paths[path] {
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: Data(content.utf8))
        }
        let prefix = path + "/"
        let files = paths.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
            .map { (path: String($0.key.dropFirst(prefix.count)), data: Data($0.value.utf8)) }
        guard !path.isEmpty, !files.isEmpty else { return HTTPResponse(statusCode: 400, body: Data("unable to read '\(path)'".utf8)) }
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/zip"], body: DemoZip.archive(files))
    }
}

extension DemoTransport: FileDownloadTransport {
    public func download(_ request: HTTPRequest, into directory: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> HTTPDownload {
        try await Task.sleep(for: .milliseconds(300))
        guard request.headers["Cookie"]?.contains("PVEAuthCookie=") == true else {
            throw ProxmoxError.unauthorized("No ticket")
        }
        let response = await state.fileRestoreDownload(request)
        let file = directory.appending(path: "download-\(UUID().uuidString)")
        try response.body.write(to: file)
        progress(Int64(response.body.count), Int64(response.body.count))
        return HTTPDownload(statusCode: response.statusCode, headers: response.headers, file: file)
    }
}
