import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct GuestCreationTests {
    @Test func linuxVMMatchesTheWebInterface() {
        var draft = VMCreationDraft(node: "pve", vmid: 120)
        draft.name = "debian"
        draft.isoVolume = "local:iso/debian-13.1.0-amd64-netinst.iso"
        draft.diskStorage = "local-lvm"
        #expect(draft.problems.isEmpty)
        let request = PVE.createVM(draft)
        #expect(request.method == .post)
        #expect(request.path == "/nodes/pve/qemu")
        #expect(request.parameters.formEncoded == [
            "vmid=120", "name=debian", "ostype=l26", "scsihw=virtio-scsi-single",
            "scsi0=local-lvm%3A32%2Cdiscard%3Don%2Ciothread%3D1",
            "ide2=local%3Aiso%2Fdebian-13.1.0-amd64-netinst.iso%2Cmedia%3Dcdrom",
            "cores=2", "cpu=x86-64-v2-AES", "memory=2048",
            "net0=model%3Dvirtio%2Cbridge%3Dvmbr0%2Cfirewall%3D1", "boot=order%3Dscsi0%3Bide2%3Bnet0",
        ].joined(separator: "&"))
    }

    @Test func windows11GetsUEFIAndTPM() {
        var draft = VMCreationDraft(node: "pve", vmid: 121)
        draft.applyDefaults(for: "win11")
        draft.diskStorage = "local-lvm"
        #expect(draft.problems.keys.sorted() == ["efidisk0", "tpmstate0"])
        draft.efiStorage = "local-lvm"
        draft.tpmStorage = "local-lvm"
        draft.driversISOVolume = "local:iso/virtio-win.iso"
        draft.hasNetwork = false
        draft.startAfterCreation = true
        let parameters = draft.parameters
        #expect(parameters["machine"] == "q35")
        #expect(parameters["bios"] == "ovmf")
        #expect(parameters["efidisk0"] == "local-lvm:1,efitype=4m,pre-enrolled-keys=1")
        #expect(parameters["tpmstate0"] == "local-lvm:1,version=v2.0")
        #expect(parameters["sata0"] == "local-lvm:32,discard=on")
        #expect(parameters["ide0"] == "local:iso/virtio-win.iso,media=cdrom")
        #expect(parameters["net0"] == nil)
        #expect(parameters["boot"] == "order=sata0")
        #expect(parameters["start"] == .bool(true))

        draft.applyDefaults(for: "l26")
        #expect(draft.bios == "seabios" && !draft.addTPM && draft.diskBus == .scsi && draft.driversISOVolume == nil)
        #expect(draft.network.model == "virtio")
    }

    @Test func ballooning() {
        var draft = VMCreationDraft(node: "pve", vmid: 100)
        draft.diskStorage = "local-lvm"
        draft.minimumMemoryMiB = 1024
        #expect(draft.parameters["balloon"] == .int(1024))
        draft.ballooning = false
        #expect(draft.parameters["balloon"] == .int(0))
    }

    @Test func vmAdvancedOptions() {
        var draft = VMCreationDraft(node: "pve", vmid: 130)
        draft.diskStorage = "local-lvm"
        draft.isHAManaged = true
        draft.startOnBoot = true
        draft.startup.order = "2"
        draft.startup.startDelay = "30"
        draft.tags = ["web", "prod"]
        draft.display = "virtio"
        draft.disk.cache = "writeback"
        draft.disk.asyncIO = "native"
        draft.disk.readOnly = true
        draft.disk.ssdEmulation = true
        draft.disk.includeInBackup = false
        draft.disk.replicate = false
        draft.disk.limits = ["mbps_rd": "100", "iops_wr": "500"]
        draft.cpu.sockets = 2
        draft.cpu.cores = 4
        draft.cpu.vcpus = 6
        draft.cpu.flags = ["aes": true, "pcid": false]
        draft.cpu.limit = 2.5
        draft.cpu.units = "200"
        draft.cpu.affinity = "0-3"
        draft.cpu.numa = true
        draft.memoryShares = "500"
        draft.allowKSM = false
        draft.network.macAddress = "BC:24:11:00:00:01"
        draft.network.isDisconnected = true
        draft.network.mtu = 1400
        draft.network.rateLimit = 12.5
        draft.network.queues = 4
        let parameters = draft.parameters
        #expect(parameters["ha-managed"] == .bool(true))
        #expect(parameters["onboot"] == .bool(true))
        #expect(parameters["startup"] == "order=2,up=30")
        #expect(parameters["tags"] == "web;prod")
        #expect(parameters["vga"] == "virtio")
        #expect(parameters["scsi0"] == "local-lvm:32,cache=writeback,discard=on,iothread=1,ssd=1,backup=0,aio=native,ro=1,replicate=0,mbps_rd=100,iops_wr=500")
        #expect(parameters["sockets"] == "2")
        #expect(parameters["cores"] == .int(4))
        #expect(parameters["vcpus"] == "6")
        #expect(parameters["cpu"] == "x86-64-v2-AES,flags=-pcid;+aes")
        #expect(parameters["cpulimit"] == "2.5")
        #expect(parameters["cpuunits"] == "200")
        #expect(parameters["affinity"] == "0-3")
        #expect(parameters["numa"] == "1")
        #expect(parameters["shares"] == "500")
        #expect(parameters["allow-ksm"] == .bool(false))
        #expect(parameters["net0"] == "virtio=BC:24:11:00:00:01,bridge=vmbr0,firewall=1,link_down=1,rate=12.5,mtu=1400,queues=4")

        // VirtIO Block disks have no SSD emulation; SATA disks have neither IO threads nor read-only mode.
        draft.diskBus = .virtio
        #expect(draft.parameters["virtio0"]?.encoded.contains("ssd=1") == false)
        draft.diskBus = .sata
        #expect(draft.parameters["sata0"]?.encoded.contains("iothread") == false)
        #expect(draft.parameters["sata0"]?.encoded.contains("ro=1") == false)
        // Shares only apply with ballooning.
        draft.ballooning = false
        #expect(draft.parameters["shares"] == nil)
    }

    @Test func vmValidation() {
        var draft = VMCreationDraft(node: "pve", vmid: 99)
        draft.name = "bad name"
        #expect(draft.problems.keys.sorted() == ["name", "scsi0", "vmid"])
        #expect(VMCreationDraft.isValidDNSName("web-01.lab"))
        #expect(!VMCreationDraft.isValidDNSName("-web"))
        #expect(!VMCreationDraft.isValidDNSName("web..lab"))
    }

    @Test func container() {
        var draft = ContainerCreationDraft(node: "pve", vmid: 210)
        #expect(draft.problems.keys.sorted() == ["ostemplate", "password", "rootfs"])
        draft.template = "local:vztmpl/alpine-3.24-default_20260714_amd64.tar.xz"
        draft.rootStorage = "local-lvm"
        draft.hostname = "alpine"
        draft.password = "secret"
        #expect(draft.problems["password"] != nil)
        draft.passwordConfirmation = "secret"
        draft.nameservers = "1.1.1.1  9.9.9.9"
        draft.startOnBoot = true
        #expect(draft.problems.isEmpty)
        let request = PVE.createContainer(draft)
        #expect(request.path == "/nodes/pve/lxc")
        let parameters = request.parameters
        #expect(parameters.items.map(\.name) == [
            "vmid", "ostemplate", "hostname", "unprivileged", "features", "password", "rootfs", "cores", "memory", "swap",
            "net0", "nameserver", "onboot",
        ])
        #expect(parameters["rootfs"] == "local-lvm:8")
        #expect(parameters["features"] == "nesting=1")
        #expect(parameters["unprivileged"] == .bool(true))
        #expect(parameters["net0"] == "name=eth0,bridge=vmbr0,firewall=1,ip=dhcp,type=veth")
        #expect(parameters["nameserver"] == "1.1.1.1 9.9.9.9")
    }

    @Test func containerAdvancedOptions() {
        var draft = ContainerCreationDraft(node: "pve", vmid: 211)
        draft.rootStorage = "local-lvm"
        draft.isHAManaged = true
        draft.tags = ["db"]
        draft.startup.shutdownTimeout = "60"
        draft.rootFS.acl = true
        draft.rootFS.quota = true
        draft.rootFS.replicate = false
        draft.rootFS.mountOptions = ["noatime", "discard"]
        draft.cpuLimit = 1.5
        draft.cpuUnits = "50"
        draft.network.macAddress = "BC:24:11:00:00:02"
        draft.network.isDisconnected = true
        draft.network.mtu = 1450
        draft.network.rateLimit = 10
        draft.network.isHostManaged = true
        let parameters = draft.parameters
        #expect(parameters["ha-managed"] == .bool(true))
        #expect(parameters["tags"] == "db")
        #expect(parameters["startup"] == "down=60")
        #expect(parameters["rootfs"] == "local-lvm:8,acl=1,quota=1,replicate=0,mountoptions=discard;noatime")
        #expect(parameters["cpulimit"] == "1.5")
        #expect(parameters["cpuunits"] == "50")
        #expect(parameters["net0"] == "name=eth0,hwaddr=BC:24:11:00:00:02,bridge=vmbr0,firewall=1,link_down=1,ip=dhcp,rate=10.0,mtu=1450,host-managed=1,type=veth")
    }

    @Test func containerWithSSHKeyNeedsNoPassword() {
        var draft = ContainerCreationDraft(node: "pve", vmid: 210)
        draft.sshPublicKeys = "ssh-ed25519 AAAA one\n\n  ssh-ed25519 AAAA two  \n"
        #expect(draft.problems["password"] == nil)
        #expect(draft.parameters["ssh-public-keys"] == "ssh-ed25519 AAAA one\nssh-ed25519 AAAA two")
        #expect(draft.parameters["password"] == nil)
    }

    @Test func decodesGuestIDsAndTemplates() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(GuestID.self, from: Data(#""103""#.utf8)).value == 103)
        #expect(try decoder.decode(GuestID.self, from: Data("104".utf8)).value == 104)
        let json = #"[{"template":"fedora-44-default_20260713_amd64.tar.xz","section":"system","package":"fedora-44-default","headline":"LXC default image for fedora 44 (20260713)","description":"","os":"fedora","version":"20260713"}]"#
        let templates = try decoder.decode([ApplianceTemplate].self, from: Data(json.utf8))
        #expect(templates.first?.summary == nil)
        #expect(templates.first?.headline == "LXC default image for fedora 44 (20260713)")
    }
}
