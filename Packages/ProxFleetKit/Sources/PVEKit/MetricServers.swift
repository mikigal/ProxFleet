import Foundation
import ProxmoxCore

/// External metric servers the nodes send their statistics to.
public enum MetricServerType: String, CaseIterable, Sendable, Identifiable {
    case graphite, influxdb, opentelemetry

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .graphite: "Graphite"
        case .influxdb: "InfluxDB"
        case .opentelemetry: "OpenTelemetry"
        }
    }

    /// The port the web interface suggests.
    public var defaultPort: String {
        switch self {
        case .graphite: "2003"
        case .influxdb: "8089"
        case .opentelemetry: "4318"
        }
    }
}

/// An entry of `GET /cluster/metrics/server`, or `GET /cluster/metrics/server/{id}` with all its settings. Tokens
/// are never returned.
public struct MetricServer: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var type: String
    /// Every setting as text, by the names the API uses.
    public var values: [String: String]

    public var isEnabled: Bool { values["disable"] != "1" }
    public var server: String { values["server"] ?? "" }
    public var port: String { values["port"] ?? "" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var values: [String: String] = [:]
        for key in container.allKeys {
            if let text = container.lossyString(key) {
                values[key.stringValue] = text
            } else if let flag = container.lossyBool(key) {
                values[key.stringValue] = flag ? "1" : "0"
            }
        }
        type = values.removeValue(forKey: "type") ?? ""
        id = values.removeValue(forKey: "id") ?? ""
        values["digest"] = nil
        self.values = values
    }
}

/// The form for a metric server. Like `OptionsDraft`, the draft and the configuration it came from serialize the
/// same way, so an update sends only what changed, plus the server and port, which every update needs.
public struct MetricServerDraft: Equatable, Sendable {
    public var id = ""
    public var type: MetricServerType
    public var server = ""
    public var port: String
    public var isEnabled = true
    public var mtu = ""
    public var timeout = ""
    /// Graphite: the root path, and `tcp` or empty for UDP.
    public var path = ""
    public var graphiteProtocol = ""
    /// InfluxDB: empty for UDP, `http` or `https`; the rest applies to HTTP(S).
    public var influxProtocol = ""
    public var organization = ""
    public var bucket = ""
    /// Write-only: empty keeps the stored token.
    public var token = ""
    public var apiPathPrefix = ""
    public var verifiesCertificate = true
    public var maxBodySize = ""
    /// OpenTelemetry (OTLP over HTTP). Headers and resource attributes are JSON objects, which the API takes
    /// base64-encoded.
    public var otelProtocol = "https"
    public var otelPath = ""
    public var otelTimeout = ""
    public var otelVerifiesSSL = true
    public var otelMaxBodySize = ""
    public var otelCompression = ""
    public var otelHeaders = ""
    public var otelResourceAttributes = ""

    public init(type: MetricServerType) {
        self.type = type
        port = type.defaultPort
    }

    public init?(_ server: MetricServer) {
        guard let type = MetricServerType(rawValue: server.type) else { return nil }
        let values = server.values
        id = server.id
        self.type = type
        self.server = server.server
        port = server.port
        isEnabled = server.isEnabled
        mtu = values["mtu"] ?? ""
        timeout = values["timeout"] ?? ""
        path = values["path"] ?? ""
        graphiteProtocol = values["proto"] ?? ""
        influxProtocol = values["influxdbproto"] ?? ""
        organization = values["organization"] ?? ""
        bucket = values["bucket"] ?? ""
        apiPathPrefix = values["api-path-prefix"] ?? ""
        verifiesCertificate = values["verify-certificate"] != "0"
        maxBodySize = values["max-body-size"] ?? ""
        otelProtocol = values["otel-protocol"] ?? "https"
        otelPath = values["otel-path"] ?? ""
        otelTimeout = values["otel-timeout"] ?? ""
        otelVerifiesSSL = values["otel-verify-ssl"] != "0"
        otelMaxBodySize = values["otel-max-body-size"] ?? ""
        otelCompression = values["otel-compression"] ?? ""
        otelHeaders = Self.decodeBase64(values["otel-headers"])
        otelResourceAttributes = Self.decodeBase64(values["otel-resource-attributes"])
    }

