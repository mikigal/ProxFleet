import Foundation
import ProxmoxCore

/// `/cluster/metrics/server` in demo mode. Servers that Proxmox contacts before saving (InfluxDB over HTTP and
/// OpenTelemetry) are refused while enabled, as there is nothing to reach.
extension DemoState {
    func handleMetricServers(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard parts.count >= 3, parts[0] == "cluster", parts[1] == "metrics", parts[2] == "server" else { return nil }
        if method != .get, !privileges(for: user).contains("Sys.Modify") { return failure(403, "Permission check failed (/, Sys.Modify)") }
        let rest = Array(parts.dropFirst(3))
        switch (method, rest) {
        case (.get, []):
            return success(.array(metricServers.map { server in
                var object: [String: JSONValue] = ["id": .string(server.id), "type": .string(server.values["type"] ?? ""), "disable": .int(server.values["disable"] == "1" ? 1 : 0)]
                for key in ["server", "port"] { object[key] = key == "port" ? .int(Int(server.values[key] ?? "") ?? 0) : .string(server.values[key] ?? "") }
                return .object(object)
            }))
        case (.get, let path) where path.count == 1:
            guard let server = metricServers.first(where: { $0.id == path[0] }) else { return failure(500, "status server entry '\(path[0])' does not exist") }
            return success(.object(server.values.filter { $0.key != "token" }.mapValues { .string($0) }))
        case (.post, let path) where path.count == 1:
            guard !metricServers.contains(where: { $0.id == path[0] }) else { return failure(500, "status server entry '\(path[0])' already exists") }
            if let error = refuseUnreachable(parameters) { return error }
            metricServers.append((id: path[0], values: parameters))
            return success(nil)
        case (.put, let path) where path.count == 1:
            guard let index = metricServers.firstIndex(where: { $0.id == path[0] }) else { return failure(500, "status server entry '\(path[0])' does not exist") }
            var missing: [String: String] = [:]
            for key in ["server", "port"] where parameters[key] == nil { missing[key] = "property is missing and it is not optional" }
            guard missing.isEmpty else { return fieldFailure(missing) }
            var values = metricServers[index].values
            for key in (parameters["delete"] ?? "").split(separator: ",") { values[String(key)] = nil }
            for (key, value) in parameters where key != "delete" { values[key] = value }
            if let error = refuseUnreachable(values) { return error }
            metricServers[index].values = values
            return success(nil)
        case (.delete, let path) where path.count == 1:
            metricServers.removeAll { $0.id == path[0] }
            return success(nil)
        default:
            return nil
        }
    }

    private func refuseUnreachable(_ values: [String: String]) -> HTTPResponse? {
        let usesConnection = values["type"] == "opentelemetry" || (values["type"] == "influxdb" && ["http", "https"].contains(values["influxdbproto"] ?? ""))
            || (values["type"] == "graphite" && values["proto"] == "tcp")
        let tested = values["type"] == "opentelemetry" || (usesConnection && values["disable"] != "1")
        return tested ? failure(500, "Connection test failed: 500 Can't connect to \(values["server"] ?? ""):\(values["port"] ?? "") (demo mode)") : nil
    }
}
