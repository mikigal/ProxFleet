import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct CloudInitTests {
    private let config = GuestConfig(values: [
        "ciuser": "admin", "cipassword": "**********",
        "sshkeys": "ssh-ed25519%20AAAAC3Nza%20me%40mac%0Assh-rsa%20AAAAB3%20other",
        "net0": "virtio=BC:24:11:00:00:01,bridge=vmbr0", "ipconfig0": "ip=10.0.0.5/24,gw=10.0.0.1",
        "ide2": "local-lvm:vm-100-cloudinit,media=cdrom",
    ])

    @Test func readsSettings() {
        let draft = CloudInitDraft(config)
        #expect(draft.user == "admin")
        #expect(draft.hasPassword)
        #expect(draft.sshKeys == ["ssh-ed25519 AAAAC3Nza me@mac", "ssh-rsa AAAAB3 other"])
        #expect(draft.ipConfigs["net0"]?.ipv4Mode == .static)
        #expect(draft.ipConfigs["net0"]?.ipv4Address == "10.0.0.5/24")
        #expect(draft.update(from: draft).isEmpty)
        #expect(config.cloudInitDrive?.key == "ide2")
    }

    @Test func passwordIsOnlySentWhenChanged() {
        let original = CloudInitDraft(config)
        var draft = original
        draft.newPassword = "s3cret"
        #expect(draft.update(from: original).values == ["cipassword": "s3cret"])
        draft.newPassword = ""
        draft.removesPassword = true
        #expect(draft.update(from: original).deletions == ["cipassword"])
    }

    @Test func keysAndAddressesAreEncoded() {
        let original = CloudInitDraft(config)
        var draft = original
        draft.sshKeys = ["ssh-ed25519 AAAA+/= me@mac"]
        draft.ipConfigs["net0"]?.ipv4Mode = .dhcp
        draft.ipConfigs["net0"]?.ipv6Mode = .slaac
        let update = draft.update(from: original)
        #expect(update.values["sshkeys"] == "ssh-ed25519%20AAAA%2B%2F%3D%20me%40mac")
        #expect(update.values["ipconfig0"] == "ip=dhcp,ip6=auto")
    }
}
