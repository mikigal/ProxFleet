import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

struct APISchemaTests {
    /// A trimmed-down `apidoc.js` in the same shape as the real one.
    private let apidoc = #"""
    const apiSchema = [
       {
          "children" : [
             {
                "info" : {
                   "POST" : {
                      "parameters" : {
                         "properties" : {
                            "args" : { "optional" : 1, "type" : "string", "description" : "Arbitrary arguments.\n" },
                            "cores" : { "default" : 1, "minimum" : 1, "optional" : 1, "type" : "integer" },
                            "digest" : { "optional" : 1, "type" : "string" },
                            "tdf" : { "default" : 0, "optional" : 1, "type" : "boolean" },
                            "numa[n]" : { "optional" : 1, "type" : "string", "format" : {
                               "cpus" : { "type" : "string" },
                               "memory" : { "optional" : 1, "type" : "number" },
                               "policy" : { "enum" : ["preferred", "bind", "interleave"], "optional" : 1, "type" : "string" }
                            } },
                            "net[n]" : { "optional" : 1, "type" : "string", "format" : {
                               "model" : { "default_key" : 1, "type" : "string" },
                               "virtio" : { "alias" : "macaddr", "keyAlias" : "model" },
                               "bridge" : { "optional" : 1, "type" : "string" }
                            } }
                         }
                      }
                   }
                },
                "path" : "/nodes/{node}/qemu/{vmid}/config"
             }
          ],
          "path" : "/nodes"
       }
    ]
    ;

    let method2cmd = {};
    """#

    @Test func parsesGuestConfigParameters() throws {
        let schema = try APISchema(apidoc: Data(apidoc.utf8))
        #expect(schema.vmConfig.map(\.name) == ["args", "cores", "net[n]", "numa[n]", "tdf"])
        #expect(schema.containerConfig.isEmpty)
        let cores = try #require(schema.vmConfig.first { $0.name == "cores" })
        #expect(cores.minimum == 1)
        #expect(cores.defaultValue == "1")
        let numa = try #require(schema.vmConfig.first { $0.name == "numa[n]" })
        #expect(numa.matches(key: "numa0"))
        #expect(!numa.matches(key: "numa"))
        #expect(numa.properties?.map(\.name) == ["cpus", "memory", "policy"])
        let net = try #require(schema.vmConfig.first { $0.name == "net[n]" })
        #expect(net.hasKeyAliases)
        #expect(net.properties?.first?.name == "model")
    }

    @Test func propertyStringValuesAreEditedInPlace() throws {
        let schema = try APISchema(apidoc: Data(apidoc.utf8))
        let numa = try #require(schema.vmConfig.first { $0.name == "numa[n]" })
        var draft = SchemaValueDraft(parameter: numa, value: "cpus=0-1,memory=1024,hostnodes=0")
        #expect(!draft.editsAsText)
        #expect(draft.fields["memory"] == "1024")
        draft.fields["policy"] = "bind"
        draft.fields["memory"] = ""
        #expect(draft.value == "cpus=0-1,hostnodes=0,policy=bind")
        #expect(GuestConfig(values: ["numa0": "x"]).nextKey(for: numa) == "numa1")
    }

    @Test func plainValuesAreValidated() throws {
        let schema = try APISchema(apidoc: Data(apidoc.utf8))
        let cores = try #require(schema.vmConfig.first { $0.name == "cores" })
        var draft = SchemaValueDraft(parameter: cores, value: "2")
        draft.text = "0"
        #expect(draft.validationMessage != nil)
        draft.text = "4"
        #expect(draft.validationMessage == nil)
        draft.text = ""
        #expect(draft.value == nil)
    }
}
