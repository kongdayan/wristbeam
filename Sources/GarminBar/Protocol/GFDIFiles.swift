import CryptoKit
import Darwin
import Foundation

struct GFDIDirectoryEntry: Equatable {
    let index: Int
    /// Garmin transport datatype; 128 means FIT, rather than a FIT message type.
    let dataType: Int
    /// Three-byte type identifier; the first byte is the FIT subtype (4 activity, 32 monitoring, etc.).
    let identifier: [UInt8]
    let flags: UInt8
    let size: Int
    let timestamp: UInt32
    var subtype: Int { Int(identifier[0]) }
    var isReadable: Bool { flags & 0x80 != 0 }

    // APK com/garmin/gfdi/file/a: 16-byte header then 16-byte entries.
    static func parseDirectory(_ data: Data) throws -> [GFDIDirectoryEntry] {
        guard data.count >= 16, (data.count - 16) % 16 == 0 else { throw GFDIProtocolError.invalidDirectory }
        var reader = GFDIReader(data)
        _ = try reader.data(16)
        var entries: [GFDIDirectoryEntry] = []
        var seen = Set<Int>()
        while reader.remaining > 0 {
            let index = Int(try reader.u16())
            let type = Int(try reader.u8())
            let identifier = Array(try reader.data(3))
            _ = try reader.u8() // reserved
            let flags = try reader.u8()
            let size = Int(try reader.u32())
            let timestamp = try reader.u32()
            // Index zero is the directory itself; a firmware may include that record or
            // empty slots in its directory. It must never be scheduled as a FIT download.
            if index == 0 { continue }
            guard !seen.contains(index) else { throw GFDIProtocolError.invalidDirectory }
            seen.insert(index)
            entries.append(GFDIDirectoryEntry(index: index, dataType: type, identifier: identifier, flags: flags, size: size, timestamp: timestamp))
        }
        return entries
    }
}

struct GFDIFileMetadata: Codable, Equatable {
    let recordID: String
    let deviceID: UInt32
    let index: Int
    let dataType: Int
    let subtype: Int
    let identifier: [UInt8]
    let timestamp: UInt32
    let fileSize: Int
    let sha256: String
    let filename: String
    let retrievedAt: Date

    var garminDate: Date { Date(timeIntervalSince1970: TimeInterval(timestamp) + 631_065_600) }
}

struct GFDIFileBlockResult {
    /// 0 OK/duplicate, 2 abort, 3 CRC mismatch, 4 incorrect offset. GFDI ACK stays 0.
    let status: UInt8
    let nextOffset: UInt32
    let bytesToAppend: Data
    let isComplete: Bool
    var responsePayload: Data {
        var writer = GFDIWriter()
        writer.u8(status)
        writer.u32(nextOffset)
        return Data(writer.bytes)
    }
}

/// Transactional block acceptance: CRC and offset are checked before changing accumulated state.
/// APK dr2/i: marker u8, cumulative CRC u16, offset u32, bytes to EOF.
struct GFDIFileReceiver {
    let finalSize: Int
    private(set) var receivedSize = 0
    private(set) var crc: UInt16 = 0
    private var lastOffset: UInt32?
    private var lastCRC: UInt16?
    private var lastBytes = Data()
    private var consecutiveInvalidBlocks = 0

    init(finalSize: Int) { self.finalSize = finalSize }

    mutating func accept(_ payload: Data) -> GFDIFileBlockResult {
        func result(_ status: UInt8, bytes: Data = Data()) -> GFDIFileBlockResult {
            GFDIFileBlockResult(status: status, nextOffset: UInt32(receivedSize), bytesToAppend: bytes, isComplete: receivedSize == finalSize)
        }
        guard finalSize >= 0, finalSize <= 64 * 1024 * 1024 else { return result(2) }
        guard payload.count >= 7 else { return result(2) }
        var reader = GFDIReader(payload)
        do {
            _ = try reader.u8()
            let expectedCRC = try reader.u16()
            let offset = try reader.u32()
            let bytes = try reader.data(reader.remaining)
            if Int(offset) != receivedSize {
                consecutiveInvalidBlocks += 1
                guard consecutiveInvalidBlocks <= 3 else { return result(2) }
                if offset == lastOffset, expectedCRC == lastCRC, bytes == lastBytes { return result(0) }
                return result(4)
            }
            guard !bytes.isEmpty, bytes.count <= finalSize - receivedSize else { return result(2) }
            let candidateCRC = GFDICRC.calculate(bytes, initial: crc)
            guard candidateCRC == expectedCRC else { return result(3) }
            crc = candidateCRC
            lastOffset = offset
            lastCRC = expectedCRC
            lastBytes = bytes
            receivedSize += bytes.count
            consecutiveInvalidBlocks = 0
            return result(0, bytes: bytes)
        } catch {
            return result(2)
        }
    }
}

