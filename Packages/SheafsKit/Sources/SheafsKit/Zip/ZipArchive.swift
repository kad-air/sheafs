import Compression
import Foundation

// A small read-only ZIP reader, enough for EPUB (and CBZ-style) archives:
// stored + deflate entries, ZIP64 sizes/offsets, UTF-8 names, data descriptors.
// Everything is read through the central directory, as every mainstream reader does.

/// One file or directory in a ZIP archive.
public struct ZipEntry: Hashable, Sendable {
    /// The entry name exactly as stored (forward slashes, no leading slash in practice).
    public let path: String
    public let compressedSize: Int
    public let uncompressedSize: Int
    /// CRC-32 of the uncompressed bytes, from the central directory.
    public let crc32: UInt32
    public let isDirectory: Bool

    /// ZIP compression method: 0 = stored, 8 = deflate.
    let method: UInt16
    /// General purpose bit flags (bit 0 = encrypted, bit 3 = data descriptor, bit 11 = UTF-8 name).
    let flags: UInt16
    /// Offset of the local file header from the start of the archive.
    let localHeaderOffset: Int

    /// Whether the entry is password protected (general purpose bit 0). Such entries cannot be read.
    public var isEncrypted: Bool { flags & 0x0001 != 0 }
}

/// Everything that can go wrong reading a ZIP archive.
public enum ZipError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// The data has no ZIP signature at all.
    case notAZipFile
    /// The data looks like a ZIP but ends early or its directory points outside the file.
    case truncated
    /// Only stored (0) and deflate (8) entries are supported.
    case unsupportedCompressionMethod(UInt16, path: String)
    /// The entry's bytes are corrupt: they failed to inflate, have the wrong length, or their
    /// CRC-32 differs from the one in the central directory.
    case crcMismatch(path: String)
    case entryNotFound(String)
    case encrypted(path: String)

    public var description: String {
        switch self {
        case .notAZipFile:
            return "The file is not a ZIP archive."
        case .truncated:
            return "The ZIP archive is truncated or its directory is damaged."
        case let .unsupportedCompressionMethod(method, path):
            return "Entry \"\(path)\" uses compression method \(method), which is not supported."
        case let .crcMismatch(path):
            return "Entry \"\(path)\" is corrupt (CRC-32 mismatch or invalid compressed data)."
        case let .entryNotFound(path):
            return "No entry named \"\(path)\" in the ZIP archive."
        case let .encrypted(path):
            return "Entry \"\(path)\" is encrypted, which is not supported."
        }
    }

    public var errorDescription: String? { description }
}

/// A read-only ZIP archive held in memory (memory-mapped when opened from a file).
///
/// Immutable after `init`, so it is safe to read from any number of threads at once.
public final class ZipArchive: Sendable {
    private let storage: Data
    private let indexByPath: [String: Int]

    /// Every entry, in central-directory order (directories included).
    public let entries: [ZipEntry]

    /// Opens the archive at `url`, memory-mapping the file when the system allows it.
    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Reads the archive directory from `data`.
    public init(data: Data) throws {
        // Offsets below are relative to the first byte, which a Data slice does not guarantee.
        let normalized = data.startIndex == 0 ? data : Data(data)
        let parsed = try normalized.withUnsafeBytes { try ZipDirectory.readEntries(ZipBytes($0)) }
        var index: [String: Int] = [:]
        index.reserveCapacity(parsed.count)
        for (i, entry) in parsed.enumerated() { index[entry.path] = i }   // last duplicate wins, as in Python
        self.storage = normalized
        self.entries = parsed
        self.indexByPath = index
    }

    /// Finds an entry by its exact, case-sensitive path. A percent-encoded `path`
    /// ("ch%201.xhtml") also matches the decoded name ("ch 1.xhtml").
    public func entry(at path: String) -> ZipEntry? {
        if let i = indexByPath[path] { return entries[i] }
        if let decoded = path.removingPercentEncoding, decoded != path, let i = indexByPath[decoded] {
            return entries[i]
        }
        return nil
    }

    public func contains(_ path: String) -> Bool { entry(at: path) != nil }

