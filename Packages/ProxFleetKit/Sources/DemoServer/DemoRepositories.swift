import Foundation
import ProxmoxCore

/// APT repositories, the subscription and certificates of nodes in demo mode.
extension DemoState {
    private struct Repository {
        var path: String
        var uri: String
        var suites: [String]
        var components: [String]
        var origin: String
        var enabled: Bool
    }

    private static let standardRepositories: [(handle: String, name: String, description: String, uri: String, component: String)] = [
        ("enterprise", "Enterprise", "This is the default, stable, and recommended repository, available for all Proxmox subscription users.",
         "https://enterprise.proxmox.com/debian/pve", "pve-enterprise"),
        ("no-subscription", "No-Subscription", "This is the recommended repository for testing and non-production use. Its packages are not as heavily tested and validated as the production ready enterprise repository. You don't need a subscription key to access this repository.",
         "http://download.proxmox.com/debian/pve", "pve-no-subscription"),
        ("test", "Test", "This repository contains the latest packages and is primarily used for test labs and by developers to test new features.",
         "http://download.proxmox.com/debian/pve", "pve-test"),
    ]

    /// The installer's repositories after switching to No-Subscription, as many home labs do.
    private func repositoryList(_ node: String) -> [Repository] {
        var list = [
            Repository(path: "/etc/apt/sources.list.d/debian.sources", uri: "http://deb.debian.org/debian/", suites: ["trixie", "trixie-updates"],
                       components: ["main", "contrib", "non-free-firmware"], origin: "Debian", enabled: true),
            Repository(path: "/etc/apt/sources.list.d/debian.sources", uri: "http://security.debian.org/debian-security/", suites: ["trixie-security"],
                       components: ["main", "contrib", "non-free-firmware"], origin: "Debian", enabled: true),
            Repository(path: "/etc/apt/sources.list.d/pve-enterprise.sources", uri: "https://enterprise.proxmox.com/debian/pve", suites: ["trixie"],
                       components: ["pve-enterprise"], origin: "Proxmox", enabled: false),
            Repository(path: "/etc/apt/sources.list.d/proxmox.sources", uri: "http://download.proxmox.com/debian/pve", suites: ["trixie"],
                       components: ["pve-no-subscription"], origin: "Proxmox", enabled: true),
        ]
        for handle in addedRepositories[node] ?? [] {
            guard let standard = Self.standardRepositories.first(where: { $0.handle == handle }) else { continue }
            list.append(Repository(path: "/etc/apt/sources.list.d/proxmox.sources", uri: standard.uri, suites: ["trixie"],
                                   components: [standard.component], origin: "Proxmox", enabled: true))
        }
        var indexInFile: [String: Int] = [:]
        for index in list.indices {
            let position = indexInFile[list[index].path, default: 0]
            indexInFile[list[index].path] = position + 1
            if let enabled = repositoryStates[node]?["\(list[index].path)#\(position)"] { list[index].enabled = enabled }
        }
        return list
    }

    private func repositoryDigest(_ node: String) -> String {
        let state = repositoryList(node).map { "\($0.uri)\($0.components)\($0.enabled)" }.joined()
        return String(state.hashValue, radix: 16).replacingOccurrences(of: "-", with: "f")
    }

    /// Routes for `apt/repositories`, `subscription` and `certificates`. nil for other paths.
    func handleNodeAdministration(_ method: HTTPMethod, node: String, rest: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        let paths: [[String]] = [["apt", "repositories"], ["subscription"], ["certificates", "info"], ["certificates", "custom"]]
        guard paths.contains(rest), let info = cluster.nodes.first(where: { $0.name == node }) else { return nil }
        guard info.isOnline else { return failure(595, "Connection refused: node '\(node)' seems to be offline") }
        if method != .get, !privileges(for: user).contains("Sys.Modify") {
            return failure(403, "Permission check failed (/nodes/\(node), Sys.Modify)")
        }

        switch (method, rest) {
        case (.get, ["apt", "repositories"]):
            return success(repositoriesJSON(node))
        case (.post, ["apt", "repositories"]):
            if let digest = parameters["digest"], digest != repositoryDigest(node) { return failure(500, "detected modified configuration - file changed by other user? Try again.") }
            guard let path = parameters["path"], let index = Int(parameters["index"] ?? "") else { return fieldFailure(["path": "property is missing and it is not optional"]) }
            repositoryStates[node, default: [:]]["\(path)#\(index)"] = parameters["enabled"] != "0"
            return success(nil)
        case (.put, ["apt", "repositories"]):
            if let digest = parameters["digest"], digest != repositoryDigest(node) { return failure(500, "detected modified configuration - file changed by other user? Try again.") }
            guard let handle = parameters["handle"], Self.standardRepositories.contains(where: { $0.handle == handle }) else {
                return failure(500, "unknown handle '\(parameters["handle"] ?? "")'")
            }
            let component = Self.standardRepositories.first { $0.handle == handle }!.component
            if let existing = repositoryIndex(node, component: component) {
                repositoryStates[node, default: [:]][existing] = true
            } else {
                addedRepositories[node, default: []].append(handle)
            }
            return success(nil)
        case (.get, ["subscription"]):
            return success([
                "status": "notfound", "message": "There is no subscription key", "serverid": "D3M0D3M0D3M0D3M0D3M0D3M0D3M0D3M0",
                "url": "https://www.proxmox.com/en/proxmox-virtual-environment/pricing",
            ])
        case (.get, ["certificates", "info"]):
            return success(.array(certificatesJSON(node)))
        case (.post, ["certificates", "custom"]):
            guard let pem = parameters["certificates"], pem.contains("-----BEGIN CERTIFICATE-----") else {
                return fieldFailure(["certificates": "unable to parse certificate"])
            }
            customCertificates[node] = Date()
            return success(customCertificateJSON(node))
        case (.delete, ["certificates", "custom"]):
            customCertificates[node] = nil
            return success(nil)
        default:
            return nil
        }
    }

