import Foundation

indirect enum GFDIMonkeyValue: Equatable {
    case null, int32(Int32), float(Float), string(String), array([Self]), bool(Bool)
    case dictionary([String: Self]), int64(Int64), double(Double), character(UInt32), bytes(Data)

    func jsonObject() throws -> Any {
        switch self {
        case .null: return NSNull()
        case .int32(let x): return NSNumber(value: x)
        case .int64(let x): return NSNumber(value: x)
        case .float(let x): guard x.isFinite else { throw GFDIConnectIQSettingsError.malformed }; return NSNumber(value: x)
        case .double(let x): guard x.isFinite else { throw GFDIConnectIQSettingsError.malformed }; return NSNumber(value: x)
        case .string(let x): return x
        case .bool(let x): return x
        case .character(let x): return NSNumber(value: x)
        case .bytes(let x): return x.map { Int($0) }
        case .array(let x): return try x.map { try $0.jsonObject() }
        case .dictionary(let x): return try x.mapValues { try $0.jsonObject() }
        }
    }
    func jsonData() throws -> Data {
        let object = try jsonObject()
        guard JSONSerialization.isValidJSONObject(object) else { throw GFDIConnectIQSettingsError.malformed }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }
}

struct GFDIConnectIQSettingsSnapshot {
    let appID: String
    let unitID: UInt32
    let values: GFDIMonkeyValue
    let jsonData: Data
    let rawData: Data
    let savedAndVerified: Bool
    let revision = UUID()
}

enum GFDIConnectIQSettingsError: LocalizedError {
    case malformed, unsupported, notInstalled, saveRejected, unconfirmed, stale
    var errorDescription: String? {
        switch self {
        case .malformed: return "表盘设置数据无效"
        case .unsupported: return "此表盘设置包含暂不支持的数据类型"
        case .notInstalled: return "手表未找到所选表盘，请重新读取已安装列表"
        case .saveRejected: return "手表未接受表盘设置"
        case .unconfirmed: return "设置已发送，但回读结果尚未确认，请重新读取"
        case .stale: return "设备、账户或设置已变化，请重新读取"
        }
    }
}

/// Monkey C settings serialization, APK d55.h/y + sh2, u27 and scalar classes.
/// Container children are breadth-first, not recursive on the wire. Integers are BE.
/// String keys are required for JSON settings; no unknown property is silently dropped.
/// Structural diagnostics only: never include property names, values or raw bytes.
struct GFDISettingsParseError: LocalizedError {
    let stage: String
    let offset: Int
    let remaining: Int
    var errorDescription: String? { GFDIConnectIQSettingsError.malformed.errorDescription }
    var diagnostic: String { "\(stage): offset=\(offset), remaining=\(remaining)" }
}

