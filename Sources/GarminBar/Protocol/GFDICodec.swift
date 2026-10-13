import Foundation

// Wire fields are independently implemented from the supplied APK:
// ir2/d (length/message/CRC), nr2/e (COBS), hq2/q4 (CRC-16/IBM).
enum GFDIProtocolError: Error, Equatable, LocalizedError {
    case truncated, invalidCOBS, invalidLength, invalidCRC, oversized, invalidDirectory

    var errorDescription: String? {
        switch self {
        case .truncated: return "协议数据长度不足"
        case .invalidCOBS: return "蓝牙消息分帧错误"
        case .invalidLength: return "蓝牙消息长度错误"
        case .invalidCRC: return "蓝牙消息校验失败"
        case .oversized: return "蓝牙消息或文件超出大小限制"
        case .invalidDirectory: return "手表文件目录格式错误"
        }
    }
}

enum GFDICRC {
    /// Reflected CRC-16/IBM, polynomial 0xA001, initial value 0.
    static func calculate<S: Sequence>(_ bytes: S, initial: UInt16 = 0) -> UInt16 where S.Element == UInt8 {
        var crc = initial
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }
}

enum GFDICOBS {
    static func encode(_ bytes: Data) -> Data {
        var output: [UInt8] = [0]
        var codeIndex = 0
        var code: UInt8 = 1
        for byte in bytes {
            if byte == 0 {
                output[codeIndex] = code
                codeIndex = output.count
                output.append(0)
                code = 1
            } else {
                output.append(byte)
                code &+= 1
                if code == 255 {
                    output[codeIndex] = code
                    codeIndex = output.count
                    output.append(0)
                    code = 1
                }
            }
        }
        output[codeIndex] = code
        return Data(output)
    }

    /// Input excludes the framing zeros.
    static func decode(_ data: Data) throws -> Data {
        let bytes = Array(data)
        guard !bytes.isEmpty else { throw GFDIProtocolError.invalidCOBS }
        var output: [UInt8] = []
        var cursor = 0
        while cursor < bytes.count {
            let code = Int(bytes[cursor])
            guard code > 0, cursor + code <= bytes.count else { throw GFDIProtocolError.invalidCOBS }
            cursor += 1
            let end = cursor + code - 1
            guard !bytes[cursor..<end].contains(0) else { throw GFDIProtocolError.invalidCOBS }
            output.append(contentsOf: bytes[cursor..<end])
            cursor = end
            if code < 255, cursor < bytes.count { output.append(0) }
        }
        return Data(output)
    }
}

struct GFDIMessage: Equatable {
    let number: UInt16
    let payload: Data
    let sequence: UInt8?

    init(number: UInt16, payload: Data = Data(), sequence: UInt8? = nil) {
        self.number = number
        self.payload = payload
        self.sequence = sequence
    }

    /// Includes the length word and final CRC word, excluding COBS framing.
    func packet() throws -> Data {
        guard payload.count <= 65_529 else { throw GFDIProtocolError.oversized }
        var bytes = GFDIWriter()
        bytes.u16(UInt16(payload.count + 6))
        if let sequence {
            guard (5000...5255).contains(number), sequence < 128 else { throw GFDIProtocolError.invalidLength }
            bytes.u8(UInt8(number - 5000))
            bytes.u8(sequence | 0x80)
        } else {
            bytes.u16(number)
        }
        bytes.data(payload)
        bytes.u16(GFDICRC.calculate(bytes.bytes))
        return Data(bytes.bytes)
    }

    func framed() throws -> Data { Data([0]) + GFDICOBS.encode(try packet()) + Data([0]) }

    static func decode(_ packet: Data) throws -> GFDIMessage {
        let bytes = Array(packet)
        guard bytes.count >= 6 else { throw GFDIProtocolError.truncated }
        guard Int(bytes[0]) | (Int(bytes[1]) << 8) == bytes.count else { throw GFDIProtocolError.invalidLength }
        guard GFDICRC.calculate(bytes) == 0 else { throw GFDIProtocolError.invalidCRC }
        let compact = bytes[3] & 0x80 != 0
        let number = compact ? UInt16(bytes[2]) + 5000 : UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        return GFDIMessage(number: number, payload: Data(bytes[4..<(bytes.count - 2)]), sequence: compact ? bytes[3] & 0x7f : nil)
    }

    func response(status: UInt8 = 0, payload responsePayload: Data = Data()) -> GFDIMessage {
        var writer = GFDIWriter()
        writer.u16(number)
        writer.u8(status)
        writer.data(responsePayload)
        return GFDIMessage(number: 5000, payload: Data(writer.bytes), sequence: sequence)
    }
}

/// Handles both multiple frames per notification and frames split over arbitrary BLE packets.
struct GFDIStreamDecoder {
    private var buffer: [UInt8] = []
    private var hasDelimiter = false
    private var discardUntilDelimiter = false
    let maximumEncodedLength = 65_800

    mutating func receive(_ data: Data) -> [Result<GFDIMessage, Error>] {
        var messages: [Result<GFDIMessage, Error>] = []
        for byte in data {
            if byte == 0 {
                if hasDelimiter, !buffer.isEmpty, !discardUntilDelimiter {
                    messages.append(Result { try GFDIMessage.decode(GFDICOBS.decode(Data(buffer))) })
                }
                hasDelimiter = true
                buffer.removeAll(keepingCapacity: true)
                discardUntilDelimiter = false
            } else if hasDelimiter, !discardUntilDelimiter {
                buffer.append(byte)
                if buffer.count > maximumEncodedLength {
                    messages.append(.failure(GFDIProtocolError.oversized))
                    buffer.removeAll(keepingCapacity: true)
                    discardUntilDelimiter = true
                }
            }
        }
        return messages
    }
}

struct GFDIWriter {
    private(set) var bytes: [UInt8] = []
    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { bytes += [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)] }
    mutating func u32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func u64(_ value: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) } }
    mutating func data(_ data: Data) { bytes += data }
    mutating func string(_ string: String) { let value = Array(string.utf8.prefix(255)); u8(UInt8(value.count)); bytes += value }
}

struct GFDIReader {
    let bytes: [UInt8]
    private(set) var cursor = 0
    init(_ data: Data) { bytes = Array(data) }
    var remaining: Int { bytes.count - cursor }
    mutating func data(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw GFDIProtocolError.truncated }
        defer { cursor += count }
        return Data(bytes[cursor..<(cursor + count)])
    }
    mutating func u8() throws -> UInt8 { let value = try data(1); return value[value.startIndex] }
    mutating func u16() throws -> UInt16 { let value = Array(try data(2)); return UInt16(value[0]) | UInt16(value[1]) << 8 }
    mutating func u32() throws -> UInt32 { let value = Array(try data(4)); return value.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) } }
    mutating func u64() throws -> UInt64 { let value = Array(try data(8)); return value.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) } }
    mutating func string() throws -> String { let size = Int(try u8()); return String(decoding: try data(size), as: UTF8.self) }
}
