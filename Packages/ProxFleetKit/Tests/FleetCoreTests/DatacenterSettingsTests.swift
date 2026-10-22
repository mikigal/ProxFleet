import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct DatacenterSettingsTests {
    private func settings() async throws -> DatacenterSettings {
        let transport = DemoTransport(cluster: .homelab)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: "root", realm: "pam"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        try #require(connection.state == .connected)
        return DatacenterSettings(connection: connection)
    }

    @Test func notifications() async throws {
        let settings = try await settings()
        await settings.loadNotifications()
        #expect(settings.targets?.map(\.name) == ["mail-to-root", "phone", "team-chat"])
        #expect(settings.matchers?.first { $0.name == "backup-failures" }?.targets == ["phone", "team-chat"])
        #expect(settings.fieldValues.contains { $0.field == "type" && $0.value == "vzdump" })

        var smtp = NotificationEndpointDraft(type: .smtp)
        smtp.name = "office"
        smtp.server = "smtp.example.com"
        smtp.fromAddress = "pve@example.com"
        smtp.mailto = ["ops@example.com"]
        smtp.secret = "hidden"
        try await settings.createEndpoint(smtp)
        let config = try await settings.endpointConfig(.smtp, name: "office")
        #expect(config.values["password"] == nil, "secrets are not returned")
        let saved = NotificationEndpointDraft(type: .smtp, name: "office", config)
        #expect(saved.mailto == ["ops@example.com"] && saved.mailtoUsers == ["root@pam"])

        var matcher = NotificationMatcherDraft()
        matcher.name = "updates"
        matcher.targets = ["office"]
        matcher.fields = [MatcherFieldRule(field: "type", value: "package-updates")]
        try await settings.createMatcher(matcher)
        let savedMatcher = try #require(settings.matchers?.first { $0.name == "updates" })
        #expect(NotificationMatcherDraft(savedMatcher).fields == matcher.fields)

        try await settings.test("mail-to-root")
        await #expect(throws: ConfigUpdateError.self) { try await settings.test("phone") }

        let target = try #require(settings.targets?.first { $0.name == "office" })
        try await settings.deleteEndpoint(target)
        #expect(settings.matchers?.first { $0.name == "updates" }?.targets == [])
        await #expect(throws: ConfigUpdateError.self) {
            try await settings.deleteEndpoint(settings.targets!.first { $0.isBuiltIn }!)
        }
    }

    @Test func options() async throws {
        let settings = try await settings()
        await settings.loadOptions()
        let original = DatacenterOptionsDraft(try #require(settings.options))
        #expect(original.keyboard == "en-us" && original.tagOrdering == "config")
        var draft = original
        draft.keyboard = "pl"
        draft.tagOrdering = ""
        draft.nextIDLower = "1000"
        try await settings.updateOptions(draft.changes(from: original))
        let saved = DatacenterOptionsDraft(try #require(settings.options))
        #expect(saved.keyboard == "pl" && saved.tagOrdering.isEmpty && saved.tagShape == "circle" && saved.nextIDLower == "1000")
    }
}