    /// The uncompressed bytes of `entry`, with the CRC-32 verified.
    public func data(for entry: ZipEntry) throws -> Data {
        if entry.isEncrypted { throw ZipError.encrypted(path: entry.path) }
        guard entry.method == 0 || entry.method == 8 else {
            throw ZipError.unsupportedCompressionMethod(entry.method, path: entry.path)
        }

        let output: Data = try storage.withUnsafeBytes { raw in
            let bytes = ZipBytes(raw)
            // The local header's name/extra lengths can differ from the central directory's,
            // so the start of the data has to come from the local header itself.
            let header = entry.localHeaderOffset
            guard try bytes.u32(header) == ZipSignature.localHeader else { throw ZipError.truncated }
            let nameLength = Int(try bytes.u16(header + 26))
            let extraLength = Int(try bytes.u16(header + 28))
            let source = try bytes.slice(header + 30 + nameLength + extraLength, entry.compressedSize)

            if entry.method == 0 {
                guard entry.compressedSize == entry.uncompressedSize else {
                    throw ZipError.crcMismatch(path: entry.path)
                }
                return Data(source)
            }
            return try ZipArchive.inflate(source, expectedSize: entry.uncompressedSize, path: entry.path)
        }

        guard CRC32.checksum(output) == entry.crc32 else { throw ZipError.crcMismatch(path: entry.path) }
        return output
    }

    /// The uncompressed bytes of the entry at `path`.
    public func data(at path: String) throws -> Data {
        guard let entry = entry(at: path) else { throw ZipError.entryNotFound(path) }
        return try data(for: entry)
    }

    // MARK: Inflate

    /// Inflates a raw DEFLATE stream whose output size is known from the directory.
    ///
    /// Apple's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951), which is what ZIP stores. The
    /// buffer is one byte larger than expected so an over-long stream shows up as a size
    /// mismatch instead of being silently clipped.
    private static func inflate(_ source: UnsafeRawBufferPointer, expectedSize: Int, path: String) throws -> Data {
        // DEFLATE cannot expand more than about 1032:1, so a bigger claim is a corrupt header
        // (and would otherwise be an invitation to allocate gigabytes).
        guard expectedSize <= (source.count + 16) * 1100 else { throw ZipError.crcMismatch(path: path) }
        if expectedSize == 0 { return Data() }

        var output = Data(count: expectedSize + 1)
        let produced = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.baseAddress, let sourceBase = source.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBase.assumingMemoryBound(to: UInt8.self), destination.count,
                sourceBase.assumingMemoryBound(to: UInt8.self), source.count,
                nil, COMPRESSION_ZLIB)
        }
        guard produced == expectedSize else { throw ZipError.crcMismatch(path: path) }
        output.count = expectedSize
        return output
    }
}

// MARK: - Directory parsing

private enum ZipSignature {
    static let localHeader: UInt32 = 0x0403_4B50
    static let centralHeader: UInt32 = 0x0201_4B50
    static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    static let zip64EndRecord: UInt32 = 0x0606_4B50
    static let zip64EndLocator: UInt32 = 0x0706_4B50
}

/// Bounds-checked little-endian reads over the archive bytes. Every read throws
/// `ZipError.truncated` rather than trapping, so a damaged file can't crash the app.
private struct ZipBytes {
    let bytes: UnsafeRawBufferPointer

    init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

    var count: Int { bytes.count }

    func check(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, offset <= bytes.count, length <= bytes.count - offset else {
            throw ZipError.truncated
        }
    }

