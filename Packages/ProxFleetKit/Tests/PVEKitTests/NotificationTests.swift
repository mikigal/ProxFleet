import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct NotificationTests {
    @Test func webhookKeepsStoredSecretsAndEncodesValues() {
        let config = NotificationConfig(
            values: ["url": "https://example.com/hook", "method": "post", "body": Data("hi".utf8).base64EncodedString()],
            lists: ["header": ["name=Accept,value=\(Data("text/plain".utf8).base64EncodedString())"], "secret": ["name=token"]]
        )
        let original = NotificationEndpointDraft(type: .webhook, name: "hook", config)
        #expect(original.body == "hi" && original.headers.first?.value == "text/plain")
        #expect(original.secrets.first?.isStored == true && original.secrets.first?.value == "")
        #expect(original.changes(from: original).isEmpty)

        var draft = original
        draft.body = ""
        draft.secrets.append(WebhookPair(name: "user", value: "anna"))
        let changes = draft.changes(from: original)
        #expect(changes.values("secret") == ["name=token", .string("name=user,value=\(Data("anna".utf8).base64EncodedString())")])
        #expect(changes["delete"] == "body")
    }

    @Test func smtpSendsThePasswordOnlyWhenTyped() {
        var draft = NotificationEndpointDraft(type: .smtp, name: "mail", NotificationConfig(values: ["server": "smtp.example.com", "from-address": "a@b.c"], lists: ["mailto": ["x@y.z"]]))
        let original = draft
        #expect(draft.changes(from: original).isEmpty)
        draft.secret = "new"
        #expect(draft.changes(from: original)["password"] == "new")
        draft.mode = "starttls"
        draft.port = "70000"
        #expect(draft.problems(isNew: false)["port"] != nil)
        #expect(NotificationEndpointDraft(type: .gotify).problems(isNew: true).keys.sorted() == ["name", "server", "token"])
    }

    @Test func matcherRules() {
        #expect(MatcherFieldRule(parsing: "regex:hostname=^pve") == MatcherFieldRule(isRegex: true, field: "hostname", value: "^pve"))
        #expect(MatcherFieldRule(parsing: "exact:type=vzdump,replication").value == "vzdump,replication")
        var draft = NotificationMatcherDraft()
        draft.name = "1bad"
        #expect(draft.problems(isNew: true).keys.sorted() == ["name", "target"])
        draft.name = "backups"
        draft.targets = ["b", "a"]
        draft.severities = [.error, .warning]
        let parameters = PVE.createNotificationMatcher(draft).parameters
        #expect(parameters.values("target") == ["a", "b"])
        #expect(parameters["match-severity"] == "warning,error")
    }

    @Test func optionsKeepUnknownKeys() {
        let config = DatacenterOptionsConfig(values: [
            "crs": "ha=static,ha-rebalance-on-start=1", "migration": "secure,network=10.0.0.0/24", "tag-style": "shape=dense,color-map=prod:FF0000",
            "registered-tags": "prod;db",
        ])
        let original = DatacenterOptionsDraft(config)
        #expect(original.haScheduler == "static" && original.migrationType == "secure" && original.migrationNetwork == "10.0.0.0/24")
        #expect(original.registeredTags == ["prod", "db"] && original.tagShape == "dense")
        var draft = original
        draft.haScheduler = ""
        draft.tagShape = ""
        draft.migrationNetwork = ""
        let update = draft.changes(from: original)
        #expect(update.values["crs"] == "ha-rebalance-on-start=1")
        #expect(update.values["tag-style"] == "color-map=prod:FF0000")
        #expect(update.values["migration"] == "type=secure")

        draft.macPrefix = "BD:24"
        draft.nextIDLower = "500"
        draft.nextIDUpper = "400"
        #expect(draft.problems.keys.sorted() == ["mac_prefix", "next-id"])
    }
}