enum GFDIMonkeyCodec {
    static let maximumBytes = 256 * 1024
    private final class Node {
        var value: GFDIMonkeyValue?
        var count: Int = 0
        var dictionary = false
        var children: [Node] = []
        init(_ value: GFDIMonkeyValue? = nil) { self.value = value }
    }
    private struct Reader {
        let data: [UInt8]
        var offset = 0
        var remaining: Int { data.count - offset }
        func failure(_ stage: String) -> GFDISettingsParseError {
            GFDISettingsParseError(stage: stage, offset: offset, remaining: remaining)
        }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw failure("truncated-value") }
            defer { offset += count }; return Data(data[offset..<offset + count])
        }
        mutating func byte() throws -> UInt8 { guard remaining > 0 else { throw GFDIConnectIQSettingsError.malformed }; defer { offset += 1 }; return data[offset] }
        mutating func number(_ size: Int) throws -> UInt64 { try take(size).reduce(0) { ($0 << 8) | UInt64($1) } }
    }
    static func decode(_ data: Data) throws -> GFDIMonkeyValue {
        if data.isEmpty { return .dictionary([:]) } // z60: empty settings is {}.
        guard data.count <= maximumBytes else { throw GFDIProtocolError.oversized }
        var reader = Reader(data: Array(data)), strings: [UInt32: String] = [:]
        var tag = try reader.number(4)
        if tag == 0xabcdabcd {
            let size = Int(try reader.number(4))
            var table = Reader(data: Array(try reader.take(size)))
            while table.remaining > 0 {
                let offset = UInt32(table.offset), length = Int(try table.number(2))
                guard length > 0, length <= 32767 else { throw table.failure("string-length") }
                let bytes = try table.take(length)
                guard bytes.last == 0, let text = String(data: bytes.dropLast(), encoding: .utf8) else { throw table.failure("string-encoding") }
                strings[offset] = text
            }
            tag = try reader.number(4)
        }
        guard tag == 0xda7ada7a else { throw reader.failure("object-marker") }
        let objectSize = Int(try reader.number(4))
        guard objectSize == reader.remaining else { throw reader.failure("object-size-\(objectSize)") }
        if objectSize == 0 { return .dictionary([:]) } // ahc.m also accepts an empty object list.
        var nodes: [Node] = []
        while reader.remaining > 0 {
            guard nodes.count < 8192 else { throw GFDIProtocolError.oversized }
            let node = Node()
            switch try reader.byte() {
            case 0: node.value = .null
            case 1: node.value = .int32(Int32(bitPattern: UInt32(try reader.number(4))))
            case 2: node.value = .float(Float(bitPattern: UInt32(try reader.number(4))))
            case 3:
                guard let text = strings[UInt32(try reader.number(4))] else { throw reader.failure("string-reference") }
                node.value = .string(text)
            case 5: node.count = Int(try reader.number(4))
            case 9: let value = try reader.byte(); guard value <= 1 else { throw reader.failure("boolean-value") }; node.value = .bool(value != 0)
            case 11: node.count = Int(try reader.number(4)); node.dictionary = true
            case 14: node.value = .int64(Int64(bitPattern: try reader.number(8)))
            case 15: node.value = .double(Double(bitPattern: try reader.number(8)))
            case 19: node.value = .character(UInt32(try reader.number(4)))
            case 20:
                let length = Int(try reader.number(4))
                node.value = .bytes(try reader.take(length))
            default: throw GFDIConnectIQSettingsError.unsupported
            }
            guard node.count <= 4096 else { throw GFDIProtocolError.oversized }
            nodes.append(node)
        }
        guard let root = nodes.first else { throw GFDIConnectIQSettingsError.malformed }
        var nextChild = 1
        for node in nodes where node.value == nil {
            let count = node.count * (node.dictionary ? 2 : 1)
            guard count <= nodes.count - nextChild else { throw reader.failure("container-children") }
            node.children = Array(nodes[nextChild..<nextChild + count]); nextChild += count
        }
        guard nextChild == nodes.count else { throw reader.failure("extra-roots") }
        func materialize(_ node: Node, depth: Int) throws -> GFDIMonkeyValue {
            guard depth <= 32 else { throw GFDIProtocolError.oversized }
            if let value = node.value { return value }
            if !node.dictionary { return .array(try node.children.map { try materialize($0, depth: depth + 1) }) }
            var dictionary: [String: GFDIMonkeyValue] = [:]
            for index in stride(from: 0, to: node.children.count, by: 2) {
                guard case let .string(key) = try materialize(node.children[index], depth: depth + 1), dictionary[key] == nil else { throw reader.failure("dictionary-key") }
                dictionary[key] = try materialize(node.children[index + 1], depth: depth + 1)
            }
            return .dictionary(dictionary)
        }
        let value = try materialize(root, depth: 0)
        _ = try value.jsonData() // Reject non-finite values and non-container roots.
        return value
    }

    /// Used for offline round-trip verification; production saves use Garmin's binary endpoint.
    static func encode(_ value: GFDIMonkeyValue) throws -> Data {
        var strings = Data(), objects = Data(), stringOffsets: [String: UInt32] = [:]
        func be(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        var queue = [value], index = 0
        while index < queue.count {
            guard queue.count <= 8192, objects.count + strings.count <= maximumBytes else { throw GFDIProtocolError.oversized }
            let item = queue[index]; index += 1
            switch item {
            case .null: objects.append(0)
            case .int32(let x): objects.append(1); objects += be(UInt64(UInt32(bitPattern: x)), 4)
            case .float(let x): objects.append(2); objects += be(UInt64(x.bitPattern), 4)
            case .string(let x):
                if stringOffsets[x] == nil {
                    let bytes = Data(x.utf8); guard bytes.count + 1 <= 32767 else { throw GFDIProtocolError.oversized }
                    stringOffsets[x] = UInt32(strings.count); strings += be(UInt64(bytes.count + 1), 2) + bytes + Data([0])
                }
                objects.append(3); objects += be(UInt64(stringOffsets[x]!), 4)
            case .array(let x): objects.append(5); objects += be(UInt64(x.count), 4); queue += x
            case .bool(let x): objects += Data([9, x ? 1 : 0])
            case .dictionary(let x):
                objects.append(11); objects += be(UInt64(x.count), 4)
                for key in x.keys.sorted() { queue.append(.string(key)); queue.append(x[key]!) }
            case .int64(let x): objects.append(14); objects += be(UInt64(bitPattern: x), 8)
            case .double(let x): objects.append(15); objects += be(x.bitPattern, 8)
            case .character(let x): objects.append(19); objects += be(UInt64(x), 4)
            case .bytes(let x): objects.append(20); objects += be(UInt64(x.count), 4) + x
            }
        }
        let result = (strings.isEmpty ? Data() : be(0xabcdabcd, 4) + be(UInt64(strings.count), 4) + strings)
            + be(0xda7ada7a, 4) + be(UInt64(objects.count), 4) + objects
        guard result.count <= maximumBytes else { throw GFDIProtocolError.oversized }
        _ = try decode(result)
        return result
    }
}

