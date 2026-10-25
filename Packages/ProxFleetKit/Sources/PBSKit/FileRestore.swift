import Foundation
import ProxmoxCore
import PVEKit

extension PVE {
    /// Entries of a folder in a backup on a Proxmox Backup Server storage. `filePath` is `/` for the archives
    /// (a VM's disks), then the entries' own paths: the files of a container archive, or the partitions of a VM
    /// disk and their files.
    ///
    /// Inside a VM disk the node first starts a small restore VM. The server waits up to 25 seconds for it and
    /// answers 503 while it is still starting, so retry until the VM is up.
    public static func fileRestoreList(node: String, storage: String, volume: String, filePath: String) -> APIRequest<[CatalogEntry]> {
        APIRequest(.get, "/nodes/\(node)/storage/\(storage)/file-restore/list",
                   parameters: ["volume": .string(volume), "filepath": .string(filePath)], timeout: 60)
    }

    /// A file of such a backup, or a folder as zip (or as `tar.zst` with `tar`). For `ProxmoxSession.download`.
    /// Starts the restore VM when it is not running, which can take a while before the first byte.
    public static func fileRestoreDownload(node: String, storage: String, volume: String, filePath: String, tar: Bool = false) -> APIRequest<Nothing> {
        var parameters: APIParameters = ["volume": .string(volume), "filepath": .string(filePath)]
        if tar { parameters["tar"] = true }
        return APIRequest(.get, "/nodes/\(node)/storage/\(storage)/file-restore/download", parameters: parameters, timeout: 120)
    }
}

extension [CatalogEntry] {
    /// Directories first, then by name, like a file manager.
    public func sortedForBrowsing() -> [CatalogEntry] {
        sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
