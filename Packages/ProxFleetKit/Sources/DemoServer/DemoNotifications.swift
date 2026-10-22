import Foundation
import ProxmoxCore

/// Notification endpoints and matchers, and datacenter options, in demo mode.
struct DemoNotifications: Sendable {
    struct Entry: Sendable {
        var name: String
        /// Endpoint type, or `matcher`.
        var type: String
        var values: [String: String]
        var lists: [String: [String]]
        var origin = "user-created"
    }

    var endpoints: [Entry]
    var matchers: [Entry]
    var options: [String: String]

    static let sample = DemoNotifications(
        endpoints: [
            Entry(name: "mail-to-root", type: "sendmail", values: ["comment": "Send mails to root@pam's email address"],
                  lists: ["mailto-user": ["root@pam"]], origin: "builtin"),
            Entry(name: "phone", type: "gotify", values: ["server": "https://gotify.example.com", "comment": "Alerts on the phone"], lists: [:]),
            Entry(name: "team-chat", type: "webhook", values: [
                "url": "https://chat.example.com/hooks/{{ secrets.token }}", "method": "post",
                "body": Data(#"{"text": "{{ title }}: {{ message }}"}"#.utf8).base64EncodedString(),
            ], lists: ["header": ["name=Content-Type,value=\(Data("application/json".utf8).base64EncodedString())"], "secret": ["name=token"]]),
        ],
        matchers: [
            Entry(name: "default-matcher", type: "matcher", values: ["mode": "all", "comment": "Route all notifications to mail-to-root"],
                  lists: ["target": ["mail-to-root"]], origin: "builtin"),
            Entry(name: "backup-failures", type: "matcher", values: ["mode": "all", "comment": "Failed backups to the phone"],
                  lists: ["target": ["phone", "team-chat"], "match-severity": ["error"], "match-field": ["exact:type=vzdump"]]),
        ],
        options: ["keyboard": "en-us", "mac_prefix": "BC:24:11", "email_from": "pve@homelab.example", "tag-style": "shape=circle,ordering=config,color-map=prod:C62828;db:6A1B9A",
                  "description": "Home lab cluster. Ask Anna before changing the network."]
    )
}

extension DemoState {
    /// Routes below `/cluster/notifications` and `/cluster/options`. nil for other paths.
    func handleNotifications(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard parts.first == "cluster", parts.count >= 2, ["notifications", "options"].contains(parts[1]) else { return nil }
        let canModify = privileges(for: user).contains("Sys.Modify")
        if method != .get, !canModify { return failure(403, "Permission check failed (/mapping/notifications, Mapping.Modify)") }
        let rest = Array(parts.dropFirst(2))
        if parts[1] == "options" {
            switch method {
            case .get:
                var object = notifications.options.mapValues { JSONValue.string($0) }
                object["allowed-tags"] = .array(["prod", "lab", "db", "web"].map { .string($0) })
                return success(.object(object))
            case .put:
                for key in (parameters["delete"] ?? "").split(separator: ",") { notifications.options[String(key)] = nil }
                for (key, value) in parameters where !["delete", "digest"].contains(key) { notifications.options[key] = value }
                return success(nil)
            default:
                return nil
            }
        }
        switch (method, rest) {
        case (.get, ["targets"]):
            return success(.array(notifications.endpoints.map { entry in
                var object: [String: JSONValue] = ["name": .string(entry.name), "type": .string(entry.type), "origin": .string(entry.origin)]
                if let comment = entry.values["comment"] { object["comment"] = .string(comment) }
                if entry.values["disable"] == "1" { object["disable"] = 1 }
                return .object(object)
            }))
        case (.get, ["matchers"]):
            return success(.array(notifications.matchers.map { entryJSON($0) }))
        case (.get, ["matcher-field-values"]):
            let values = ["vzdump", "replication", "package-updates", "fencing", "system-mail"].map { ["field": "type", "value": JSONValue.string($0)] }
                + cluster.nodes.map { ["field": "hostname", "value": JSONValue.string($0.name)] }
            return success(.array(values.map { .object($0) }))
        case (.post, ["matchers"]):
            return create(\.matchers, type: "matcher", parameters: parameters)
        case (.put, let path) where path.count == 2 && path[0] == "matchers":
            return update(\.matchers, name: path[1], parameters: parameters)
        case (.delete, let path) where path.count == 2 && path[0] == "matchers":
            guard notifications.matchers.contains(where: { $0.name == path[1] && $0.origin == "user-created" }) else { return failure(500, "cannot delete built-in matcher") }
            notifications.matchers.removeAll { $0.name == path[1] }
            return success(nil)
        case (.get, let path) where path.count == 3 && path[0] == "endpoints":
            guard let entry = notifications.endpoints.first(where: { $0.name == path[2] && $0.type == path[1] }) else { return failure(404, "no such endpoint") }
            return success(entryJSON(entry))
        case (.post, let path) where path.count == 2 && path[0] == "endpoints":
            var parameters = parameters
            parameters["password"] = nil
            parameters["token"] = nil
            return create(\.endpoints, type: path[1], parameters: parameters)
        case (.put, let path) where path.count == 3 && path[0] == "endpoints":
            var parameters = parameters
            parameters["password"] = nil
            parameters["token"] = nil
            return update(\.endpoints, name: path[2], parameters: parameters)
        case (.delete, let path) where path.count == 3 && path[0] == "endpoints":
            guard notifications.endpoints.contains(where: { $0.name == path[2] && $0.origin == "user-created" }) else { return failure(500, "cannot delete built-in target") }
            notifications.endpoints.removeAll { $0.name == path[2] }
            for index in notifications.matchers.indices {
                notifications.matchers[index].lists["target"]?.removeAll { $0 == path[2] }
            }
            return success(nil)
        case (.post, let path) where path.count == 3 && path[0] == "targets" && path[2] == "test":
            guard let entry = notifications.endpoints.first(where: { $0.name == path[1] }) else { return failure(404, "no such target") }
            if entry.type == "sendmail" { return success(nil) }
            return failure(500, "could not notify via target '\(entry.name)': demo mode does not reach \(entry.values["server"] ?? entry.values["url"] ?? "the network")")
        default:
            return nil
        }
    }

