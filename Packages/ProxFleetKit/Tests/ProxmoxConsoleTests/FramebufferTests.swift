@testable import ProxmoxConsole
import Testing

struct FramebufferTests {
    private func pixel(_ framebuffer: Framebuffer, _ x: Int, _ y: Int) -> UInt8 {
        framebuffer.pixels[(y * framebuffer.width + x) * Framebuffer.bytesPerPixel]
    }

    @Test func writeClipsToScreen() {
        var framebuffer = Framebuffer(width: 4, height: 3)
        let rect = [UInt8](repeating: 9, count: 3 * 2 * 4)
        framebuffer.write(rect, x: 2, y: 2, width: 3, height: 2)
        #expect(pixel(framebuffer, 2, 2) == 9)
        #expect(pixel(framebuffer, 3, 2) == 9)
        #expect(pixel(framebuffer, 1, 2) == 0)
        #expect(pixel(framebuffer, 2, 1) == 0)
    }

    @Test func overlappingCopyMovesRows() {
        var framebuffer = Framebuffer(width: 2, height: 4)
        for row in 0..<4 {
            framebuffer.write([UInt8](repeating: UInt8(row + 1), count: 2 * 4), x: 0, y: row, width: 2, height: 1)
        }
        // Scroll down by one row: rows 0...2 move to 1...3.
        framebuffer.copy(fromX: 0, fromY: 0, toX: 0, toY: 1, width: 2, height: 3)
        #expect((0..<4).map { pixel(framebuffer, 0, $0) } == [1, 1, 2, 3])
    }

    @Test func keysymsForTyping() {
        #expect(KeySym.character("a") == 0x61)
        #expect(KeySym.character("\n") == KeySym.returnKey)
        #expect(KeySym.character("ł") == 0x0100_0142)
        #expect(KeySym.needsShift("A"))
        #expect(KeySym.needsShift("?"))
        #expect(!KeySym.needsShift("a"))
        #expect(KeySym.function(12) == 0xFFC9)
    }
}