enum GFDIConnectIQSettings {
    typealias Proto = GFDIConnectIQ.Proto
    static func request(appID: String, settingsData: Data? = nil) throws -> Data {
        let identity = try GFDIConnectIQSDK.uuidBytes(appID)
        if let settingsData {
            _ = try GFDIMonkeyCodec.decode(settingsData)
            return Proto.bytes(4, Proto.bytes(3, Proto.bytes(1, identity) + Proto.bytes(2, settingsData)))
        }
        return Proto.bytes(4, Proto.bytes(1, Proto.bytes(1, identity)))
    }
    static func checkResponse(_ data: Data, appID: String, saving: Bool) throws {
        let root = try Proto(data)
        guard let serviceData = try root.blob(4), let responseData = try Proto(serviceData).blob(saving ? 4 : 2) else { throw GFDISettingsParseError(stage: saving ? "save-response" : "get-response", offset: 0, remaining: data.count) }
        let response = try Proto(responseData)
        guard try response.blob(1) == GFDIConnectIQSDK.uuidBytes(appID) else { throw GFDIConnectIQSettingsError.stale }
        guard let status = try response.number(2) else { throw GFDISettingsParseError(stage: "missing-response-status", offset: 0, remaining: responseData.count) }
        if status == 2 { throw saving ? GFDIConnectIQSettingsError.saveRejected : GFDIConnectIQSettingsError.notInstalled }
        guard status == 1 else { throw GFDIConnectIQSettingsError.malformed }
    }
    static func push(_ data: Data) throws -> (appID: String, data: Data)? {
        guard let serviceData = try Proto(data).blob(4), let requestData = try Proto(serviceData).blob(5) else { return nil }
        let request = try Proto(requestData)
        guard let id = try request.blob(1), id.count == 16 else { throw GFDIConnectIQSettingsError.malformed }
        let bytes = [UInt8](id)
        let uuid = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
        let data = try request.blob(2) ?? Data()
        guard data.count <= GFDIMonkeyCodec.maximumBytes else { throw GFDIProtocolError.oversized }
        return (uuid.uuidString.lowercased(), data)
    }
    static let pushResponse = Proto.bytes(4, Proto.bytes(6, Proto.integer(1, 1)))
}
