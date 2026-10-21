import Foundation
import ProxmoxCore
@testable import PVEKit
import Testing

private struct Envelope<T: Decodable>: Decodable {
    var data: T
}

private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/pve-9.2-standalone"))
    return try JSONDecoder().decode(Envelope<T>.self, from: Data(contentsOf: url)).data
}

struct PropertyStringTests {
    @Test func parsesKeylessFirstItemAndOptions() {
        let disk = PropertyString(parsing: "local-lvm:vm-100-disk-0,size=4G,ssd=1")
        #expect(disk.defaultValue == "local-lvm:vm-100-disk-0")
        #expect(disk["size"] == "4G")
        #expect(disk["ssd"] == "1")
        #expect(disk["missing"] == nil)
    }

    @Test func respectsQuotedCommas() {
        let value = PropertyString(parsing: #"name=eth0,ip="10.0.0.1/24,x",gw=10.0.0.254"#)
        #expect(value["ip"] == "10.0.0.1/24,x")
        #expect(value["gw"] == "10.0.0.254")
    }

    @Test func parsesUPID() throws {
        let upid = try #require(UPID("UPID:pve-claude:00002EE8:0004758A:6AD7F7F0:qmpause:102:root@pam:"))
        #expect(upid.node == "pve-claude")
        #expect(upid.type == "qmpause")
        #expect(upid.objectID == "102")
        #expect(upid.user == "root@pam")
        #expect(upid.startTime == Date(timeIntervalSince1970: 0x6AD7F7F0))
        #expect(UPID("not a upid") == nil)
    }
}

struct GuestModelTests {
    @Test func runningStoppedAndPausedStatus() throws {
        let running = try fixture("qemu-100-status", as: GuestStatus.self)
        #expect(running.powerState == .running)
        #expect(running.cpuCount == 2)
        #expect(running.memoryTotal == 1_073_741_824)
        #expect(running.agentEnabled)
        #expect(running.runningQEMU != nil)
        #expect(running.tags == ["prod", "web"])

        #expect(try fixture("qemu-101-status", as: GuestStatus.self).powerState == .stopped)

        let paused = try fixture("qemu-102-status-paused", as: GuestStatus.self)
        #expect(paused.status == "running")
        #expect(paused.powerState == .paused)

        let container = try fixture("lxc-200-status", as: GuestStatus.self)
        #expect(container.powerState == .running)
        #expect(container.swapTotal == 536_870_912)
    }

    @Test func vmConfigHardware() throws {
        let config = try fixture("qemu-101-config", as: GuestConfig.self)
        #expect(config.name == "windows-test")
        #expect(config.memoryMiB == 2048)
        #expect(config.cores == 2)
        #expect(config.sockets == 1)
        #expect(config.bios == "ovmf")
        #expect(config.osTypeDescription == "Windows 11/2022/2025")
        #expect(config.agentEnabled)
        #expect(config.bootOrder == ["scsi0", "net0"])
        #expect(config.digest?.count == 40)

        #expect(config.disks.map(\.key) == ["efidisk0", "scsi0"])
        let disk = try #require(config.disks.last)
        #expect(disk.volume == "local-lvm:vm-101-disk-1")
        #expect(disk.size == "4G")
        #expect(!disk.isCDROM)

        let nic = try #require(config.networks.first)
        #expect(nic.key == "net0")
        #expect(nic.model == "virtio")
        #expect(nic.macAddress == "BC:24:11:BC:2F:86")
        #expect(nic.bridge == "vmbr0")
        #expect(!nic.firewall)
    }

    @Test func containerConfig() throws {
        let config = try fixture("lxc-200-config", as: GuestConfig.self)
        #expect(config.name == "alpine-dns")
        #expect(config.swapMiB == 512)
        #expect(config.isUnprivileged)
        #expect(config.disks.map(\.key) == ["rootfs"])
        #expect(config.disks.first?.size == "1G")
        let nic = try #require(config.networks.first)
        #expect(nic.model == "eth0")
        #expect(nic.macAddress == "BC:24:11:8F:45:9C")
        #expect(nic.ipv4 == "dhcp")
    }

    @Test func rrdSkipsEmptySamples() throws {
        let points = try fixture("qemu-100-rrddata-hour", as: [RRDPoint].self)
        #expect(points.count == 60)
        let filled = points.filter(\.hasData)
        #expect(!filled.isEmpty)
        #expect(filled.allSatisfy { $0.cpu != nil && $0.memoryTotal != nil })
    }

    @Test func containerInterfacesWithoutLoopbackAndLinkLocal() throws {
        let raw = try fixture("lxc-200-interfaces", as: [RawInterface].self)
        let interfaces = raw.map { GuestNetworkInterface(name: $0.name, macAddress: $0.hardwareAddress, addresses: $0.addresses) }.filter(\.isUseful)
        #expect(interfaces.map(\.name) == ["eth0"])
        #expect(interfaces.first?.addresses == ["10.10.100.131/24"])
    }

    @Test func permissionsAndTasks() throws {
        let permissions = try fixture("permissions-vm100", as: [String: [String: Int]].self)
        #expect(permissions["/vms/100"]?["VM.PowerMgmt"] == 1)

        let done = try fixture("task-status-done", as: TaskStatus.self)
        #expect(!done.isRunning)
        #expect(done.succeeded)
        let failed = try fixture("task-status-failed", as: TaskStatus.self)
        #expect(!failed.succeeded)
        #expect(failed.exitStatus == "VM 100 already running")
        #expect(try fixture("task-log-failed", as: [TaskLogLine].self).first?.text == "TASK ERROR: VM 100 already running")

        let tasks = try fixture("cluster-tasks", as: [ClusterTask].self)
        #expect(!tasks.isEmpty)
        #expect(tasks.allSatisfy { UPID($0.upid) != nil })
    }

    @Test func powerActionsDependOnState() {
        #expect(PowerAction.available(for: .virtualMachine, state: .stopped, isTemplate: false) == [.start])
        #expect(PowerAction.available(for: .virtualMachine, state: .running, isTemplate: false).contains(.reset))
        #expect(!PowerAction.available(for: .container, state: .running, isTemplate: false).contains(.reset))
        #expect(PowerAction.available(for: .virtualMachine, state: .paused, isTemplate: false) == [.resume, .stop])
        #expect(PowerAction.available(for: .virtualMachine, state: .stopped, isTemplate: true).isEmpty)
        #expect(PVE.powerAction(.pause, on: GuestReference(node: "n", vmid: 1, kind: .virtualMachine)).path == "/nodes/n/qemu/1/status/suspend")
        #expect(PVE.powerAction(.hibernate, on: GuestReference(node: "n", vmid: 1, kind: .virtualMachine)).parameters["todisk"] == .bool(true))
    }

    @Test func taskTitles() {
        #expect(TaskDescription.title(type: "qmstart", objectID: "100") == "VM 100 – Start")
        #expect(TaskDescription.title(type: "vzshutdown", objectID: "200") == "CT 200 – Shutdown")
        #expect(TaskDescription.title(type: "vzdump", objectID: "100") == "VM/CT 100 – Backup")
        #expect(TaskDescription.title(type: "aptupdate", objectID: nil) == "Update Package Database")
    }
}