    func u16(_ offset: Int) throws -> UInt16 {
        try check(offset, 2)
        return UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    func u32(_ offset: Int) throws -> UInt32 {
        try check(offset, 4)
        return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    func u64(_ offset: Int) throws -> UInt64 {
        try check(offset, 8)
        return UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    func slice(_ offset: Int, _ length: Int) throws -> UnsafeRawBufferPointer {
        try check(offset, length)
        return UnsafeRawBufferPointer(rebasing: bytes[offset ..< offset + length])
    }

    func int(_ value: UInt64) throws -> Int {
        guard let result = Int(exactly: value) else { throw ZipError.truncated }
        return result
    }
}

private enum ZipDirectory {
    static func readEntries(_ bytes: ZipBytes) throws -> [ZipEntry] {
        guard let eocd = findEndOfCentralDirectory(bytes) else {
            // A ZIP that merely lost its tail still starts with a local header signature.
            let head = try bytes.count >= 4 ? bytes.u32(0) : 0
            throw head == ZipSignature.localHeader || head == ZipSignature.endOfCentralDirectory
                ? ZipError.truncated : ZipError.notAZipFile
        }

        var entryCount = UInt64(try bytes.u16(eocd + 10))
        var directorySize = UInt64(try bytes.u32(eocd + 12))
        var directoryOffset = UInt64(try bytes.u32(eocd + 16))

        let saturated = entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF
        if saturated, eocd >= 20, try bytes.u32(eocd - 20) == ZipSignature.zip64EndLocator {
            // ZIP64: the real numbers live in a separate record the locator points at.
            let record = try bytes.int(try bytes.u64(eocd - 20 + 8))
            guard try bytes.u32(record) == ZipSignature.zip64EndRecord else { throw ZipError.truncated }
            entryCount = try bytes.u64(record + 32)
            directorySize = try bytes.u64(record + 40)
            directoryOffset = try bytes.u64(record + 48)
        } else if directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw ZipError.truncated
        }

        // Each central header is at least 46 bytes, which bounds what a sane count can be.
        guard entryCount <= UInt64(bytes.count / 46) else { throw ZipError.truncated }
        var position = try bytes.int(directoryOffset)
        try bytes.check(position, try bytes.int(directorySize))

        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(entryCount))
        for _ in 0 ..< Int(entryCount) {
            let (entry, next) = try readCentralHeader(bytes, at: position)
            entries.append(entry)
            position = next
        }
        return entries
    }

    /// Scans backwards (the record may be followed by a comment of up to 65535 bytes). The
    /// candidate whose comment length lands exactly on the end of the file wins; a signature
    /// that merely appears inside a comment will not line up.
    private static func findEndOfCentralDirectory(_ bytes: ZipBytes) -> Int? {
        let count = bytes.count
        guard count >= 22 else { return nil }
        let lowest = max(0, count - 22 - 65535)
        var lenient: Int?
        var offset = count - 22
        while offset >= lowest {
            if let signature = try? bytes.u32(offset), signature == ZipSignature.endOfCentralDirectory,
               let commentLength = try? bytes.u16(offset + 20) {
                let end = offset + 22 + Int(commentLength)
                if end == count { return offset }
                if end < count, lenient == nil { lenient = offset }   // trailing junk after the comment
            }
            offset -= 1
        }
        return lenient
    }

    /// Parses one central directory header; returns the entry and the offset of the next header.
    private static func readCentralHeader(_ bytes: ZipBytes, at position: Int) throws -> (ZipEntry, Int) {
        guard try bytes.u32(position) == ZipSignature.centralHeader else { throw ZipError.truncated }
        let flags = try bytes.u16(position + 8)
        let method = try bytes.u16(position + 10)
        let crc = try bytes.u32(position + 16)
        var compressed = UInt64(try bytes.u32(position + 20))
        var uncompressed = UInt64(try bytes.u32(position + 24))
        let nameLength = Int(try bytes.u16(position + 28))
        let extraLength = Int(try bytes.u16(position + 30))
        let commentLength = Int(try bytes.u16(position + 32))
        var localOffset = UInt64(try bytes.u32(position + 42))

        let nameStart = position + 46
        let nameBytes = try bytes.slice(nameStart, nameLength)
        let extra = try bytes.slice(nameStart + nameLength, extraLength)
        try bytes.check(nameStart + nameLength + extraLength, commentLength)

        // ZIP64 extra field (id 0x0001): holds, in this order, only the values that were
        // saturated to 0xFFFFFFFF in the fixed header.
        var cursor = 0
        while cursor + 4 <= extra.count {
            let id = UInt16(littleEndian: extra.loadUnaligned(fromByteOffset: cursor, as: UInt16.self))
            let size = Int(UInt16(littleEndian: extra.loadUnaligned(fromByteOffset: cursor + 2, as: UInt16.self)))
            let body = cursor + 4
            guard body + size <= extra.count else { break }
            if id == 0x0001 {
                var field = body
                func next() -> UInt64? {
                    guard field + 8 <= body + size else { return nil }
                    defer { field += 8 }
                    return UInt64(littleEndian: extra.loadUnaligned(fromByteOffset: field, as: UInt64.self))
                }
                if uncompressed == 0xFFFF_FFFF, let value = next() { uncompressed = value }
                if compressed == 0xFFFF_FFFF, let value = next() { compressed = value }
                if localOffset == 0xFFFF_FFFF, let value = next() { localOffset = value }
            }
            cursor = body + size
        }

        let path = decodeName(nameBytes)
        let entry = ZipEntry(
            path: path,
            compressedSize: try bytes.int(compressed),
            uncompressedSize: try bytes.int(uncompressed),
            crc32: crc,
            isDirectory: path.hasSuffix("/"),
            method: method,
            flags: flags,
            localHeaderOffset: try bytes.int(localOffset))
        return (entry, nameStart + nameLength + extraLength + commentLength)
    }

    /// UTF-8 when valid (which covers both the bit-11 flag and the many writers that use UTF-8
    /// without setting it), otherwise ISO Latin-1, which accepts every byte.
    private static func decodeName(_ bytes: UnsafeRawBufferPointer) -> String {
        if let utf8 = String(validating: bytes, as: UTF8.self) { return utf8 }
        return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }
}
