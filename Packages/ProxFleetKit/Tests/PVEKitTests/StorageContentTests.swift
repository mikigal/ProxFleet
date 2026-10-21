import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

/// Storage status and content, with responses recorded from Proxmox VE 9.2.
struct StorageContentTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func volumes() throws {
        let volumes = try decode([StorageVolume].self, #"""
        [{"volid": "local:iso/alpine-virt-3.24.2-x86_64.iso", "content": "iso", "size": 69206016, "ctime": 1792542411, "format": "iso"},
         {"volid": "local-lvm:base-9000-disk-0", "content": "images", "size": 4294967296, "vmid": 9000, "ctime": "1792538019", "format": "raw"},
         {"volid": "pbs:backup/vm/100/2026-10-20T10:00:00Z", "content": "backup", "approximate-size": 1048576, "notes": "nightly\n", "protected": 1}]
        """#)
        #expect(volumes[0].fileName == "alpine-virt-3.24.2-x86_64.iso" && volumes[0].content == "iso" && volumes[0].format == "iso")
        #expect(volumes[0].created == Date(timeIntervalSince1970: 1_792_542_411))
        #expect(volumes[1].vmid == 9000 && volumes[1].created == Date(timeIntervalSince1970: 1_792_538_019))
        #expect(volumes[2].size == 1_048_576 && volumes[2].notes == "nightly" && volumes[2].isProtected)
    }

    @Test func statusAndMetadata() throws {
        let status = try decode(StorageStatus.self, #"{"avail": 35277590528, "active": 1, "shared": 0, "used": 6348210176, "enabled": 1, "type": "dir", "content": "backup,vztmpl,iso,import", "total": 43888205824}"#)
        #expect(status.isActive && !status.isShared && status.type == "dir")
        #expect(status.contentTypes == [.iso, .vztmpl, .backup, .import])
        let metadata = try decode(URLMetadata.self, #"{"filename": "alpine-virt-3.22.2-x86_64.iso", "size": 68157440, "mimetype": "application/octet-stream"}"#)
        #expect(metadata.fileName == "alpine-virt-3.22.2-x86_64.iso" && metadata.size == 68_157_440)
    }

    @Test func fileDrafts() {
        #expect(StorageFileDraft.fileName(from: "https://example.com/isos/debian%2013.iso?token=1") == "debian 13.iso")
        var draft = StorageFileDraft(content: .iso)
        draft.url = "ftp://example.com/x.iso"
        draft.fileName = "x.qcow2"
        draft.checksum = "xyz"
        #expect(draft.problems().keys.sorted() == ["checksum", "filename", "url"])
        #expect(draft.problems(forUpload: true).keys.sorted() == ["checksum", "filename"])
        draft.url = "https://example.com/x.iso"
        draft.fileName = "x.iso"
        draft.checksum = "ABCDEF12"
        draft.verifyCertificates = false
        #expect(draft.problems().isEmpty)
        #expect(PVE.downloadURL(node: "pve", storage: "local", draft).parameters.formEncoded
            == "content=iso&filename=x.iso&checksum-algorithm=sha256&checksum=abcdef12&url=https%3A%2F%2Fexample.com%2Fx.iso&verify-certificates=0")
        #expect(PVE.uploadFile(node: "pve", storage: "local", draft).parameters.formEncoded == "content=iso&checksum-algorithm=sha256&checksum=abcdef12")
        var template = StorageFileDraft(content: .vztmpl)
        template.fileName = "alpine-3.22-default_20250617_amd64.tar.xz"
        #expect(template.problems(forUpload: true).isEmpty)
        #expect(PVE.deleteVolume(node: "pve", storage: "local", volume: "local:iso/x.iso").path == "/nodes/pve/storage/local/content/local:iso%2Fx.iso")
    }

    @Test func multipartBodyStreamsTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "image.iso")
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        try payload.write(to: source)

        let body = try MultipartBody.write(fields: [("content", "iso"), ("checksum", "abc")], fileField: "filename",
                                           fileName: "my \"image\".iso", source: source, directory: directory)
        let data = try Data(contentsOf: body.file)
        let text = String(decoding: data.prefix(400), as: UTF8.self)
        #expect(text.hasPrefix("--\(body.boundary)\r\nContent-Disposition: form-data; name=\"content\"\r\n\r\niso\r\n"))
        #expect(text.contains("name=\"filename\"; filename=\"my _image_.iso\""))
        #expect(data.range(of: payload) != nil)
        let closing = Data("\r\n--\(body.boundary)--\r\n".utf8)
        #expect(data.suffix(closing.count) == closing)
        #expect(MultipartBody.fields(of: body.file, boundary: body.boundary) == ["content": "iso", "checksum": "abc", "filename": "my _image_.iso"])
        #expect(body.contentType == "multipart/form-data; boundary=\(body.boundary)")
    }
}
