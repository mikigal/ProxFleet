import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct DeviceDraftTests {
    @Test func deviceKindsFromKeys() {
        #expect(VMDeviceKind(key: "hostpci3") == .pci)
        #expect(VMDeviceKind(key: "usb0") == .usb)
        #expect(VMDeviceKind(key: "ivshmem") == .ivshmem)
        #expect(VMDeviceKind(key: "serial") == nil)
        #expect(VMDeviceKind(key: "scsi0") == nil)
        let config = GuestConfig(values: ["usb0": "host=spice", "serial0": "socket", "efidisk0": "x", "audio0": "device=AC97,driver=none"])
        #expect(config.otherDevices.map(\.key) == ["audio0", "serial0", "usb0"])
        #expect(VMDeviceKind.usb.nextKey(in: config) == "usb1")
        #expect(VMDeviceKind.audio.nextKey(in: config) == nil)
    }

    @Test func usbSources() {
        #expect(USBDeviceDraft("host=spice").source == .spice)
        let host = USBDeviceDraft("host=0627:0001,usb3=1")
        #expect(host.source == .host)
        #expect(host.host == "0627:0001")
        #expect(host.usb3)
        #expect(host.stringValue == "host=0627:0001,usb3=1")
        var mapped = USBDeviceDraft()
        mapped.source = .mapping
        mapped.mapping = "keyboard"
        #expect(mapped.stringValue == "mapping=keyboard")
    }

    @Test func pciFunctionsAndOptions() {
        let draft = PCIDeviceDraft("0000:01:00,pcie=1,x-vga=1")
        #expect(draft.allFunctions)
        #expect(draft.pcie)
        #expect(draft.primaryGPU)
        #expect(draft.stringValue == "host=0000:01:00,pcie=1,x-vga=1")
        var single = PCIDeviceDraft()
        single.host = "0000:02:00.1"
        single.romBar = false
        #expect(single.stringValue == "host=0000:02:00.1,rombar=0")
        single.allFunctions = true
        #expect(single.stringValue == "host=0000:02:00,rombar=0")
    }

    @Test func smallDevices() {
        #expect(RNGDeviceDraft("source=/dev/urandom").stringValue == "source=/dev/urandom")
        var rng = RNGDeviceDraft()
        rng.maxBytes = 0
        #expect(rng.stringValue == "source=/dev/urandom,max_bytes=0")
        #expect(AudioDeviceDraft("device=AC97,driver=none") == { var a = AudioDeviceDraft(); a.device = "AC97"; a.driver = "none"; return a }())
        var fs = VirtioFSDraft()
        fs.directory = "share"
        fs.exposeACL = true
        fs.exposeXattr = true
        #expect(fs.stringValue == "dirid=share,expose-acl=1")
        #expect(IVSHMEMDraft("size=64,name=lg").stringValue == "size=64,name=lg")
        #expect(GuestConfig.efiDiskValue(storage: "local-lvm", preEnrolledKeys: true) == "local-lvm:1,efitype=4m,pre-enrolled-keys=1,ms-cert=2023k")
    }

    @Test func nodeDevicesDecode() throws {
        let usb = try JSONDecoder().decode(NodeUSBDevice.self, from: Data(#"{"busnum":2,"usbpath":"1","vendid":"0627","prodid":"0001","product":"QEMU USB Tablet","class":0}"#.utf8))
        #expect(usb.deviceID == "0627:0001")
        #expect(usb.portID == "2-1")
        #expect(!usb.isHub)
        let pci = try JSONDecoder().decode(NodePCIDevice.self, from: Data(#"{"id":"0000:00:1a.0","vendor_name":"Intel","iommugroup":-1,"mdev":1}"#.utf8))
        #expect(pci.mdev == true)
    }
}
