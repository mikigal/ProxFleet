@testable import ProxmoxConsole
import Testing

struct DESTests {
    @Test func standardTestVector() {
        #expect(DES.encrypt(block: 0x0123_4567_89AB_CDEF, key: 0x1334_5779_9BBC_DFF1) == 0x85E8_1354_0F0A_B405)
    }

    @Test func allZeroKeyAndBlock() {
        #expect(DES.encrypt(block: 0, key: 0) == 0x8CA6_4DE9_C1B1_23A7)
    }

    @Test func vncResponseHasTwoBlocks() {
        let challenge = Array(0..<16).map(UInt8.init)
        let response = VNCAuthentication.response(challenge: challenge, password: "password")
        #expect(response.count == 16)
        // Same challenge and password give the same response, different passwords a different one.
        #expect(response == VNCAuthentication.response(challenge: challenge, password: "password"))
        #expect(response != VNCAuthentication.response(challenge: challenge, password: "Password"))
        // Only the first 8 characters count.
        #expect(response == VNCAuthentication.response(challenge: challenge, password: "password-long"))
    }
}
