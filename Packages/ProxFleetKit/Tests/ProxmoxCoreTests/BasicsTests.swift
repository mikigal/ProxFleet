import Foundation
@testable import ProxmoxCore
import Testing

struct ServerAddressTests {
    @Test(arguments: [
        ("pve.lan", "pve.lan", 8006),
        ("  10.0.0.5:8443 ", "10.0.0.5", 8443),
        ("https://pve.example.com:8006/", "pve.example.com", 8006),
        ("[fd00::1]:9000", "fd00::1", 9000),
        ("http://pve.lan", "pve.lan", 8006),
    ])
    func parsesUserInput(input: String, host: String, port: Int) throws {
        let address = try #require(ServerAddress(parsing: input, defaultPort: 8006))
        #expect(address.host == host)
        #expect(address.port == port)
    }

    @Test(arguments: ["", "   ", "ftp://pve.lan", "pve.lan:99999"])
    func rejectsInvalidInput(input: String) {
        #expect(ServerAddress(parsing: input, defaultPort: 8006) == nil)
    }

    @Test func buildsHTTPSBaseURLWithBracketedIPv6() {
        #expect(ServerAddress(host: "fd00::1", port: 8006).baseURL.absoluteString == "https://[fd00::1]:8006")
        #expect(ServerAddress(host: "pve.lan", port: 8006).displayString(defaultPort: 8006) == "pve.lan")
        #expect(ServerAddress(host: "pve.lan", port: 443).displayString(defaultPort: 8006) == "pve.lan:443")
    }
}

struct APIParametersTests {
    @Test func formEncodesInOrderWithBooleansAsDigits() {
        var parameters: APIParameters = ["name": "web server", "cores": 4, "onboot": true]
        parameters["description"] = "a&b=c+d"
        #expect(parameters.formEncoded == "name=web%20server&cores=4&onboot=1&description=a%26b%3Dc%2Bd")
    }

    @Test func subscriptReplacesAndRemoves() {
        var parameters: APIParameters = ["a": "1", "b": "2"]
        parameters["a"] = "3"
        parameters["b"] = nil
        #expect(parameters.formEncoded == "a=3")
    }
}

struct ResponseDecodingTests {
    private struct Item: Decodable, Equatable {
        var name: String
    }

    @Test func decodesData() throws {
        let value = try ResponseDecoder.decode([Item].self, from: .json(#"{"data":[{"name":"a"}],"success":1}"#))
        #expect(value == [Item(name: "a")])
    }

    @Test func nullDataIsAllowedForOptionalAndNothing() throws {
        #expect(try ResponseDecoder.decode(Item?.self, from: .json(#"{"data":null,"success":1}"#)) == nil)
        #expect(try ResponseDecoder.decode(Nothing.self, from: .json(#"{"data":null,"success":1}"#)) == Nothing())
        #expect(throws: ProxmoxError.invalidResponse("missing data")) {
            try ResponseDecoder.decode(Item.self, from: .json(#"{"data":null,"success":1}"#))
        }
    }

    @Test func extJSFailureCarriesMessageAndFieldErrors() {
        let body = #"{"data":null,"success":0,"status":400,"message":"Parameter verification failed.\n","errors":{"memory":"value must be at least 16\n"}}"#
        #expect(throws: ProxmoxError.api(status: 400, message: "Parameter verification failed.", fieldErrors: ["memory": "value must be at least 16"])) {
            try ResponseDecoder.decode(Nothing.self, from: .json(body))
        }
    }

    @Test func unauthorizedInBodyOrStatusLine() {
        #expect(throws: ProxmoxError.unauthorized("authentication failure")) {
            try ResponseDecoder.decode(Nothing.self, from: .json(#"{"data":null,"success":0,"status":401,"message":"authentication failure"}"#))
        }
        #expect(throws: ProxmoxError.unauthorized(nil)) {
            try ResponseDecoder.decode(Nothing.self, from: HTTPResponse(statusCode: 401, body: Data()))
        }
    }

    @Test func plainTextErrorBody() {
        #expect(throws: ProxmoxError.api(status: 501, message: "Not Implemented", fieldErrors: [:])) {
            try ResponseDecoder.decode(Nothing.self, from: .json("Not Implemented", status: 501))
        }
    }
}

struct LossyDecodingTests {
    private struct Sample: Decodable {
        var count: Int?
        var ratio: Double?
        var flag: Bool?
        var label: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            count = container.lossyInt(AnyCodingKey("count"))
            ratio = container.lossyDouble(AnyCodingKey("ratio"))
            flag = container.lossyBool(AnyCodingKey("flag"))
            label = container.lossyString(AnyCodingKey("label"))
        }
    }

    @Test func acceptsStringsAndNumbers() throws {
        let sample = try JSONDecoder().decode(Sample.self, from: Data(#"{"count":"42","ratio":"0.5","flag":"1","label":100}"#.utf8))
        #expect(sample.count == 42)
        #expect(sample.ratio == 0.5)
        #expect(sample.flag == true)
        #expect(sample.label == "100")

        let numeric = try JSONDecoder().decode(Sample.self, from: Data(#"{"count":7.9,"flag":0}"#.utf8))
        #expect(numeric.count == 7)
        #expect(numeric.flag == false)
        #expect(numeric.label == nil)
    }
}

struct CertificateDetailsTests {
    @Test func formatsFingerprintLikeWebUI() {
        #expect(CertificateDetails.formatFingerprint([0x0A, 0xFF, 0x00]) == "0A:FF:00")
    }
}
