import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

/// Responses recorded from Proxmox VE 9.2.
struct NodeTests {
    @Test func decodesStatus() throws {
        let json = #"""
        {"memory": {"total": 8254115840, "free": 5810253824, "used": 2040315904, "available": 6213799936},
         "swap": {"used": 0, "free": 8250191872, "total": 8250191872},
         "cpuinfo": {"hvm": "1", "mhz": "3092.734", "model": "Intel(R) Xeon(R) Gold 6254 CPU @ 3.10GHz", "sockets": 1, "cores": 6, "cpus": 6},
         "loadavg": ["0.47", "0.45", "0.45"],
         "current-kernel": {"machine": "x86_64", "release": "7.0.14-25-pve", "sysname": "Linux"},
         "kversion": "Linux 7.0.14-25-pve #1 SMP PREEMPT_DYNAMIC", "uptime": 53760, "cpu": 0.0123, "wait": 0.001,
         "boot-info": {"secureboot": 1, "mode": "efi"},
         "rootfs": {"total": 43888205824, "avail": 35289251840, "free": 37551656960, "used": 6336548864},
         "pveversion": "pve-manager/9.2.21/4f6e0ac86f9e8c7f", "idle": 0}
        """#
        let status = try JSONDecoder().decode(NodeStatus.self, from: Data(json.utf8))
        #expect(status.pveVersion == "9.2.21")
        #expect(status.kernel == "7.0.14-25-pve")
        #expect(status.architecture == "x86_64")
        #expect(status.loadAverage == [0.47, 0.45, 0.45])
        #expect(status.cpuCount == 6 && status.cores == 6 && status.sockets == 1)
        #expect(status.memoryUsed == 2_040_315_904 && status.swapTotal == 8_250_191_872)
        #expect(status.rootUsed == 6_336_548_864)
        #expect(status.bootMode == "efi" && status.secureBoot)
        #expect(status.uptime == 53760)
    }

    @Test func decodesNodeHistory() throws {
        let json = #"[{"memavailable": 6242651477.3, "memtotal": 8254115840, "netin": 656.3, "cpu": 0.0514, "netout": 97.2, "memused": 2011464362.6, "iowait": 2.75e-05, "loadavg": 0.431, "time": 1792589340, "maxcpu": 6}]"#
        let point = try #require(try JSONDecoder().decode([RRDPoint].self, from: Data(json.utf8)).first)
        #expect(point.memoryUsed == 2_011_464_362.6)
        #expect(point.memoryTotal == 8_254_115_840)
        #expect(point.loadAverage == 0.431)
        #expect(point.ioWait == 2.75e-05)
        #expect(point.hasData)
    }

    @Test func decodesServicesAndActions() throws {
        let json = #"[{"active-state": "active", "service": "chrony", "desc": "chrony, an NTP client/server", "state": "running", "name": "chrony", "unit-state": "enabled"}, {"active-state": "inactive", "service": "corosync", "state": "dead", "desc": "Corosync Cluster Engine", "name": "corosync", "unit-state": "enabled"}]"#
        let services = try JSONDecoder().decode([NodeService].self, from: Data(json.utf8))
        #expect(services.map(\.name) == ["chrony", "corosync"])
        #expect(services[0].isRunning && !services[1].isRunning)
        #expect(ServiceAction.available(for: services[0]) == [.restart, .reload, .stop])
        #expect(ServiceAction.available(for: services[1]) == [.start])
        let request = PVE.serviceAction(node: "pve", service: "chrony", .restart)
        #expect(request.method == .post && request.path == "/nodes/pve/services/chrony/restart")
    }

    @Test func decodesPackages() throws {
        let json = #"[{"CurrentState": "Installed", "Origin": "Proxmox", "OldVersion": "9.2.0", "RunningKernel": "7.0.14-25-pve", "Package": "proxmox-ve", "Section": "admin", "Title": "Proxmox Virtual Environment", "Priority": "optional", "Version": "9.2.1", "Arch": "all"}]"#
        let package = try #require(try JSONDecoder().decode([PackageVersion].self, from: Data(json.utf8)).first)
        #expect(package.package == "proxmox-ve")
        #expect(package.oldVersion == "9.2.0" && package.version == "9.2.1")
        #expect(package.runningKernel == "7.0.14-25-pve")
    }

    @Test func journalDropsCursorLines() {
        let entries = [
            "s=de89c589a92045408c5afdb154f844ca;i=1648;b=0964883c;m=c8286f29e;t=65e59bf55f916;x=92bc3c5ced6904ce",
            "Oct 21 15:30:46 pve-claude pvedaemon[1064]: <root@pam> successful auth for user 'root@pam'",
            "s=de89c589a92045408c5afdb154f844ca;i=1650;b=0964883c;m=c82a1;t=65e59bf8;x=1",
        ]
        #expect(NodeJournal.lines(entries) == [entries[1]])
    }

    @Test func requests() {
        #expect(PVE.nodePower("pve", .reboot).parameters.formEncoded == "command=reboot")
        #expect(PVE.refreshPackageIndex(node: "pve").method == .post)
        #expect(PVE.journal(node: "pve").parameters.formEncoded == "lastentries=500")
        #expect(PVE.nodeTasks(node: "pve", limit: 50).parameters.formEncoded == "limit=50&source=all")
    }
}
