import Foundation

/// CRC-32 (IEEE 802.3, the variant ZIP uses). Table driven, no dependencies.
///
///     var crc = CRC32()
///     crc.update(chunk1)
///     crc.update(chunk2)
///     crc.value
///
/// or in one shot with ``checksum(_:)``.
public struct CRC32: Sendable {
    /// Standard reflected table for the polynomial 0xEDB88320.
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    // Stored pre-inverted, as in the textbook formulation, so `value` is a plain XOR away.
    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    /// The checksum of everything passed to `update` so far.
    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    /// Feeds more bytes into the running checksum.
    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    /// Feeds more bytes into the running checksum.
    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var crc = state
        CRC32.table.withUnsafeBufferPointer { table in
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        state = crc
    }

    /// The CRC-32 of `data`.
    public static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }

    /// The CRC-32 of a raw byte range.
    public static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }
}
