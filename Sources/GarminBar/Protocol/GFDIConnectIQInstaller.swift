import Foundation
import CryptoKit

/// Legacy GFDI upload of an unmodified official CIQ package.
/// Wire evidence: APK ud6 (5005), iy9 (5003), sha (5004), wa3 (payload ceiling).
/// Completion here means byte transfer only; the session separately verifies installed UUID.
struct GFDIConnectIQInstaller {
    enum InstallError: LocalizedError {
        case invalidPackage, invalidSource, rejected(UInt8), invalidResponse, noSpace, offsetMismatch, crcMismatch
        var errorDescription: String? {
            switch self {
            case .invalidPackage: return "本地表盘包校验失败，请重新下载"
            case .invalidSource: return "表盘下载任务标识无效，请刷新下载任务"
            case .rejected(let status): return "手表拒绝表盘文件传输（状态 \(status)）"
            case .invalidResponse: return "手表返回的文件传输响应无效"
            case .noSpace: return "手表没有足够空间安装此表盘"
            case .offsetMismatch: return "手表文件传输位置不一致，安装已停止"
            case .crcMismatch: return "表盘文件传输校验失败，安装已停止"
            }
        }
    }
    private let data: Data
    let sourceMessageID: UInt64
    private(set) var offset = 0
    private(set) var crc: UInt16 = 0
    private var restart = false
    private var pendingBlock: (payload: Data, nextOffset: Int, nextCRC: UInt16)?
    var size: Int { data.count }
    var complete: Bool { offset == size }
    var progress: Double { Double(offset) / Double(size) }

    init(data: Data, expectedSHA256: String, sourceMessageID: UInt64) throws {
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024,
              expectedSHA256.count == 64,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedSHA256.lowercased() else {
            throw InstallError.invalidPackage
        }
        // The APK encodes the final ID byte with shift 54; below 2^54 this is exact LE64.
        guard sourceMessageID > 0, sourceMessageID < (UInt64(1) << 54) else { throw InstallError.invalidSource }
        self.data = data; self.sourceMessageID = sourceMessageID
    }

    var createRequest: Data {
        var writer = GFDIWriter()
        writer.u32(UInt32(size)); writer.u8(255); writer.data(Data([17, 0, 0]))
        writer.data(Data([0, 0, 255, 255])); writer.u16(0) // No remote pathname.
        writer.u64(sourceMessageID)
        return Data(writer.bytes)
    }
    static func createdIndex(_ response: Data) throws -> UInt16 {
        var reader = GFDIReader(response)
        let status = try reader.u8()
        guard status == 0 || status == 1 else {
            if status == 2 || status == 4 || status == 5 { throw InstallError.noSpace }
            throw InstallError.rejected(status)
        }
        return try reader.u16()
    }
    func uploadRequest(index: UInt16) -> Data {
        var writer = GFDIWriter()
        writer.u16(index); writer.u32(UInt32(size)); writer.u32(0); writer.u16(0)
        return Data(writer.bytes)
    }
    mutating func acceptUpload(_ response: Data) throws {
        var reader = GFDIReader(response)
        let status = try reader.u8()
        guard status == 0 else {
            if status == 3 { throw InstallError.noSpace }
            throw InstallError.rejected(status)
        }
        let remoteOffset = Int(try reader.u32()), maximumSize = Int(try reader.u32()), remoteCRC = try reader.u16()
        guard size <= maximumSize else { throw InstallError.noSpace }
        if remoteOffset >= size || GFDICRC.calculate(data.prefix(remoteOffset)) != remoteCRC {
            offset = 0; crc = 0; restart = true
        } else { offset = remoteOffset; crc = remoteCRC; restart = false }
        pendingBlock = nil
    }
    mutating func nextBlock(maximumPacketSize: Int) throws -> Data {
        if let pendingBlock { return pendingBlock.payload }
        guard offset < size, maximumPacketSize >= 24, maximumPacketSize <= 65535 else { throw InstallError.invalidResponse }
        // wa3.f subtracts COBS ceiling + GFDI overhead; sha then reserves 7 bytes.
        let payloadCeiling = maximumPacketSize - ((maximumPacketSize + 253) / 254) - 8
        let capacity = min(512, payloadCeiling - 7)
        guard capacity > 0 else { throw InstallError.invalidResponse }
        let end = min(size, offset + capacity)
        let chunk = data.subdata(in: offset..<end)
        let nextCRC = GFDICRC.calculate(chunk, initial: crc)
        var writer = GFDIWriter()
        writer.u8(restart ? 1 : 0); writer.u16(nextCRC); writer.u32(UInt32(offset)); writer.data(chunk)
        let payload = Data(writer.bytes)
        pendingBlock = (payload, end, nextCRC)
        return payload
    }
    /// false asks for the identical block again; no state or CRC advances on status 1.
    mutating func acceptBlock(_ response: Data) throws -> Bool {
        guard let block = pendingBlock else { throw InstallError.invalidResponse }
        var reader = GFDIReader(response)
        let status = try reader.u8()
        if status == 1 { return false }
        guard status == 0 else {
            if status == 3 { throw InstallError.crcMismatch }
            if status == 4 { throw InstallError.offsetMismatch }
            throw InstallError.rejected(status)
        }
        let next = Int(try reader.u32())
        guard next == block.nextOffset else { throw InstallError.offsetMismatch }
        offset = next; crc = block.nextCRC; restart = false; pendingBlock = nil
        return true
    }
}
