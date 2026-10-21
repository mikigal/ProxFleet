import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

/// Repositories, subscription and certificates, with responses recorded from Proxmox VE 9.2.
struct NodeAdministrationTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func repositories() throws {
        let repositories = try decode(AptRepositories.self, #"""
        {"infos": [{"message": "Proxmox", "kind": "origin", "index": 0, "path": "/etc/apt/sources.list.d/pve.sources"},
                   {"kind": "origin", "path": "/etc/apt/sources.list.d/debian.sources", "index": 0, "message": "Debian"},
                   {"message": "Debian", "kind": "origin", "index": 1, "path": "/etc/apt/sources.list.d/debian.sources"},
                   {"message": "suite 'bookworm' should not be used in production!", "kind": "warning", "index": 1, "path": "/etc/apt/sources.list.d/debian.sources"}],
         "standard-repos": [{"name": "Enterprise", "description": "This is the default…", "handle": "enterprise"},
                            {"handle": "no-subscription", "description": "This is the recommended…", "name": "No-Subscription", "status": 1}],
         "errors": [{"path": "/etc/apt/sources.list.d/broken.list", "error": "malformed entry on line 1"}],
         "files": [{"digest": [50, 34], "file-type": "sources", "path": "/etc/apt/sources.list.d/pve.sources",
                    "repositories": [{"URIs": ["http://download.proxmox.com/debian/pve"], "Options": [{"Key": "Signed-By", "Values": ["/usr/share/keyrings/proxmox-archive-keyring.gpg"]}],
                                      "Suites": ["trixie"], "Components": ["pve-no-subscription"], "FileType": "sources", "Types": ["deb"], "Enabled": 1}]},
                   {"repositories": [{"Suites": ["trixie", "trixie-updates"], "URIs": ["http://deb.debian.org/debian/"], "Components": ["main", "contrib", "non-free-firmware"],
                                      "Types": ["deb"], "Enabled": 1, "FileType": "sources"},
                                     {"FileType": "sources", "Enabled": 0, "Types": ["deb"], "Components": ["main"], "URIs": ["http://security.debian.org/debian-security/"],
                                      "Suites": ["bookworm-security"], "Comment": "old\n"}],
                    "file-type": "sources", "path": "/etc/apt/sources.list.d/debian.sources", "digest": [153, 188]}],
         "digest": "e26d2501ca6d68c9d9591de6aec02e6877270c07ca811f30870354dfeec9df1a"}
        """#)
        #expect(repositories.files.map(\.path) == ["/etc/apt/sources.list.d/pve.sources", "/etc/apt/sources.list.d/debian.sources"])
        let pve = repositories.repositories[0]
        #expect(pve.origin == "Proxmox" && pve.isEnabled && !pve.isEnterprise)
        #expect(pve.summary == "http://download.proxmox.com/debian/pve trixie pve-no-subscription")
        let security = repositories.repositories[2]
        #expect(security.id == "/etc/apt/sources.list.d/debian.sources#1" && !security.isEnabled && security.comment == "old")
        #expect(security.warnings == ["suite 'bookworm' should not be used in production!"])
        #expect(repositories.hasEnabledProxmoxRepository && !repositories.hasEnabledEnterpriseRepository)
        #expect(repositories.standardRepositories.map(\.isEnabled) == [nil, true])
        #expect(repositories.errors.first?.message == "malformed entry on line 1")

        #expect(PVE.setRepository(node: "pve", security, enabled: true, digest: "e26d").parameters.formEncoded
            == "path=%2Fetc%2Fapt%2Fsources.list.d%2Fdebian.sources&index=1&enabled=1&digest=e26d")
        #expect(PVE.addStandardRepository(node: "pve", handle: "no-subscription", digest: nil).method == .put)
    }

    @Test func subscription() throws {
        let subscription = try decode(NodeSubscription.self, #"{"status": "notfound", "url": "https://www.proxmox.com", "serverid": "B596", "message": "There is no subscription key"}"#)
        #expect(!subscription.isActive && subscription.message == "There is no subscription key")
        #expect(try decode(NodeSubscription.self, #"{"status": "Active", "productname": "Proxmox VE Community"}"#).isActive)
    }

    @Test func certificates() throws {
        let list = try decode([NodeCertificate].self, #"""
        [{"issuer": "/CN=Proxmox Virtual Environment/OU=f59eb78b/O=PVE Cluster Manager CA", "public-key-bits": 4096, "public-key-type": "rsaEncryption",
          "subject": "/CN=Proxmox Virtual Environment/OU=f59eb78b/O=PVE Cluster Manager CA", "fingerprint": "45:69:63:3B", "notafter": 2107808866,
          "san": [], "notbefore": 1792448866, "filename": "pve-root-ca.pem"},
         {"filename": "pve-ssl.pem", "notbefore": 1792448866, "san": ["127.0.0.1", "localhost", "10.10.100.150", "pve-claude", "pve-claude.local"],
          "fingerprint": "BF:CB:FB:44", "subject": "/OU=PVE Cluster Node/O=Proxmox Virtual Environment/CN=pve-claude.local", "notafter": 1855520866,
          "public-key-bits": 2048, "public-key-type": "rsaEncryption", "issuer": "/CN=Proxmox Virtual Environment/OU=f59eb78b/O=PVE Cluster Manager CA"}]
        """#)
        #expect(list[0].isAuthority && list[0].commonName == "Proxmox Virtual Environment")
        let node = list[1]
        #expect(node.commonName == "pve-claude.local" && node.issuerName == "Proxmox Virtual Environment" && !node.isCustom)
        #expect(node.subjectAlternativeNames.count == 5 && node.keyBits == 2048)
        #expect(node.notAfter == Date(timeIntervalSince1970: 1_855_520_866))
        #expect(!node.isExpired(at: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(node.expiresSoon(at: Date(timeIntervalSince1970: 1_855_000_000)))
    }

    @Test func customCertificateDraft() {
        var draft = CustomCertificateDraft()
        #expect(draft.problems.keys.sorted() == ["certificates"])
        draft.certificates = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
        draft.key = "not a key"
        #expect(draft.problems.keys.sorted() == ["key"])
        draft.key = "-----BEGIN EC PRIVATE KEY-----\nMHc\n-----END EC PRIVATE KEY-----"
        #expect(draft.problems.isEmpty)
        let parameters = PVE.uploadCertificate(node: "pve", draft).parameters
        #expect(parameters["force"] == .bool(true) && parameters["restart"] == .bool(true))
        #expect(parameters["certificates"] == .string("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"))
        #expect(PVE.deleteCustomCertificate(node: "pve").parameters.formEncoded == "restart=1")
    }
}
