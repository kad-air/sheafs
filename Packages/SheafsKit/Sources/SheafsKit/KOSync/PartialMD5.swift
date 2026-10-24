import CryptoKit
import Foundation

/// KOReader's partial MD5: the document key every kosync client uses for a book.
///
/// It must agree bit-for-bit with every other client, so it follows `util.partialMD5` exactly:
/// for `i` in `-1...10`, read up to 1024 bytes at offset `1024 << (2 * i)`, which is 0 (twice:
/// LuaJIT's 32-bit shift turns the `i = -1` offset into 0, not 256), 1 KiB, 4 KiB, 16 KiB,
/// ... 1 GiB. Offsets at or past the end of the file are skipped, a read that straddles the end
/// contributes the bytes that exist, and the key is the lowercase hex MD5 of the concatenation.
public enum PartialMD5 {
    private static let sampleSize = 1024

    /// The offsets read, in order: 0, then 1024 << (2 * i) for i in 0...10.
    private static let offsets: [Int] = [0] + (0...10).map { 1024 << (2 * $0) }

    /// The key for the file at `url`, read with seeks so the whole file is never loaded.
    public static func digest(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        for offset in offsets {
            try handle.seek(toOffset: UInt64(offset))
            guard let sample = try handle.read(upToCount: sampleSize), !sample.isEmpty else { break }
            md5.update(data: sample)
        }
        return hexString(md5.finalize())
    }

    /// The key for in-memory file contents.
    public static func digest(data: Data) -> String {
        var md5 = Insecure.MD5()
        for offset in offsets where offset < data.count {
            let start = data.startIndex + offset
            let end = min(start + sampleSize, data.endIndex)
            md5.update(data: data[start..<end])
        }
        return hexString(md5.finalize())
    }

    /// Lowercase hex of a digest.
    static func hexString<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        for byte in digest {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
