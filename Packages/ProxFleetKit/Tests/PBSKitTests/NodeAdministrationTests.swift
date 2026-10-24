import Foundation
@testable import PBSKit
import ProxmoxCore
import PVEKit
import Testing

struct NodeAdministrationTests {
    @Test func disksAreFlattenedLikeProxmoxVE() throws {
        let disks = try fixture("node-disks-list", as: [BackupServerDisk].self).flatMap(\.nodeDisks)
        let system = try #require(disks.first { $0.path == "/dev/sda" })
        #expect(system.type == "hdd")
        #expect(system.usage == "partitions")
        #expect(!system.isPartition)
        let partitions = disks.filter { $0.parent == "/dev/sda" }
        #expect(Set(partitions.compactMap(\.usage)) == ["LVM", "BIOS boot", "EFI"])
        #expect(partitions.allSatisfy { $0.type == "partition" })
        let spare = try #require(disks.first { $0.path == "/dev/sdb" })
        // `unused` is no usage, as Proxmox VE reports it.
        #expect(spare.isUnused)
        #expect(NodeDisk.grouped(disks).map(\.disk.name) == ["sda", "sdb"])
    }

    @Test func diskCallsTakeNames() {
        #expect(PBS.diskName("/dev/sdb") == "sdb")
        #expect(PBS.diskName("nvme0n1") == "nvme0n1")
    }

    @Test func smartReportsReadTheBackupServersStatus() throws {
        let report = try JSONDecoder().decode(SMARTReport.self, from: Data(#"{"attributes":[],"status":"passed","wearout":null}"#.utf8))
        #expect(report.health == "PASSED")
    }

    @Test func directoriesAndStorageCreation() throws {
        let directory = try JSONDecoder().decode(BackupServerDirectory.self, from: Data(
            #"{"name":"/usb","device":"/dev/disk/by-uuid/9bff97e5","filesystem":"ext4","path":"/mnt/datastore/usb","removable":true}"#.utf8))
        // Listed with a leading slash, deleted without.
        #expect(directory.name == "usb")
        #expect(directory.mount.name == "usb")
        #expect(directory.mount.fileSystem == "ext4")
        #expect(directory.isRemovable)

        var draft = DiskStorageDraft(kind: .directory)
        draft.name = "usb"
        draft.devices = ["/dev/sdd"]
        let parameters = draft.backupServerParameters(removable: true)
        #expect(parameters == ["name": "usb", "disk": "sdd", "filesystem": "ext4", "add-datastore": true, "removable-datastore": true])
        #expect(PBS.createDiskStorage(draft).path == "/nodes/localhost/disks/directory")

        var pool = DiskStorageDraft(kind: .zfs)
        pool.name = "tank"
        pool.devices = ["/dev/sdb", "/dev/sdc"]
        pool.raidLevel = "mirror"
        pool.addStorage = false
        let poolParameters = pool.backupServerParameters(removable: true)
        #expect(poolParameters["devices"] == "sdb,sdc")
        #expect(poolParameters["raidlevel"] == "mirror")
        #expect(poolParameters["add-datastore"] == .bool(false))
        #expect(poolParameters["removable-datastore"] == nil)
        #expect(PBS.createDiskStorage(pool).path == "/nodes/localhost/disks/zfs")

        // The name is also the datastore's.
        pool.name = "tk"
        #expect(pool.backupServerProblems(existingDatastores: [])["name"] != nil)
        pool.name = "main"
        pool.addStorage = true
        #expect(pool.backupServerProblems(existingDatastores: ["main"])["name"] != nil)
        #expect(!DiskStorageDraft.backupServerRAIDLevels.contains("draid"))
    }

    @Test func networkListsAreCommaSeparatedAndDeletionsRepeated() throws {
        var bridge = NetworkInterfaceDraft(creating: .bridge, existing: [])
        bridge.bridgePorts = ["eno1", "eno2"]
        bridge.vlanAware = true
        bridge.bridgeVIDs = "2-100"
        let created = PBS.createInterface(bridge)
        #expect(created.path == "/nodes/localhost/network")
        #expect(created.parameters["bridge_ports"] == "eno1,eno2")
        #expect(created.parameters["bridge_vids"] == nil)
        #expect(created.parameters["iface"] == "vmbr0")

        var update = GuestConfigUpdate()
        update.set("cidr", nil)
        update.set("bridge_vids", nil)
        update.set("gateway", nil)
        update.set("slaves", "eno1 eno2")
        let request = PBS.updateInterface("bond0", update)
        #expect(request.method == .put)
        #expect(request.parameters.values("delete") == ["cidr", "gateway"])
        #expect(request.parameters["slaves"] == "eno1,eno2")
    }

    @Test func interfacesWithListsDecode() throws {
        let network = try envelopeFixture("node-network", as: NetworkConfiguration.self)
        let nic = try #require(network.interfaces.first)
        #expect(nic.cidr == "10.10.100.160/24")
        #expect(nic.gateway == "10.10.100.1")
        let bridge = try JSONDecoder().decode(NetworkInterface.self, from: Data(
            #"{"iface":"vmbr0","type":"bridge","bridge_ports":["eno1","eno2"],"autostart":true}"#.utf8))
        #expect(bridge.bridgePorts == ["eno1", "eno2"])
    }

    @Test func optionsSendOnlyChanges() throws {
        let original = BackupServerNodeOptionsDraft(BackupServerNodeOptions(values: [
            "email-from": "pbs@home.arpa", "task-log-max-days": "90", "acme": "account=default",
        ]))
        #expect(original.taskLogMaxDays == 90)
        #expect(original.changes(from: original).isEmpty)
        var draft = original
        draft.emailFrom = ""
        draft.httpProxy = "http://proxy.lan:3128"
        draft.defaultLanguage = "pl"
        let update = draft.changes(from: original, digest: "d")
        #expect(update.deletions == ["email-from"])
        #expect(update.values == ["http-proxy": "http://proxy.lan:3128", "default-lang": "pl"])
        #expect(PBS.updateNodeOptions(update).parameters.values("delete") == ["email-from"])
        #expect(draft.problems.isEmpty)
        draft.httpProxy = "not a proxy"
        draft.emailFrom = "nobody"
        #expect(Set(draft.problems.keys) == ["http-proxy", "email-from"])
        // ACME settings are not the form's to change.
        #expect(original.serialized()["acme"] == nil)
    }

    @Test func emptyOptionsDecode() throws {
        let options = try envelopeFixture("node-config", as: Digested<BackupServerNodeOptions>.self)
        #expect(options.value.values.isEmpty)
        #expect(options.digest != nil)
    }

    @Test func certificatesCalls() {
        var draft = CustomCertificateDraft()
        draft.certificates = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
        #expect(PBS.uploadCertificate(draft).path == "/nodes/localhost/certificates/custom")
        // The backup server knows no `restart` for deletion.
        #expect(PBS.deleteCustomCertificate().parameters.isEmpty)
    }
}