    private static func decodeBase64(_ text: String?) -> String {
        guard let text, let data = Data(base64Encoded: text) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// UDP sends packets of at most the MTU; HTTP batches requests up to a body size.
    public var usesHTTP: Bool {
        switch type {
        case .graphite: false
        case .influxdb: !influxProtocol.isEmpty && influxProtocol != "udp"
        case .opentelemetry: true
        }
    }

    func serialized() -> [String: String?] {
        var values: [String: String?] = [:]
        func set(_ key: String, _ value: String?) { values.updateValue(value, forKey: key) }
        set("disable", isEnabled ? nil : "1")
        switch type {
        case .graphite:
            set("path", Self.text(path))
            set("proto", Self.text(graphiteProtocol))
            set("mtu", graphiteProtocol == "tcp" ? nil : Self.text(mtu))
            set("timeout", graphiteProtocol == "tcp" ? Self.text(timeout) : nil)
        case .influxdb:
            set("influxdbproto", Self.text(influxProtocol))
            set("mtu", usesHTTP ? nil : Self.text(mtu))
            for (key, value) in [("organization", organization), ("bucket", bucket), ("api-path-prefix", apiPathPrefix), ("timeout", timeout), ("max-body-size", maxBodySize)] {
                set(key, usesHTTP ? Self.text(value) : nil)
            }
            set("verify-certificate", usesHTTP && !verifiesCertificate ? "0" : nil)
        case .opentelemetry:
            set("otel-protocol", otelProtocol)
            set("otel-path", Self.text(otelPath))
            set("otel-timeout", Self.text(otelTimeout))
            set("otel-verify-ssl", otelVerifiesSSL ? nil : "0")
            set("otel-max-body-size", Self.text(otelMaxBodySize))
            set("otel-compression", Self.text(otelCompression))
            set("otel-headers", Self.text(otelHeaders).map { Data($0.utf8).base64EncodedString() })
            set("otel-resource-attributes", Self.text(otelResourceAttributes).map { Data($0.utf8).base64EncodedString() })
        }
        return values
    }

    /// Parameters of `POST /cluster/metrics/server/{id}`; the ID goes in the path.
    var creationParameters: APIParameters {
        var parameters: APIParameters = ["type": .string(type.rawValue), "server": .string(server.trimmingCharacters(in: .whitespaces)),
                                         "port": .string(port.trimmingCharacters(in: .whitespaces))]
        for (key, value) in serialized().sorted(by: { $0.key < $1.key }) {
            if let value { parameters[key] = .string(value) }
        }
        if type == .influxdb, usesHTTP, let token = Self.text(token) { parameters["token"] = .string(token) }
        return parameters
    }

    /// The changes against the configuration the form was opened with. Every update carries the server and port.
    public func changes(from original: MetricServerDraft) -> GuestConfigUpdate {
        var update = GuestConfigUpdate()
        let old = original.serialized()
        for (key, value) in serialized() where value != (old[key] ?? nil) {
            update.set(key, value)
        }
        if type == .influxdb, usesHTTP, let token = Self.text(token) { update.set("token", token) }
        if server != original.server || port != original.port { update.set("server", Self.text(server)) }
        return update
    }

    /// `PUT` refuses updates without the server and port, even when they did not change.
    func updateParameters(_ update: GuestConfigUpdate) -> APIParameters {
        var parameters = update.parameters
        parameters["server"] = .string(server.trimmingCharacters(in: .whitespaces))
        parameters["port"] = .string(port.trimmingCharacters(in: .whitespaces))
        return parameters
    }

    public func problems(isNew: Bool) -> [String: String] {
        var problems: [String: String] = [:]
        if isNew {
            let id = id.trimmingCharacters(in: .whitespaces)
            if id.isEmpty || !(id.first?.isLetter == true) || id.contains(where: { !($0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0))) }) {
                problems["id"] = String(localized: "Use letters, digits, - and _, starting with a letter.")
            }
        }
        if Self.text(server) == nil { problems["server"] = String(localized: "Enter the server's address.") }
        if !(Int(port.trimmingCharacters(in: .whitespaces)).map { (1...65536).contains($0) } ?? false) {
            problems["port"] = String(localized: "Enter a port from 1 to 65536.")
        }
        if let mtu = Self.text(mtu), !usesHTTP, !(Int(mtu).map { (512...65536).contains($0) } ?? false) {
            problems["mtu"] = String(localized: "Use an MTU from 512 to 65536.")
        }
        for (key, value) in [("timeout", timeout), ("max-body-size", maxBodySize), ("otel-max-body-size", otelMaxBodySize)] {
            if let value = Self.text(value), Int(value) == nil { problems[key] = String(localized: "Enter a whole number.") }
        }
        if let timeout = Self.text(otelTimeout), !(Int(timeout).map { (1...10).contains($0) } ?? false) {
            problems["otel-timeout"] = String(localized: "Use 1 to 10 seconds.")
        }
        for (key, value) in [("otel-headers", otelHeaders), ("otel-resource-attributes", otelResourceAttributes)] where type == .opentelemetry {
            if let value = Self.text(value), !((try? JSONSerialization.jsonObject(with: Data(value.utf8))) is [String: Any]) {
                problems[key] = String(localized: "Enter a JSON object, such as {\"key\": \"value\"}.")
            }
        }
        return problems
    }
}

extension PVE {
    public static func metricServers() -> APIRequest<[MetricServer]> {
        APIRequest(.get, "/cluster/metrics/server")
    }

    public static func metricServer(_ id: String) -> APIRequest<MetricServer> {
        APIRequest(.get, "/cluster/metrics/server/\(escapePath(id))")
    }

    /// InfluxDB over HTTP(S) and OpenTelemetry servers are contacted before they are saved, unless disabled
    /// (OpenTelemetry always).
    public static func createMetricServer(_ draft: MetricServerDraft) -> APIRequest<Nothing> {
        APIRequest(.post, "/cluster/metrics/server/\(escapePath(draft.id.trimmingCharacters(in: .whitespaces)))", parameters: draft.creationParameters)
    }

    public static func updateMetricServer(_ draft: MetricServerDraft, _ update: GuestConfigUpdate) -> APIRequest<Nothing> {
        APIRequest(.put, "/cluster/metrics/server/\(escapePath(draft.id))", parameters: draft.updateParameters(update))
    }

    public static func deleteMetricServer(_ id: String) -> APIRequest<Nothing> {
        APIRequest(.delete, "/cluster/metrics/server/\(escapePath(id))")
    }
}
