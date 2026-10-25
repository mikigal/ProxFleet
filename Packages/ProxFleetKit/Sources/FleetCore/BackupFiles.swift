import Foundation
import PBSKit
import ProxmoxCore
import PVEKit

/// Files of a backup that can be browsed and downloaded like in a file manager.
@MainActor
public protocol BackupFileBrowser {
    /// The path of the top folder.
    var rootPath: String { get }
    /// Entries of a folder, directories first: `rootPath`, then the entries' own paths.
    func entries(at filePath: String) async throws -> [CatalogEntry]
    /// A file, or a folder as zip, in a folder of its own in the temporary directory. Delete the folder when done.
    func download(_ entry: CatalogEntry, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL
}

/// A file archive of a snapshot on a backup server.
public struct SnapshotArchiveFiles: BackupFileBrowser {
    public let detail: SnapshotDetail
    public let archive: SnapshotFile

    public init(detail: SnapshotDetail, archive: SnapshotFile) {
        self.detail = detail
        self.archive = archive
    }

    public var rootPath: String { Data("/\(archive.name)".utf8).base64EncodedString() }

    /// Split archives are listed through their metadata half.
    private var archiveName: String? { archive.name.hasSuffix(".mpxar.didx") ? archive.name : nil }

    public func entries(at filePath: String) async throws -> [CatalogEntry] {
        try await detail.catalog(filePath, archive: archiveName)
    }

    public func download(_ entry: CatalogEntry, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        try await detail.download(entry, archive: archiveName, progress: progress)
    }
}

/// The files of a backup on a Proxmox VE storage of a backup server, read through a node: a container's files,
/// or a VM's disks, their partitions and files.
public struct GuestBackupFiles: BackupFileBrowser {
    public let connection: ServerConnection
    public let node: String
    public let backup: BackupVolume
    public let rootPath = "/"
    /// How long to wait for the restore VM that reads a VM's disks.
    var startTimeout: Duration = .seconds(180)
    var retryDelay: Duration = .seconds(2)

    public init(connection: ServerConnection, node: String, backup: BackupVolume) {
        self.connection = connection
        self.node = node
        self.backup = backup
    }

    public func entries(at filePath: String) async throws -> [CatalogEntry] {
        let deadline = ContinuousClock.now + startTimeout
        while true {
            do {
                return try await connection.send(PVE.fileRestoreList(node: node, storage: backup.storage, volume: backup.volumeID, filePath: filePath))
                    .sortedForBrowsing()
            } catch ProxmoxError.api(503, _, _) where ContinuousClock.now < deadline {
                // The restore VM is still starting.
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    /// Named like downloads from a backup server: `ct-200-hostname`, `vm-102-etc.zip`.
    public func download(_ entry: CatalogEntry, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let kind = backup.subtype == "lxc" || backup.volumeID.contains("/ct/") ? "ct" : "vm"
        let name = [kind, backup.vmid.map(String.init), entry.name].compactMap(\.self).joined(separator: "-")
        return try await connection.downloadFile(PVE.fileRestoreDownload(node: node, storage: backup.storage, volume: backup.volumeID, filePath: entry.filePath),
                                                 named: name + (entry.isDirectory ? ".zip" : ""), progress: progress)
    }
}
