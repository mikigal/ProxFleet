import Foundation
@testable import PVEKit
import Testing

struct OptionsDraftTests {
    private let vmConfig = GuestConfig(values: [
        "name": "web", "onboot": "1", "ostype": "l26", "agent": "1,fstrim_cloned_disks=1", "tags": "prod;web",
        "smbios1": "uuid=fd9d79ea-50ae-4b26-8cb3-cb35c16723be", "hotplug": "network,disk,usb", "startup": "order=2,up=30",
    ])

    @Test func unchangedDraftProducesNoUpdate() {
        let draft = VMOptionsDraft(vmConfig)
        #expect(draft.changes(from: VMOptionsDraft(vmConfig)).isEmpty)
        let container = ContainerOptionsDraft(GuestConfig(values: ["hostname": "dns", "features": "nesting=1,keyctl=1", "env": "A=1\u{0}B=two"]))
        #expect(container.changes(from: container).isEmpty)
    }

    @Test func onlyChangedOptionsAreSent() {
        let original = VMOptionsDraft(vmConfig)
        var draft = original
        draft.tags.append("db")
        draft.hotplug.insert("memory")
        draft.agentFreezeFS = false
        let update = draft.changes(from: original)
        #expect(update.values == [
            "tags": "prod;web;db",
            "hotplug": "network,disk,usb,memory",
            "agent": "enabled=1,freeze-fs=0,fstrim_cloned_disks=1",
        ])
        #expect(update.deletions.isEmpty)
    }

    @Test func defaultsAreDeleted() {
        let original = VMOptionsDraft(GuestConfig(values: ["tablet": "0", "hotplug": "0", "keyboard": "de"]))
        #expect(!original.tablet)
        #expect(original.hotplug.isEmpty)
        var draft = original
        draft.tablet = true
        draft.hotplug = ["network", "disk", "usb"]
        draft.keyboard = ""
        let update = draft.changes(from: original)
        #expect(update.deletions == ["tablet", "hotplug", "keyboard"])
    }

    @Test func smbiosTextIsBase64AndUUIDKept() {
        let original = VMOptionsDraft(vmConfig)
        var draft = original
        draft.smbios.manufacturer = "ProxFleet, Inc."
        let update = draft.changes(from: original)
        #expect(update.values["smbios1"] == "base64=1,manufacturer=UHJveEZsZWV0LCBJbmMu,uuid=fd9d79ea-50ae-4b26-8cb3-cb35c16723be")
        // Reading it back decodes the value.
        let reread = VMOptionsDraft(GuestConfig(values: ["smbios1": update.values["smbios1"]!]))
        #expect(reread.smbios.manufacturer == "ProxFleet, Inc.")
    }

    @Test func agentAliasesAreRead() {
        let draft = VMOptionsDraft(GuestConfig(values: ["agent": "enabled=1,freeze-fs-on-backup=0,type=isa"]))
        #expect(draft.agentEnabled)
        #expect(!draft.agentFreezeFS)
        #expect(draft.agentType == "isa")
    }

    @Test func containerFeaturesAndEnvironment() {
        let original = ContainerOptionsDraft(GuestConfig(values: ["hostname": "dns", "features": "nesting=1", "unprivileged": "1"]))
        var draft = original
        draft.keyctl = true
        draft.mountTypes = ["nfs"]
        draft.environment = [.init(name: "TZ", value: "UTC"), .init(name: "", value: "ignored")]
        draft.ttyCount = 4
        let update = draft.changes(from: original)
        #expect(update.values == ["features": "nesting=1,keyctl=1,mount=nfs", "env": "TZ=UTC", "tty": "4"])
        #expect(draft.isUnprivileged)
    }

    @Test func tagRules() {
        #expect(TagRules.normalize(" Prod ") == "prod")
        #expect(TagRules.normalize("k8s-node.1") == "k8s-node.1")
        #expect(TagRules.normalize("-bad") == nil)
        #expect(TagRules.normalize("with space") == nil)
    }
}