/// Original files and immutable metadata are durable before the onFile callback is emitted.
/// No remote archive, erase, GUID overwrite, device setting or software update is performed here.
enum GFDIFileArchive {
    static func persist(_ data: Data, entry: GFDIDirectoryEntry, deviceID: UInt32, root: URL) throws -> (URL, GFDIFileMetadata) {
        guard data.count == entry.size else { throw GFDIProtocolError.invalidLength }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let identifier = entry.identifier.map { String(format: "%02x", $0) }.joined()
        let recordID = "\(deviceID)-\(entry.index)-\(entry.dataType)-\(identifier)-\(entry.timestamp)-\(digest)"
        let directory = root.appendingPathComponent(String(deviceID), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let filename = recordID + (entry.dataType == 128 ? ".fit" : ".bin")
        let file = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: file.path) {
            // Hash identity must agree with an existing immutable original.
            guard try Data(contentsOf: file) == data else { throw GFDIProtocolError.invalidCRC }
        } else {
            try durableWrite(data, to: file)
        }
        let metadata = GFDIFileMetadata(recordID: recordID, deviceID: deviceID, index: entry.index, dataType: entry.dataType, subtype: entry.subtype, identifier: entry.identifier, timestamp: entry.timestamp, fileSize: data.count, sha256: digest, filename: filename, retrievedAt: Date())
        let metadataURL = directory.appendingPathComponent(recordID + ".json")
        var effectiveMetadata = metadata
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            effectiveMetadata = try JSONDecoder().decode(GFDIFileMetadata.self, from: Data(contentsOf: metadataURL))
            guard effectiveMetadata.sha256 == digest, effectiveMetadata.fileSize == data.count else { throw GFDIProtocolError.invalidCRC }
        } else {
            try durableWrite(JSONEncoder().encode(metadata), to: metadataURL)
        }
        // A separate local queue can be consumed on restart without reading the watch again.
        let pending = root.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pendingURL = pending.appendingPathComponent(recordID + ".json")
        if !FileManager.default.fileExists(atPath: pendingURL.path) { try durableWrite(JSONEncoder().encode(effectiveMetadata), to: pendingURL) }
        return (file, effectiveMetadata)
    }

    static func pendingFiles(root: URL) throws -> [(URL, GFDIFileMetadata)] {
        let pending = root.appendingPathComponent("pending", isDirectory: true)
        guard FileManager.default.fileExists(atPath: pending.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { item in
            guard let bytes = try? Data(contentsOf: item), let metadata = try? JSONDecoder().decode(GFDIFileMetadata.self, from: bytes) else { return nil }
            let file = root.appendingPathComponent(String(metadata.deviceID)).appendingPathComponent(metadata.filename)
            guard metadata.filename == URL(fileURLWithPath: metadata.filename).lastPathComponent,
                  let original = try? Data(contentsOf: file), original.count == metadata.fileSize,
                  SHA256.hash(data: original).map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else { return nil }
            return (file, metadata)
        }
    }

    private static func durableWrite(_ data: Data, to url: URL) throws {
        // Foundation forbids combining .atomic with .withoutOverwriting. Stage on the same
        // volume, sync the bytes, then atomically publish a hard link: link(2) cannot replace
        // an existing immutable original, even if another process wins the creation race.
        let staged = url.deletingLastPathComponent().appendingPathComponent(".stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        let handle = try FileHandle(forWritingTo: staged)
        defer { try? handle.close() }
        try handle.synchronize()
        let result = staged.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return Int32(-1) }
                return Darwin.link(source, target)
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let directoryFD = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        if directoryFD >= 0 { _ = Darwin.fsync(directoryFD); _ = Darwin.close(directoryFD) }
    }
}
