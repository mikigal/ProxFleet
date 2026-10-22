import Foundation
import ProxmoxCore
@testable import PVEKit
import Testing

/// Metric servers, realm sync jobs and the LDAP TLS settings. The JSON is recorded from the test server.
struct MetricServerAndRealmSyncTests {
    @Test func metricServers() throws {
        let list = try JSONDecoder().decode([MetricServer].self, from: Data(#"[{"id": "pfgraph", "disable": 0, "server": "192.0.2.10", "port": 2003, "type": "graphite"}]"#.utf8))
        #expect(list.first?.isEnabled == true && list.first?.port == "2003")
        let influx = try JSONDecoder().decode(MetricServer.self, from: Data(#"{"port": 8086, "disable": 1, "influxdbproto": "http", "server": "192.0.2.10", "type": "influxdb"}"#.utf8))
        var draft = try #require(MetricServerDraft(influx))
        #expect(draft.usesHTTP && !draft.isEnabled && draft.changes(from: draft).isEmpty)
        let original = draft
        draft.token = "secret"
        draft.verifiesCertificate = false
        // Every update carries the server and port, which PUT requires.
        #expect(PVE.updateMetricServer(draft, draft.changes(from: original)).parameters.formEncoded
            == "token=secret&verify-certificate=0&server=192.0.2.10&port=8086")

        var graphite = MetricServerDraft(type: .graphite)
        graphite.id = "graphite1"
        graphite.server = "metrics.example.com"
        graphite.graphiteProtocol = "tcp"
        graphite.mtu = "1400"
        graphite.timeout = "3"
        #expect(graphite.problems(isNew: true).isEmpty)
        // The MTU only applies to UDP, the timeout to TCP.
        #expect(PVE.createMetricServer(graphite).parameters.formEncoded == "type=graphite&server=metrics.example.com&port=2003&proto=tcp&timeout=3")

        var otel = MetricServerDraft(type: .opentelemetry)
        otel.id = "otel"
        otel.server = "collector"
        otel.otelHeaders = #"{"Authorization": "Bearer x"}"#
        otel.otelResourceAttributes = "not json"
        otel.otelTimeout = "30"
        #expect(otel.problems(isNew: true).keys.sorted() == ["otel-resource-attributes", "otel-timeout"])
        otel.otelResourceAttributes = ""
        otel.otelTimeout = ""
        let parameters = PVE.createMetricServer(otel).parameters
        #expect(parameters["otel-headers"] == .string(Data(#"{"Authorization": "Bearer x"}"#.utf8).base64EncodedString()) && parameters["otel-protocol"] == "https")
        let stored = try JSONDecoder().decode(MetricServer.self, from: Data(#"{"type": "opentelemetry", "server": "collector", "port": 4318, "otel-protocol": "https", "otel-headers": "\#(Data(#"{"a": "b"}"#.utf8).base64EncodedString())"}"#.utf8))
        #expect(MetricServerDraft(stored)?.otelHeaders == #"{"a": "b"}"#)

        var bad = MetricServerDraft(type: .influxdb)
        bad.id = "1x"
        bad.port = "0"
        bad.mtu = "100"
        #expect(bad.problems(isNew: true).keys.sorted() == ["id", "mtu", "port", "server"])
    }

    @Test func realmSyncJobs() throws {
        let jobs = try JSONDecoder().decode([RealmSyncJob].self, from: Data(#"""
        [{"id": "realmsync-corp", "realm": "corp", "schedule": "sat 02:00", "enabled": 1, "scope": "both", "enable-new": 0, "remove-vanished": "acl;entry", "next-run": 1792893600}]
        """#.utf8))
        let job = try #require(jobs.first)
        #expect(job.options.scope == "both" && job.options.enableNew == false && job.options.removeVanished == [.acl, .entry] && job.nextRun != nil)
        var draft = RealmSyncJobDraft(job)
        let original = draft
        draft.isEnabled = false
        draft.options.removeVanished = []
        draft.comment = "weekly"
        let update = draft.changes(from: original)
        #expect(update.values == ["enabled": "0", "remove-vanished": "none", "comment": "weekly"])

        var defaults = RealmSyncOptions()
        defaults.scope = "users"
        defaults.removeVanished = [.properties]
        var new = RealmSyncJobDraft(realm: "ldap1", defaults: defaults)
        #expect(new.options.enableNew == true && new.problems(isNew: true).isEmpty)
        #expect(new.resolvedID { "0123456789abcdef" } == "realmsync-0123456789abc")
        #expect(PVE.createRealmSyncJob(id: "nightly", new).path == "/cluster/jobs/realm-sync/nightly")
        #expect(PVE.createRealmSyncJob(id: "nightly", new).parameters.formEncoded
            == "realm=ldap1&enable-new=1&enabled=1&remove-vanished=properties&schedule=sat%2002%3A00&scope=users")
        new.options.scope = ""
        new.schedule = " "
        new.id = "9bad"
        #expect(new.problems(isNew: true).keys.sorted() == ["id", "schedule", "scope"])
    }

    @Test func ldapTLSSettings() throws {
        let config = RealmConfig(type: "ldap", values: ["server1": "ldap", "base_dn": "dc=x", "user_attr": "uid", "group_dn": "ou=groups,dc=x", "sslversion": "tlsv1_3"])
        var draft = try #require(RealmDraft(realm: "ldap1", config))
        #expect(draft.groupDN == "ou=groups,dc=x" && draft.sslVersion == "tlsv1_3")
        let original = draft
        draft.certificate = "/etc/pve/ldap/client.pem"
        #expect(draft.problems(isNew: false)["certkey"] != nil)
        draft.certificateKey = "/etc/pve/ldap/client.key"
        draft.sslVersion = ""
        let update = draft.changes(from: original)
        #expect(update.values == ["cert": "/etc/pve/ldap/client.pem", "certkey": "/etc/pve/ldap/client.key"] && update.deletions == ["sslversion"])
    }
}
