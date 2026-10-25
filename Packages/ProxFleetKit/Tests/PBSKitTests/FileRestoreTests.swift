import Foundation
@testable import PBSKit
import ProxmoxCore
import PVEKit
import Testing

/// File restore through Proxmox VE: the `pve-file-restore-*` fixtures were recorded on Proxmox VE 9.2 from backups
/// on the Backup Server 4.2 test server.
struct FileRestoreTests {
    private let volume = "pbs-test:backup/ct/200/2026-10-24T14:09:49Z"

    @Test func requests() {
        let list = PVE.fileRestoreList(node: "test2", storage: "pbs-test", volume: volume, filePath: "/")
        #expect(list.method == .get)
        #expect(list.path == "/nodes/test2/storage/pbs-test/file-restore/list")
        #expect(list.parameters == ["volume": .string(volume), "filepath": "/"])
        // The server waits up to 25 seconds for a restore VM, longer than the app's usual timeout.
        #expect((list.timeout ?? 0) > 25)
        let download = PVE.fileRestoreDownload(node: "test2", storage: "pbs-test", volume: volume, filePath: "cm9vdC5weGFyLmRpZHgvZXRj")
        #expect(download.path == "/nodes/test2/storage/pbs-test/file-restore/download")
        #expect(download.parameters == ["volume": .string(volume), "filepath": "cm9vdC5weGFyLmRpZHgvZXRj"])
        #expect((download.timeout ?? 0) > 25)
        #expect(PVE.fileRestoreDownload(node: "test2", storage: "pbs-test", volume: volume, filePath: "Lw==", tar: true).parameters["tar"] == .bool(true))
    }

    @Test func containerFiles() throws {
        let root = try fixture("pve-file-restore-ct-root", as: [CatalogEntry].self)
        #expect(root.map(\.name) == ["root.pxar.didx"])
        #expect(root.first?.isDirectory == true)
        #expect(root.first?.decodedPath == "/root.pxar.didx")
        let archive = try fixture("pve-file-restore-ct-archive", as: [CatalogEntry].self)
        #expect(archive.first { $0.name == "etc" }?.decodedPath == "root.pxar.didx/etc")

        let etc = try fixture("pve-file-restore-ct-directory", as: [CatalogEntry].self)
        let hostname = try #require(etc.first { $0.name == "hostname" })
        #expect(hostname.kind == .file && !hostname.isDirectory)
        #expect(hostname.size == 11 && hostname.modified != nil)
        #expect(hostname.decodedPath == "root.pxar.didx/etc/hostname")
        #expect(etc.first { $0.name == "os-release" }?.kind == .symlink)
        #expect(etc.first { $0.name == "apk" }?.isDirectory == true)

        let sorted = etc.sortedForBrowsing()
        let firstFile = try #require(sorted.firstIndex { !$0.isDirectory })
        #expect(sorted[firstFile...].allSatisfy { !$0.isDirectory })
        #expect(sorted.prefix(2).map(\.name) == ["acpi", "apk"])
    }

    @Test func vmDisks() throws {
        let disk = try #require(try fixture("pve-file-restore-vm-root", as: [CatalogEntry].self).first)
        #expect(disk.name == "drive-scsi0.img.fidx")
        #expect(disk.kind == .virtual && disk.isDirectory)
        #expect(disk.size == 4_294_967_296)
    }
}
