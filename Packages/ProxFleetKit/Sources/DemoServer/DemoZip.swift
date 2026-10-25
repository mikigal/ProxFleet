import Foundation

/// Builds small zip archives without compression, for directories downloaded from backups in demo mode, as the
/// backup server sends a directory as zip.
enum DemoZip {
    static func archive(_ files: [(path: String, data: Data)]) -> Data {
        var output = Data()
        var central = Data()
        for file in files {
            let name = Data(file.path.utf8)
            let crc = crc32(file.data)
            let offset = UInt32(output.count)
            // Local file header: version 2.0, no flags, stored, no time.
            output.append(le32(0x0403_4B50))
            output.append(le16(20)); output.append(le16(0)); output.append(le16(0))
            output.append(le16(0)); output.append(le16(0x21))
            output.append(le32(crc)); output.append(le32(UInt32(file.data.count))); output.append(le32(UInt32(file.data.count)))
            output.append(le16(UInt16(name.count))); output.append(le16(0))
            output.append(name)
            output.append(file.data)

            central.append(le32(0x0201_4B50))
            central.append(le16(20)); central.append(le16(20)); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0x21))
            central.append(le32(crc)); central.append(le32(UInt32(file.data.count))); central.append(le32(UInt32(file.data.count)))
            central.append(le16(UInt16(name.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0o644 << 16))
            central.append(le32(offset))
            central.append(name)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.append(le32(0x0605_4B50))
        output.append(le16(0)); output.append(le16(0))
        output.append(le16(UInt16(files.count))); output.append(le16(UInt16(files.count)))
        output.append(le32(UInt32(central.count))); output.append(le32(centralOffset))
        output.append(le16(0))
        return output
    }

    private static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
