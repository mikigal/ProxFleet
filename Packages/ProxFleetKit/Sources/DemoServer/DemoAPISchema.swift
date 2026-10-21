import Foundation

/// A small API schema in the shape of the API viewer's `apidoc.js`, covering the guest configuration keys
/// the demo knows, so All Settings works without a server.
enum DemoAPISchema {
    static let apidoc: Data = {
        let tree: JSONValue = [[
            "path": "/nodes", "text": "nodes",
            "children": [
                ["path": "/nodes/{node}/qemu/{vmid}/config", "text": "config", "leaf": 1, "info": ["POST": method(vmParameters)]],
                ["path": "/nodes/{node}/lxc/{vmid}/config", "text": "config", "leaf": 1, "info": ["PUT": method(containerParameters)]],
            ],
        ]]
        var text = Data("const apiSchema = ".utf8)
        text.append(tree.encoded())
        text.append(Data("\n;\n\nlet method2cmd = {};\n".utf8))
        return text
    }()

    private static func method(_ properties: [String: JSONValue]) -> JSONValue {
        ["method": "POST", "parameters": ["additionalProperties": 0, "properties": .object(properties)]]
    }

    // MARK: - Parameter builders

    private static func flag(_ description: String, default value: Int = 0) -> JSONValue {
        ["type": "boolean", "optional": 1, "default": .int(value), "description": .string(description), "typetext": "<boolean>"]
    }

    private static func integer(_ description: String, min: Int? = nil, max: Int? = nil, default value: Int? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": "integer", "optional": 1, "description": .string(description)]
        if let min { fields["minimum"] = .int(min) }
        if let max { fields["maximum"] = .int(max) }
        if let value { fields["default"] = .int(value) }
        return .object(fields)
    }

    private static func number(_ description: String, min: Double? = nil, max: Double? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": "number", "optional": 1, "description": .string(description)]
        if let min { fields["minimum"] = .double(min) }
        if let max { fields["maximum"] = .double(max) }
        return .object(fields)
    }

    private static func text(_ description: String, typeText: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": "string", "optional": 1, "description": .string(description)]
        if let typeText { fields["typetext"] = .string(typeText) }
        return .object(fields)
    }

    private static func choice(_ description: String, _ values: [String], default value: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": "string", "optional": 1, "description": .string(description), "enum": .array(values.map { .string($0) })]
        if let value { fields["default"] = .string(value) }
        return .object(fields)
    }

    private static func properties(_ description: String, _ keys: [String: JSONValue]) -> JSONValue {
        ["type": "string", "optional": 1, "description": .string(description), "format": .object(keys)]
    }

    private static func defaultKey(_ field: JSONValue) -> JSONValue {
        guard case .object(var fields) = field else { return field }
        fields["default_key"] = 1
        fields["optional"] = nil
        return .object(fields)
    }

    // MARK: - Shared keys

    private static let shared: [String: JSONValue] = [
        "cores": integer("Number of CPU cores.", min: 1, max: 8192),
        "cpulimit": number("Limit of CPU time, in cores. 0 means no limit.", min: 0, max: 8192),
        "cpuunits": integer("Weight of this guest when the host is busy.", min: 1, max: 10000),
        "memory": text("Memory in MiB.", typeText: "<integer> (16 - N)"),
        "onboot": flag("Start this guest when the host boots."),
        "protection": flag("Prevent removing the guest and its disks."),
        "tags": text("Tags separated by semicolons.", typeText: "<tag>[;<tag>...]"),
        "description": text("Notes shown in the Summary of the web interface."),
        "startup": text("Start and shutdown order and delays.", typeText: "[[order=]\\d+] [,up=\\d+] [,down=\\d+]"),
        "hookscript": text("Script run at each step of the guest's lifecycle.", typeText: "<volume>"),
    ]

    // MARK: - VMs

