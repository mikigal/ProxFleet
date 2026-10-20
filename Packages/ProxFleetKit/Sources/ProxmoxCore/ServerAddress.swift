import Foundation

/// Host and port of a Proxmox API endpoint. Always HTTPS.
public struct ServerAddress: Hashable, Codable, Sendable {
    /// Hostname or IP address. IPv6 addresses are stored without brackets.
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Parses user input such as `pve.lan`, `10.0.0.5:8006`, `https://pve.lan:8006/` or `[fd00::1]:8006`.
    public init?(parsing input: String, defaultPort: Int) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https" || components.scheme?.lowercased() == "http",
              var host = components.host, !host.isEmpty
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        let port = components.port ?? defaultPort
        guard (1...65535).contains(port) else { return nil }
        self.init(host: host, port: port)
    }

    public var baseURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        // Built from validated parts, so this cannot fail.
        return components.url!
    }

    /// Short form for display: the port is shown only when it differs from the default.
    public func displayString(defaultPort: Int) -> String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return port == defaultPort ? hostPart : "\(hostPart):\(port)"
    }
}
