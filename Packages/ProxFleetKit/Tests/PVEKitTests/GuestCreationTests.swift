import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct GuestCreationTests {
    @Test func linuxVMMatchesTheWebInterface() {
        var draft = VMCreationDraft(node: "pve", vmid: 120)
        draft.name = "debian"
        draft.isoVolume = "local:iso/debian-13.1.0-amd64-netinst.iso"
        draft.disks[0].storage = "local-lvm"
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
        draft.disks[0].storage = "local-lvm"
        #expect(draft.problems.keys.sorted() == ["efidisk0", "tpmstate0"])
        draft.efiStorage = "local-lvm"
        draft.tpmStorage = "local-lvm"
        draft.driversISOVolume = "local:iso/virtio-win.iso"
        draft.networks = []
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
        #expect(draft.bios == "seabios" && !draft.addTPM && draft.disks[0].bus == .scsi && draft.driversISOVolume == nil)
        #expect(draft.defaultNetworkModel == "virtio")
    }

    @Test func ballooning() {
        var draft = VMCreationDraft(node: "pve", vmid: 100)
        draft.disks[0].storage = "local-lvm"
        draft.minimumMemoryMiB = 1024
        #expect(draft.parameters["balloon"] == .int(1024))
        draft.ballooning = false
        #expect(draft.parameters["balloon"] == .int(0))
    }

    @Test func vmAdvancedOptions() {
        var draft = VMCreationDraft(node: "pve", vmid: 130)
        draft.disks[0].storage = "local-lvm"
        draft.isHAManaged = true
        draft.startOnBoot = true
        draft.startup.order = "2"
        draft.startup.startDelay = "30"
        draft.tags = ["web", "prod"]
        draft.display = "virtio"
        draft.disks[0].options.cache = "writeback"
        draft.disks[0].options.asyncIO = "native"
        draft.disks[0].options.readOnly = true
        draft.disks[0].options.ssdEmulation = true
        draft.disks[0].options.includeInBackup = false
        draft.disks[0].options.replicate = false
        draft.disks[0].options.limits = ["mbps_rd": "100", "iops_wr": "500"]
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
        draft.networks[0].device.macAddress = "BC:24:11:00:00:01"
        draft.networks[0].device.isDisconnected = true
        draft.networks[0].device.mtu = 1400
        draft.networks[0].device.rateLimit = 12.5
        draft.networks[0].device.queues = 4
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
        draft.disks[0].bus = .virtio
        #expect(draft.parameters["virtio0"]?.encoded.contains("ssd=1") == false)
        draft.disks[0].bus = .sata
        #expect(draft.parameters["sata0"]?.encoded.contains("iothread") == false)
        #expect(draft.parameters["sata0"]?.encoded.contains("ro=1") == false)
        // Shares only apply with ballooning.
        draft.ballooning = false
        #expect(draft.parameters["shares"] == nil)
    }

    @Test func diskFormatFollowsTheStorage() throws {
        let json = #"[{"storage":"local","type":"dir","formats":{"supported":["raw","qcow2","vmdk","subvol"],"default":"raw"}},{"storage":"local-lvm","type":"lvmthin","formats":{"supported":["raw"],"default":"raw"}}]"#
        let storages = try JSONDecoder().decode([StorageInfo].self, from: Data(json.utf8))
        #expect(storages[0].diskFormats == ["raw", "qcow2", "vmdk"])
        var draft = VMCreationDraft(node: "pve", vmid: 140)
        draft.disks[0].storage = "local"
        draft.disks[0].chooseFormat(for: storages[0])
        #expect(draft.disks[0].format == "qcow2")
        #expect(draft.parameters["scsi0"] == "local:32,format=qcow2,discard=on,iothread=1")
        draft.disks[0].storage = "local-lvm"
        draft.disks[0].chooseFormat(for: storages[1])
        #expect(draft.disks[0].format == nil)
        #expect(draft.parameters["scsi0"] == "local-lvm:32,discard=on,iothread=1")
    }

    @Test func severalDisks() {
        var draft = VMCreationDraft(node: "pve", vmid: 150)
        draft.isoVolume = "local:iso/debian.iso"
        draft.disks[0].storage = "local-lvm"
        draft.addDisk()
        draft.disks[1].sizeGiB = 100
        draft.disks[1].options.includeInBackup = false
        #expect(draft.disks[1].bus == .scsi && draft.disks[1].storage == "local-lvm")
        #expect(draft.diskKeys == ["scsi0", "scsi1"])
        var parameters = draft.parameters
        #expect(parameters["scsi1"] == "local-lvm:100,discard=on,iothread=1,backup=0")
        #expect(parameters["boot"] == "order=scsi0;ide2;net0")

        // IDE disks skip the CD drives; the OS type moves every disk to its bus.
        draft.applyDefaults(for: "wxp")
        draft.driversISOVolume = "local:iso/virtio-win.iso"
        draft.addDisk()
        #expect(draft.diskKeys == ["ide1", "ide3", "ide4"])
        #expect(draft.problems["ide4"] != nil)
        draft.disks.removeLast()
        #expect(draft.problems.isEmpty)
        parameters = draft.parameters
        #expect(parameters["ide0"] == "local:iso/virtio-win.iso,media=cdrom")
        #expect(parameters["ide1"] == "local-lvm:32,discard=on")

        // A VM can also have no disk.
        draft.disks = []
        #expect(draft.parameters["boot"] == "order=ide2;net0")
    }

    @Test func severalNetworkDevices() {
        var draft = VMCreationDraft(node: "pve", vmid: 160)
        draft.disks[0].storage = "local-lvm"
        draft.networks[0].device.bridge = "vmbr1"
        draft.addNetworkDevice()
        draft.networks[1].device.vlanTag = 30
        #expect(draft.networks[1].device.bridge == "vmbr1")
        var parameters = draft.parameters
        #expect(parameters["net0"] == "model=virtio,bridge=vmbr1,firewall=1")
        #expect(parameters["net1"] == "model=virtio,bridge=vmbr1,tag=30,firewall=1")
        #expect(parameters["boot"] == "order=scsi0;net0")

        // The OS type sets the card of every device, and new ones follow it.
        draft.applyDefaults(for: "win10")
        draft.addNetworkDevice()
        #expect(draft.networks.map(\.device.model) == ["e1000e", "e1000e", "e1000e"])

        draft.networks = []
        parameters = draft.parameters
        #expect(parameters["net0"] == nil)
        #expect(parameters["boot"] == "order=sata0")
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
        draft.networks[0].device.macAddress = "BC:24:11:00:00:02"
        draft.networks[0].device.isDisconnected = true
        draft.networks[0].device.mtu = 1450
        draft.networks[0].device.rateLimit = 10
        draft.networks[0].device.isHostManaged = true
        let parameters = draft.parameters
        #expect(parameters["ha-managed"] == .bool(true))
        #expect(parameters["tags"] == "db")
        #expect(parameters["startup"] == "down=60")
        #expect(parameters["rootfs"] == "local-lvm:8,acl=1,quota=1,replicate=0,mountoptions=discard;noatime")
        #expect(parameters["cpulimit"] == "1.5")
        #expect(parameters["cpuunits"] == "50")
        #expect(parameters["net0"] == "name=eth0,hwaddr=BC:24:11:00:00:02,bridge=vmbr0,firewall=1,link_down=1,ip=dhcp,rate=10.0,mtu=1450,host-managed=1,type=veth")
    }

    @Test func containerMountPoints() {
        var draft = ContainerCreationDraft(node: "pve", vmid: 212)
        draft.template = "local:vztmpl/alpine.tar.xz"
        draft.rootStorage = "local-lvm"
        draft.password = "secret"
        draft.passwordConfirmation = "secret"
        draft.addMountPoint()
        draft.addMountPoint()
        #expect(draft.mountPoints.map(\.storage) == ["local-lvm", "local-lvm"])
        #expect(draft.problems.keys.sorted() == ["mp0", "mp1"])
        draft.mountPoints[0].options.path = "/data"
        draft.mountPoints[1].options.path = "/data"
        #expect(draft.problems.keys.sorted() == ["mp1"])
        draft.mountPoints[1].options.path = " /srv/www "
        draft.mountPoints[1].sizeGiB = 20
        draft.mountPoints[1].options.includeInBackup = false
        draft.mountPoints[1].options.readOnly = true
        draft.mountPoints[1].options.mountOptions = ["noatime"]
        #expect(draft.problems.isEmpty)
        let parameters = draft.parameters
        #expect(parameters["mp0"] == "local-lvm:8,mp=/data,backup=1")
        #expect(parameters["mp1"] == "local-lvm:20,mp=/srv/www,ro=1,mountoptions=noatime")
    }

    @Test func containerNetworkDevices() {
        var draft = ContainerCreationDraft(node: "pve", vmid: 213)
        draft.addNetworkDevice()
        draft.networks[1].device.ipv4Mode = .static
        draft.networks[1].device.ipv4Address = "10.0.0.5/24"
        #expect(draft.networks.map(\.device.name) == ["eth0", "eth1"])
        #expect(draft.problems["net1"] == nil)
        #expect(draft.parameters["net1"] == "name=eth1,bridge=vmbr0,firewall=1,ip=10.0.0.5/24,type=veth")
        draft.networks[1].device.name = "eth0"
        #expect(draft.problems["net1"] != nil)
        draft.networks[1].device.name = " "
        #expect(draft.problems["net1"] != nil)
        draft.networks.removeFirst()
        draft.networks[0].device.name = "eth0"
        draft.addNetworkDevice()
        #expect(draft.networks.map(\.device.name) == ["eth0", "eth1"])
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

    @Test func efiFormatTPMVersionAndPhysicalDrive() {
        var draft = VMCreationDraft(node: "pve", vmid: 122)
        draft.bios = "ovmf"
        draft.efiStorage = "local"
        draft.efiFormat = "qcow2"
        draft.addTPM = true
        draft.tpmStorage = "local-lvm"
        draft.tpmVersion = "v1.2"
        draft.isoVolume = GuestConfig.physicalCDROM
        draft.disks = []
        #expect(draft.problems.isEmpty)
        #expect(draft.parameters["efidisk0"] == "local:1,format=qcow2,efitype=4m,pre-enrolled-keys=1")
        #expect(draft.parameters["tpmstate0"] == "local-lvm:1,version=v1.2")
        #expect(draft.parameters["ide2"] == "cdrom,media=cdrom")
        draft.isoVolume = nil
        draft.networks = []
        // Without boot devices there is no boot order; Proxmox rejects an empty one.
        #expect(draft.parameters["boot"] == nil)
        draft.addEFIDisk = false
        draft.efiStorage = ""
        #expect(draft.problems.isEmpty)
        #expect(draft.parameters["efidisk0"] == nil)
        #expect(draft.parameters["bios"] == "ovmf")
    }

    @Test func armVMsFollowTheWebInterface() {
        var draft = VMCreationDraft(node: "pve", vmid: 123)
        draft.applyDefaults(for: "win11")
        draft.scsiController = "lsi"
        draft.setArchitecture("aarch64")
        #expect(draft.isARM)
        #expect(draft.osType == "l26")
        #expect(draft.bios == "ovmf" && draft.machine == "virt" && !draft.addTPM)
        #expect(draft.scsiController == "virtio-scsi-single")
        #expect(draft.cpu.model.isEmpty)
        #expect(draft.disks[0].bus == .scsi)
        draft.disks[0].storage = "local-lvm"
        draft.efiStorage = "local-lvm"
        draft.isoVolume = "local:iso/debian-13-arm64.iso"
        #expect(draft.problems.isEmpty)
        #expect(draft.diskKeys == ["scsi0"])
        let parameters = draft.parameters
        #expect(parameters["arch"] == "aarch64")
        #expect(parameters["machine"] == nil)
        #expect(parameters["cpu"] == nil)
        #expect(parameters["scsi2"] == "local:iso/debian-13-arm64.iso,media=cdrom")
        #expect(parameters["ide2"] == nil)
        #expect(parameters["boot"] == "order=scsi0;scsi2;net0")

        draft.addDisk()
        draft.addDisk()
        // scsi2 holds the CD/DVD drive.
        #expect(draft.diskKeys == ["scsi0", "scsi1", "scsi3"])
        draft.disks[1].bus = .ide
        #expect(draft.problems.keys.sorted() == ["ide0"])

        draft.setArchitecture("")
        #expect(!draft.isARM && draft.machine == "i440fx" && draft.bios == "seabios")
        #expect(draft.cpu.model == "x86-64-v2-AES")
        #expect(draft.parameters["arch"] == nil)
    }

    @Test func importedDisks() {
        var draft = VMCreationDraft(node: "pve", vmid: 124)
        draft.disks[0].storage = "local-lvm"
        draft.addImportedDisk()
        #expect(draft.disks[1].isImport)
        #expect(draft.problems["scsi1"] != nil)
        draft.disks[1].importSource = "local:import/debian-13-genericcloud-amd64.qcow2"
        #expect(draft.problems.isEmpty)
        #expect(draft.parameters["scsi1"] == "local-lvm:0,import-from=local:import/debian-13-genericcloud-amd64.qcow2,discard=on,iothread=1")
        draft.disks[1].storage = "local"
        draft.disks[1].format = "qcow2"
        #expect(draft.parameters["scsi1"] == "local:0,import-from=local:import/debian-13-genericcloud-amd64.qcow2,format=qcow2,discard=on,iothread=1")
    }
}