    private static var vmParameters: [String: JSONValue] {
        var keys = shared
        keys.merge([
            "acpi": flag("Enable ACPI.", default: 1),
            "affinity": text("Host cores the VM may run on.", typeText: "<cpuset>"),
            "agent": properties("QEMU Guest Agent and its options.", [
                "enabled": defaultKey(flag("Talk to a guest agent in the VM.")),
                "freeze-fs": flag("Freeze file systems for consistent backups.", default: 1),
                "fstrim_cloned_disks": flag("Trim disks after moving or cloning them."),
                "type": choice("Agent device type.", ["virtio", "isa"], default: "virtio"),
            ]),
            "args": text("Extra arguments passed to KVM. For experts only.", typeText: "<string>"),
            "autostart": flag("Restart the VM automatically after a crash."),
            "balloon": integer("Minimum memory in MiB with ballooning; 0 disables the balloon device.", min: 0),
            "bios": choice("Firmware.", ["seabios", "ovmf"], default: "seabios"),
            "boot": text("Boot order.", typeText: "[order=<device[;device...]>]"),
            "cpu": text("Emulated CPU type and flags.", typeText: "[[cputype=]<string>] [,flags=<+FLAG[;-FLAG...]>]"),
            "freeze": flag("Do not start the CPU at startup."),
            "hotplug": text("Device kinds that can be hot-plugged.", typeText: "network,disk,usb,memory,cpu"),
            "keyboard": choice("Keyboard layout for the VNC console.", ["de", "en-gb", "en-us", "es", "fr", "it", "pl", "pt"]),
            "kvm": flag("Hardware virtualization.", default: 1),
            "localtime": flag("Run the clock in local time."),
            "machine": text("Machine type and version.", typeText: "[[type=]<machine>] [,viommu=<intel|virtio>]"),
            "name": text("Name of the VM."),
            "numa": flag("NUMA emulation."),
            "numa[n]": properties("NUMA topology.", [
                "cpus": text("CPUs of this node.", typeText: "id[-id];..."),
                "hostnodes": text("Host NUMA nodes to use.", typeText: "id[-id];..."),
                "memory": number("Memory of this node in MiB."),
                "policy": choice("NUMA allocation policy.", ["preferred", "bind", "interleave"]),
            ]),
            "ostype": choice("Guest operating system.", ["other", "wxp", "w2k", "w2k3", "w2k8", "wvista", "win7", "win8", "win10", "win11", "l24", "l26", "solaris"]),
            "reboot": flag("Allow reboots; when off, a reboot stops the VM.", default: 1),
            "scsihw": choice("SCSI controller model.", ["lsi", "lsi53c810", "virtio-scsi-pci", "virtio-scsi-single", "megasas", "pvscsi"], default: "lsi"),
            "shares": integer("Memory shares for auto-ballooning.", min: 0, max: 50000, default: 1000),
            "sockets": integer("Number of CPU sockets.", min: 1, default: 1),
            "startdate": text("Initial date of the real-time clock.", typeText: "(now | YYYY-MM-DD | YYYY-MM-DDTHH:MM:SS)"),
            "tablet": flag("Use a USB tablet as pointer.", default: 1),
            "tdf": flag("Time drift fix."),
            "vcpus": integer("vCPUs plugged in at start.", min: 1),
            "vga": properties("Display.", [
                "type": defaultKey(choice("Display type.", ["std", "virtio", "qxl", "vmware", "serial0", "none"], default: "std")),
                "memory": integer("Display memory in MiB.", min: 4, max: 512),
                "clipboard": choice("Clipboard to share.", ["vnc"]),
            ]),
            "watchdog": text("Watchdog device and action.", typeText: "[[model=]<i6300esb|ib700>] [,action=<enum>]"),
            "net[n]": properties("Network device.", [
                "model": defaultKey(choice("Network card model.", ["virtio", "e1000", "e1000e", "rtl8139", "vmxnet3"])),
                "virtio": ["alias": "macaddr", "keyAlias": "model"],
                "e1000": ["alias": "macaddr", "keyAlias": "model"],
                "macaddr": text("MAC address."),
                "bridge": text("Bridge to attach to."),
                "tag": integer("VLAN tag.", min: 1, max: 4094),
                "firewall": flag("Use the firewall."),
                "mtu": integer("MTU.", min: 1, max: 65520),
            ]),
            "serial[n]": text("Serial port: socket or a host device.", typeText: "(/dev/.+|socket)"),
            "scsi[n]": text("SCSI disk or drive.", typeText: "[file=]<volume> [,option=value...]"),
            "virtio[n]": text("VirtIO block disk.", typeText: "[file=]<volume> [,option=value...]"),
            "sata[n]": text("SATA disk or drive.", typeText: "[file=]<volume> [,option=value...]"),
            "ide[n]": text("IDE disk or CD/DVD drive.", typeText: "[file=]<volume> [,media=cdrom]"),
            "efidisk0": text("Disk for the UEFI variables.", typeText: "[file=]<volume> [,efitype=4m]"),
            "tpmstate0": text("Disk for the TPM state.", typeText: "[file=]<volume> [,version=v2.0]"),
            "unused[n]": text("Disk that belongs to the VM but is not attached.", typeText: "[file=]<volume>"),
            "usb[n]": text("USB device.", typeText: "[host=]<vendor:product|bus-port|spice> [,usb3=1]"),
            "hostpci[n]": text("PCI device passed through from the host.", typeText: "[host=]<address> [,pcie=1]"),
        ]) { _, new in new }
        return keys
    }

    // MARK: - Containers

    private static var containerParameters: [String: JSONValue] {
        var keys = shared
        keys.merge([
            "arch": choice("Architecture.", ["amd64", "i386", "arm64", "armhf"], default: "amd64"),
            "cmode": choice("Console mode.", ["shell", "console", "tty"], default: "tty"),
            "console": flag("Attach a console device.", default: 1),
            "debug": flag("Extra debug logging when starting."),
            "features": properties("Extra features.", [
                "nesting": flag("Allow nested containers, e.g. Docker."),
                "keyctl": flag("Allow the keyctl() system call."),
                "fuse": flag("Allow FUSE file systems."),
                "mknod": flag("Allow creating device nodes."),
                "mount": text("Allowed file system types to mount.", typeText: "<fstype;fstype;...>"),
            ]),
            "hostname": text("Host name of the container."),
            "nameserver": text("DNS servers."),
            "ostype": choice("Distribution, for setup inside the container.", ["debian", "devuan", "ubuntu", "centos", "fedora", "opensuse", "archlinux", "alpine", "gentoo", "nixos", "unmanaged"]),
            "searchdomain": text("DNS search domain."),
            "swap": integer("Swap in MiB.", min: 0, default: 512),
            "timezone": text("Time zone, or host to use the host's."),
            "tty": integer("Number of TTYs.", min: 0, max: 6, default: 2),
            "unprivileged": flag("Run as an unprivileged user. Set at creation only."),
            "dev[n]": text("Device passed through to the container.", typeText: "[[path=]<path>] [,mode=<octal>]"),
            "rootfs": text("Root file system.", typeText: "[volume=]<volume> [,size=<size>]"),
            "mp[n]": text("Mount point.", typeText: "[volume=]<volume>, mp=<path> [,backup=1]"),
            "unused[n]": text("Volume that belongs to the container but is not mounted.", typeText: "[volume=]<volume>"),
            "net[n]": text("Network interface.", typeText: "name=<string> [,bridge=<bridge>] [,ip=<cidr|dhcp>]"),
        ]) { _, new in new }
        return keys
    }
}
