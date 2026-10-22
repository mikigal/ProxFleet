import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct ContainerDraftTests {
    @Test func networkRoundTripsAndKeepsUnknownOptions() {
        let value = "name=eth0,bridge=vmbr0,hwaddr=BC:24:11:8F:45:9C,ip=dhcp,type=veth"
        let draft = ContainerNetworkDraft(GuestNIC(key: "net0", value: value))
        #expect(draft.ipv4Mode == .dhcp)
        #expect(draft.ipv6Mode == AddressMode.none)
        #expect(!draft.firewall)
        #expect(draft.stringValue == "name=eth0,hwaddr=BC:24:11:8F:45:9C,bridge=vmbr0,ip=dhcp,type=veth")
    }

    @Test func staticAddresses() {
        var draft = ContainerNetworkDraft(name: "eth1")
        draft.ipv4Mode = .static
        draft.ipv4Address = "10.0.0.5/24"
        draft.ipv4Gateway = "10.0.0.1"
        draft.ipv6Mode = .slaac
        draft.vlanTag = 20
        #expect(draft.stringValue == "name=eth1,bridge=vmbr0,tag=20,firewall=1,ip=10.0.0.5/24,gw=10.0.0.1,ip6=auto,type=veth")
        let reread = ContainerNetworkDraft(GuestNIC(key: "net1", value: draft.stringValue))
        #expect(reread == draft)
    }

    @Test func dnsServersAreSpaceSeparated() {
        let original = ContainerDNSDraft(GuestConfig(values: ["nameserver": "1.1.1.1 8.8.8.8"]))
        #expect(original.nameservers == ["1.1.1.1", "8.8.8.8"])
        var draft = original
        draft.nameservers.append("9.9.9.9")
        draft.searchDomain = "lan"
        let update = draft.changes(from: original)
        #expect(update.values == ["nameserver": "1.1.1.1 8.8.8.8 9.9.9.9", "searchdomain": "lan"])
        draft.nameservers = [""]
        #expect(draft.changes(from: original).deletions == ["nameserver"])
    }

    @Test func mountPointOptions() {
        let disk = GuestDisk(key: "mp0", value: "local-lvm:vm-200-disk-1,mp=/data,size=8G")
        var draft = MountPointDraft(disk)
        #expect(draft.stringValue == "local-lvm:vm-200-disk-1,mp=/data,size=8G")
        draft.includeInBackup = true
        draft.mountOptions = ["nosuid", "noatime"]
        draft.path = "/srv"
        #expect(draft.stringValue == "local-lvm:vm-200-disk-1,mp=/srv,size=8G,backup=1,mountoptions=noatime;nosuid")
    }

    @Test func rootFSIgnoresMountPointOnlyOptions() {
        var draft = MountPointDraft(GuestDisk(key: "rootfs", value: "local-lvm:vm-200-disk-0,size=1G"))
        draft.readOnly = true
        draft.acl = false
        #expect(draft.stringValue == "local-lvm:vm-200-disk-0,size=1G,acl=0")
    }

    @Test func newMountPoints() {
        #expect(MountPointDraft.newValue(source: "local-lvm", sizeGiB: 8, path: "/data", includeInBackup: true, readOnly: false) == "local-lvm:8,mp=/data,backup=1")
        #expect(MountPointDraft.newValue(source: "/mnt/share", sizeGiB: nil, path: "/share", includeInBackup: false, readOnly: true) == "/mnt/share,mp=/share,ro=1")
    }

    @Test func devicePassthrough() {
        var draft = ContainerDeviceDraft("/dev/dri/renderD128,gid=104,mode=0666,future=1")
        #expect(draft.path == "/dev/dri/renderD128")
        #expect(draft.gid == 104 && draft.uid == nil && draft.mode == "0666")
        draft.isReadOnly = true
        #expect(draft.stringValue == "/dev/dri/renderD128,gid=104,mode=0666,deny-write=1,future=1")
        #expect(ContainerDeviceDraft("path=/dev/ttyUSB0,uid=1000").stringValue == "/dev/ttyUSB0,uid=1000")
        draft.path = "dri"
        draft.mode = "666"
        #expect(draft.problems.keys.sorted() == ["mode", "path"])
        let config = GuestConfig(values: ["dev10": "/dev/b", "dev2": "/dev/a", "devices": "x", "net0": "name=eth0"])
        #expect(config.containerDevices.map(\.key) == ["dev2", "dev10"])
    }
}
