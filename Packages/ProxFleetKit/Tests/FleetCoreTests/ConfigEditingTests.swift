import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct GuestConfigEditingTests {
    private func detail(vmid: Int, node: String) async throws -> GuestDetail {
        let transport = DemoTransport(cluster: .homelab)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: "root", realm: "pam"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        let detail = GuestDetail(reference: GuestReference(node: node, vmid: vmid, kind: .virtualMachine), connection: connection)
        await detail.load()
        return detail
    }

    @Test func newDisksAreAllocatedAndDetachedDisksKept() async throws {
        let detail = try await detail(vmid: 102, node: "pve2")
        var update = GuestConfigUpdate()
        update.set("scsi1", "local-lvm:8,discard=on")
        update.set("tpmstate0", "local-lvm:1,version=v2.0")
        try await detail.apply(update)
        #expect(detail.config?["scsi1"] == "local-lvm:vm-102-disk-3,discard=on,size=8G")
        #expect(detail.config?["tpmstate0"]?.hasPrefix("local-lvm:vm-102-disk-") == true)

        var removal = GuestConfigUpdate()
        removal.set("scsi1", nil)
        try await detail.apply(removal)
        #expect(detail.config?["scsi1"] == nil)
        #expect(detail.config?["unused0"] == "local-lvm:vm-102-disk-3")
    }

    @Test func disksMoveBetweenStoragesAndGuests() async throws {
        let detail = try await detail(vmid: 103, node: "pve2")
        try await detail.run(PVE.moveDisk(detail.reference, disk: "scsi0", storage: "local", deleteSource: false))
        #expect(detail.config?["scsi0"]?.hasPrefix("local:vm-103-disk-1,") == true)
        #expect(detail.config?["unused0"] == "local-lvm:vm-103-disk-0")

        try await detail.run(PVE.reassignDisk(detail.reference, disk: "unused0", to: 102, as: "unused5"))
        #expect(detail.config?["unused0"] == nil)
        let target = try await detail.connection.send(PVE.guestConfig(GuestReference(node: "pve2", vmid: 102, kind: .virtualMachine)))
        #expect(target["unused5"]?.hasPrefix("local-lvm:vm-102-disk-") == true)
    }

    @Test func stoppedVMChangesApplyImmediately() async throws {
        let detail = try await detail(vmid: 102, node: "pve2")
        var update = GuestConfigUpdate()
        update.set("memory", "16384")
        update.set("cores", "8")
        update.set("onboot", true)
        try await detail.apply(update)

        #expect(detail.config?.memoryMiB == 16384)
        #expect(detail.config?.cores == 8)
        #expect(detail.config?.startsOnBoot == true)
        #expect(detail.pendingChanges.isEmpty)
    }

    @Test func runningVMHardwareChangesWaitForRestart() async throws {
        let detail = try await detail(vmid: 100, node: "pve1")
        var update = GuestConfigUpdate()
        update.set("memory", "8192")
        update.set("description", "Changed live")
        try await detail.apply(update)

        #expect(detail.config?.memoryMiB == 4096)
        #expect(detail.config?.description == "Changed live")
        #expect(detail.pendingChange(for: "memory")?.pending == "8192")

        try await detail.revertPendingChanges()
        #expect(detail.pendingChanges.isEmpty)
        #expect(detail.config?.memoryMiB == 4096)
    }

    @Test func validationErrorsArePerField() async throws {
        let detail = try await detail(vmid: 102, node: "pve2")
        var update = GuestConfigUpdate()
        update.set("cores", "0")
        await #expect(throws: ConfigUpdateError.invalid(message: "Parameter verification failed.", fields: ["cores": "value must have a minimum value of 1"])) {
            try await detail.apply(update)
        }
    }

    @Test func outdatedDigestIsAConflict() async throws {
        let detail = try await detail(vmid: 102, node: "pve2")
        let staleDigest = try #require(detail.config?.digest)
        var first = GuestConfigUpdate()
        first.set("description", "first")
        try await detail.apply(first)

        var second = GuestConfigUpdate(digest: staleDigest)
        second.set("description", "second")
        await #expect(throws: ConfigUpdateError.conflict) {
            try await detail.apply(second)
        }
        #expect(detail.config?.description == "first")
    }

    @Test func addNetworkDeviceAndGrowDisk() async throws {
        let detail = try await detail(vmid: 102, node: "pve2")
        let config = try #require(detail.config)
        var nic = NetworkDeviceDraft()
        nic.bridge = "vmbr1"
        nic.vlanTag = 30
        var update = GuestConfigUpdate()
        update.set(try #require(config.nextFreeKey(prefix: "net", slots: 32)), nic.stringValue)
        try await detail.apply(update)
        #expect(detail.config?.networks.map(\.key) == ["net0", "net1"])
        #expect(detail.config?.networks.last?.vlanTag == "30")

        try await detail.growDisk("scsi0", byGiB: 4)
        #expect(detail.config?.disks.first { $0.key == "scsi0" }?.size == "132G")
    }
}