    private func repositoryIndex(_ node: String, component: String) -> String? {
        var counts: [String: Int] = [:]
        for repository in repositoryList(node) {
            let index = counts[repository.path, default: 0]
            counts[repository.path] = index + 1
            if repository.components.contains(component) { return "\(repository.path)#\(index)" }
        }
        return nil
    }

    private func repositoriesJSON(_ node: String) -> JSONValue {
        let list = repositoryList(node)
        var files: [String: [JSONValue]] = [:]
        var infos: [JSONValue] = []
        var order: [String] = []
        for repository in list {
            if files[repository.path] == nil { order.append(repository.path) }
            let index = files[repository.path, default: []].count
            files[repository.path, default: []].append([
                "Types": ["deb"], "URIs": [.string(repository.uri)], "Suites": .array(repository.suites.map { .string($0) }),
                "Components": .array(repository.components.map { .string($0) }), "Enabled": .int(repository.enabled ? 1 : 0), "FileType": "sources",
                "Options": [["Key": "Signed-By", "Values": .array([.string(repository.origin == "Debian" ? "/usr/share/keyrings/debian-archive-keyring.gpg" : "/usr/share/keyrings/proxmox-archive-keyring.gpg")])]],
            ])
            infos.append(["path": .string(repository.path), "index": .int(index), "kind": "origin", "message": .string(repository.origin)])
        }
        let standard: [JSONValue] = Self.standardRepositories.map { repository in
            var object: [String: JSONValue] = ["handle": .string(repository.handle), "name": .string(repository.name), "description": .string(repository.description)]
            if let match = list.first(where: { $0.components.contains(repository.component) }) { object["status"] = .int(match.enabled ? 1 : 0) }
            return .object(object)
        }
        return [
            "files": .array(order.map { path in ["path": .string(path), "file-type": "sources", "repositories": .array(files[path] ?? []), "digest": [0, 1, 2]] }),
            "infos": .array(infos), "errors": [], "standard-repos": .array(standard), "digest": .string(repositoryDigest(node)),
        ]
    }

    private func certificatesJSON(_ node: String) -> [JSONValue] {
        let installed = started.addingTimeInterval(-86_400 * 300)
        let ip = cluster.nodes.first { $0.name == node }?.ip ?? "127.0.0.1"
        let authority = "/CN=Proxmox Virtual Environment/OU=7d3e2a90-demo/O=PVE Cluster Manager CA"
        var list: [JSONValue] = [
            [
                "filename": "pve-root-ca.pem", "subject": .string(authority), "issuer": .string(authority),
                "notbefore": .int(Int(installed.timeIntervalSince1970)), "notafter": .int(Int(installed.timeIntervalSince1970) + 86_400 * 3650),
                "fingerprint": "3A:91:5C:0E:7B:22:D4:18:66:AF:03:9E:B2:41:7D:C8:55:0F:E3:94:21:6B:8C:D7:4A:12:F0:9B:3E:65:C1:08",
                "public-key-type": "rsaEncryption", "public-key-bits": 4096, "san": [],
            ],
            [
                "filename": "pve-ssl.pem", "subject": .string("/OU=PVE Cluster Node/O=Proxmox Virtual Environment/CN=\(node).home.arpa"), "issuer": .string(authority),
                "notbefore": .int(Int(installed.timeIntervalSince1970)), "notafter": .int(Int(installed.timeIntervalSince1970) + 86_400 * 730),
                "fingerprint": "C4:0D:7E:9A:15:B3:62:F8:2E:47:D9:01:8C:A6:53:BE:70:1F:E8:39:94:C2:5D:0A:B7:6E:23:F1:48:9C:D5:7A",
                "public-key-type": "rsaEncryption", "public-key-bits": 2048,
                "san": ["127.0.0.1", "0000:0000:0000:0000:0000:0000:0000:0001", "localhost", .string(ip), .string(node), .string("\(node).home.arpa")],
            ],
        ]
        if customCertificates[node] != nil { list.append(customCertificateJSON(node)) }
        return list
    }

    private func customCertificateJSON(_ node: String) -> JSONValue {
        let issued = customCertificates[node] ?? started
        return [
            "filename": "pveproxy-ssl.pem", "subject": .string("/CN=\(node).example.net"), "issuer": "/C=US/O=Let's Encrypt/CN=R11",
            "notbefore": .int(Int(issued.timeIntervalSince1970)), "notafter": .int(Int(issued.timeIntervalSince1970) + 86_400 * 90),
            "fingerprint": "9E:42:B1:0C:D8:77:3A:E5:16:F0:6B:C9:28:54:A3:DD:01:7F:BE:62:90:4C:E1:35:A8:5D:0B:F7:C3:19:66:2E",
            "public-key-type": "id-ecPublicKey", "public-key-bits": 256, "san": [.string("\(node).example.net")],
        ]
    }
}