    private func create(_ entries: WritableKeyPath<DemoNotifications, [DemoNotifications.Entry]>, type: String, parameters: [String: String]) -> HTTPResponse {
        guard let name = parameters["name"], name.first?.isLetter == true else { return fieldFailure(["name": "invalid configuration ID"]) }
        guard !(notifications.endpoints + notifications.matchers).contains(where: { $0.name == name }) else {
            return failure(500, "name '\(name)' already exists")
        }
        var entry = DemoNotifications.Entry(name: name, type: type, values: [:], lists: [:])
        apply(parameters, to: &entry)
        notifications[keyPath: entries].append(entry)
        return success(nil)
    }

    private func update(_ entries: WritableKeyPath<DemoNotifications, [DemoNotifications.Entry]>, name: String, parameters: [String: String]) -> HTTPResponse {
        guard let index = notifications[keyPath: entries].firstIndex(where: { $0.name == name }) else { return failure(404, "'\(name)' does not exist") }
        var entry = notifications[keyPath: entries][index]
        for key in (parameters["delete"] ?? "").split(separator: ",").map(String.init) {
            entry.values[key] = nil
            entry.lists[key] = nil
        }
        apply(parameters, to: &entry)
        if entry.origin == "builtin" { entry.origin = "modified-builtin" }
        notifications[keyPath: entries][index] = entry
        return success(nil)
    }

    /// Array settings come as repeated parameters; a webhook secret sent by name only keeps its stored value.
    private func apply(_ parameters: [String: String], to entry: inout DemoNotifications.Entry) {
        let listKeys: Set<String> = ["mailto", "mailto-user", "header", "secret", "target", "match-field", "match-severity", "match-calendar"]
        for (key, value) in parameters where !["name", "delete", "digest"].contains(key) {
            if listKeys.contains(key) {
                var list = value.components(separatedBy: DemoState.listSeparator)
                if key == "secret" {
                    // Values are write-only: keep names, drop values, as the server only returns names.
                    list = list.map { PropertyString(parsing: $0)["name"].map { "name=\($0)" } ?? $0 }
                }
                entry.lists[key] = list
            } else {
                entry.values[key] = value
            }
        }
    }

    private func entryJSON(_ entry: DemoNotifications.Entry) -> JSONValue {
        var object: [String: JSONValue] = ["name": .string(entry.name), "origin": .string(entry.origin)]
        for (key, value) in entry.values { object[key] = .string(value) }
        for (key, list) in entry.lists { object[key] = .array(list.map { .string($0) }) }
        return .object(object)
    }
}
