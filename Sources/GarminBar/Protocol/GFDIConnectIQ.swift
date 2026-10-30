import Foundation

/// A device-returned RTS choice, not a store listing or an arbitrary Connect IQ UUID.
struct GFDIWatchFaceOption: Equatable, Identifiable {
    let unitID: UInt32
    let compositionID: UInt32
    let compositionVersion: UInt32
    let globalVersion: UInt32
    let rowID: UInt32
    let index: UInt32
    let title: String
    let imageName: String?
    var isSelected: Bool?
    var id: String { "\(compositionID)-\(rowID)-\(index)" }
}

/// Actual on-device CIQ inventory. Disabled/favorite are not current-watchface indicators.
struct GFDIInstalledWatchFace: Equatable, Identifiable {
    let unitID: UInt32
    let id: String
    let name: String
    let version: UInt32?
    let filename: String?
    let fileSize: UInt64?
    let disabled: Bool
    let favorite: Bool?
    let nativeAppID: UInt32?
}

struct GFDIInstalledWatchFaceInventory: Equatable {
    let availableSpace: UInt64
    let availableSlots: UInt32
    let apps: [GFDIInstalledWatchFace]
}

enum GFDIConnectIQError: LocalizedError {
    case unavailable, emptyResponse, malformed, rejected, stale, unconfirmed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "手表没有提供可切换的表盘列表"
        case .emptyResponse: return "手表返回了空表盘数据，暂无法读取或切换"
        case .malformed: return "手表返回的表盘数据不完整，请重新读取"
        case .rejected: return "手表未接受表盘请求"
        case .stale: return "设备或表盘列表已变化，请重新读取"
        case .unconfirmed: return "尚未确认表盘已切换，请重新读取并查看手表"
        }
    }
}

/// Independent wire encoding from GDIRealtimeSettingsProto / Extension descriptors.
/// APK ow1/c -> wt2/d -> nu2/i1.D sends grid index under SettingsChangeRequest field 16.
/// LaunchApp is intentionally not used: its applicability to watch faces is unproven.
enum GFDIConnectIQ {
    static let watchFaceComposition: UInt32 = 36361

    /// Smart extension 3, get_installed_apps_request 1, app_type WATCH_FACE 3.
    /// APK ConnectIQRequestManager.a0.d and p13 use this inventory service.
    static let installedWatchFacesQuery = Data([0x1a, 4, 0x0a, 2, 8, 3])

    static func installedWatchFaces(_ smart: Data, unitID: UInt32) throws -> GFDIInstalledWatchFaceInventory {
        guard !smart.isEmpty else { throw GFDIConnectIQError.emptyResponse }
        guard let service = try Proto(smart).blob(3), let response = try Proto(service).blob(2) else { throw GFDIConnectIQError.malformed }
        let inventory = try Proto(response)
        guard let space = try inventory.number(1) else { throw GFDIConnectIQError.malformed }
        let slots = try inventory.requiredUInt32(2)
        let records = inventory.blobs(3)
        guard records.count <= 256 else { throw GFDIProtocolError.oversized }
        var seen = Set<String>(), apps: [GFDIInstalledWatchFace] = []
        for bytes in records {
            let app = try Proto(bytes)
            guard try app.requiredUInt32(2) == 3 else { continue }
            guard let uuid = try app.blob(1), uuid.count == 16, let name = try app.text(3),
                  let disabled = try app.number(4), disabled <= 1 else { throw GFDIConnectIQError.malformed }
            let hex = uuid.map { String(format: "%02x", $0) }.joined()
            let id = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.suffix(12))"
            guard seen.insert(id).inserted else { throw GFDIConnectIQError.malformed }
            let version = try app.number(5), nativeID = try app.number(8), favorite = try app.number(9)
            guard version == nil || version! <= UInt64(UInt32.max), nativeID == nil || nativeID! <= UInt64(UInt32.max),
                  favorite == nil || favorite! <= 1 else { throw GFDIConnectIQError.malformed }
            apps.append(GFDIInstalledWatchFace(unitID: unitID, id: id, name: name,
                version: version.map { UInt32($0) }, filename: try app.text(6), fileSize: try app.number(7),
                disabled: disabled == 1, favorite: favorite.map { $0 == 1 }, nativeAppID: nativeID.map { UInt32($0) }))
        }
        return GFDIInstalledWatchFaceInventory(availableSpace: space, availableSlots: slots, apps: apps)
    }

    static func compositionQuery(id: UInt32 = watchFaceComposition, locale: String = "zh_CN") -> Data {
        wrap(1, Proto.integer(1, UInt64(id)) + Proto.integer(2, 2) + Proto.bytes(3, Data(locale.utf8)))
    }
    /// Official RTS initialization asks for locale resources and the communication mode.
    /// No consent country is asserted on behalf of the user.
    static func startupQuery(locale: String = "zh_CN") -> Data { wrap(8, Proto.bytes(1, Data(locale.utf8))) }
    static func startupCommunicationMode(_ data: Data) throws -> UInt64? {
        guard let service = try Proto(data).blob(42), let response = try Proto(service).blob(9) else { return nil }
        let mode = try Proto(response).number(4) ?? 0
        guard mode <= 1 else { throw GFDIConnectIQError.malformed }
        return mode
    }
    static func settingsQuery(composition: UInt32, locale: String = "zh_CN") -> Data {
        wrap(3, Proto.integer(1, UInt64(composition)) + Proto.bytes(2, Data(locale.utf8)))
    }
    static func selection(_ choice: GFDIWatchFaceOption) -> Data {
        wrap(5, Proto.integer(1, UInt64(choice.compositionID)) + Proto.integer(2, UInt64(choice.rowID))
             + Proto.bytes(16, Proto.integer(1, UInt64(choice.index))))
    }
    private static func wrap(_ field: UInt64, _ data: Data) -> Data { Proto.bytes(42, Proto.bytes(field, data)) }

    static func choices(_ smart: Data, unitID: UInt32) throws -> [GFDIWatchFaceOption] {
        let response = try serviceResponse(smart, field: 2)
        guard (try response.number(1) ?? 0) <= 1 else { throw GFDIConnectIQError.rejected }
        let compositions = response.blobs(2)
        guard compositions.count <= 32 else { throw GFDIProtocolError.oversized }
        var result: [GFDIWatchFaceOption] = []
        var identifiers = Set<String>()
        for bytes in compositions {
            let composition = try Proto(bytes)
            let compositionID = try composition.requiredUInt32(1)
            let compositionVersion = try composition.requiredUInt32(2)
            let globalVersion = try composition.requiredUInt32(3)
            let rows = composition.blobs(5)
            guard rows.count <= 128 else { throw GFDIProtocolError.oversized }
            for rowBytes in rows {
                let row = try Proto(rowBytes)
                guard try row.number(2) == 25, let optionsBytes = try row.blob(19) else { continue }
                // DEVICE-only rows are not controls offered to companion applications.
                guard try row.number(4) != 3 else { continue }
                let rowID = try row.requiredUInt32(1)
                let options = try Proto(optionsBytes)
                let rowTitle = try row.blob(3).flatMap { try Proto($0).text(2) }
                let items = options.blobs(3)
                guard items.count <= 64 else { throw GFDIProtocolError.oversized }
                for itemBytes in items {
                    let item = try Proto(itemBytes)
                    let index = try item.requiredUInt32(1)
                    let imageName = try item.text(2)
                    let title = "\(rowTitle?.isEmpty == false ? rowTitle! : "表盘") \(UInt64(index) + 1)"
                    let choice = GFDIWatchFaceOption(unitID: unitID, compositionID: compositionID, compositionVersion: compositionVersion, globalVersion: globalVersion, rowID: rowID,
                                                  index: index, title: title, imageName: imageName, isSelected: nil)
                    guard identifiers.insert(choice.id).inserted else { throw GFDIConnectIQError.malformed }
                    result.append(choice)
                }
            }
        }
        guard !result.isEmpty else { throw GFDIConnectIQError.unavailable }
        return result
    }

    static func applySettings(_ smart: Data, compositionID: UInt32, choices: [GFDIWatchFaceOption]) throws -> [GFDIWatchFaceOption] {
        let response = try serviceResponse(smart, field: 4)
        guard (try response.number(1) ?? 0) == 0 else { throw GFDIConnectIQError.rejected }
        guard let bytes = try response.blob(2) else { throw GFDIConnectIQError.malformed }
        let settings = try Proto(bytes)
        guard try settings.requiredUInt32(1) == compositionID else { throw GFDIConnectIQError.stale }
        let version = try settings.requiredUInt32(2), globalVersion = try settings.requiredUInt32(3)
        guard choices.filter({ $0.compositionID == compositionID }).allSatisfy({ $0.compositionVersion == version && $0.globalVersion == globalVersion }) else {
            throw GFDIConnectIQError.stale
        }
        var values: [String: Bool] = [:]
        for rowBytes in settings.blobs(4) {
            let row = try Proto(rowBytes)
            guard let gridBytes = try row.blob(10) else { continue }
            let rowID = try row.requiredUInt32(1)
            guard (try row.number(2) ?? 0) == 0 else { throw GFDIConnectIQError.unavailable }
            for valueBytes in try Proto(gridBytes).blobs(1) {
                let value = try Proto(valueBytes)
                let index = try value.requiredUInt32(1)
                guard let selected = try value.number(2), selected <= 1 else { throw GFDIConnectIQError.malformed }
                let id = "\(compositionID)-\(rowID)-\(index)"
                guard values.updateValue(selected == 1, forKey: id) == nil else { throw GFDIConnectIQError.malformed }
            }
        }
        var updated = choices
        for index in updated.indices where updated[index].compositionID == compositionID {
            guard let selected = values[updated[index].id] else { throw GFDIConnectIQError.malformed }
            updated[index].isSelected = selected
        }
        let groups = Dictionary(grouping: updated.filter { $0.compositionID == compositionID }, by: \.rowID)
        guard groups.values.allSatisfy({ $0.filter { $0.isSelected == true }.count == 1 }) else { throw GFDIConnectIQError.malformed }
        return updated
    }

    static func checkSelectionResponse(_ smart: Data) throws {
        let response = try serviceResponse(smart, field: 6)
        // A missing status is not sufficient evidence for a device write acknowledgement.
        guard try response.number(1) == 0 else { throw GFDIConnectIQError.rejected }
    }
    private static func serviceResponse(_ smart: Data, field: UInt64) throws -> Proto {
        guard !smart.isEmpty else { throw GFDIConnectIQError.emptyResponse }
        guard let service = try Proto(smart).blob(42), let response = try Proto(service).blob(field) else {
            throw GFDIConnectIQError.malformed
        }
        return try Proto(response)
    }

    /// Minimal bounded protobuf parser, preserving repeated fields and rejecting duplicate scalars.
    struct Proto {
        enum Value { case integer(UInt64), bytes(Data) }
        var fields: [(UInt64, Value)] = []
        init(_ data: Data) throws {
            guard data.count <= 512 * 1024 else { throw GFDIProtocolError.oversized }
            var reader = GFDIReader(data)
            func varint() throws -> UInt64 {
                var result: UInt64 = 0
                for index in 0..<10 {
                    let byte = try reader.u8()
                    guard index < 9 || byte < 2 else { throw GFDIProtocolError.invalidLength }
                    result |= UInt64(byte & 127) << (index * 7)
                    if byte & 128 == 0 { return result }
                }
                throw GFDIProtocolError.invalidLength
            }
            while reader.remaining > 0 {
                guard fields.count < 8192 else { throw GFDIProtocolError.oversized }
                let tag = try varint()
                guard tag >> 3 > 0 else { throw GFDIProtocolError.invalidLength }
                switch tag & 7 {
                case 0: fields.append((tag >> 3, .integer(try varint())))
                case 1: _ = try reader.data(8)
                case 2:
                    let length = try varint()
                    guard length <= UInt64(reader.remaining) else { throw GFDIProtocolError.truncated }
                    fields.append((tag >> 3, .bytes(try reader.data(Int(length)))))
                case 5: _ = try reader.data(4)
                default: throw GFDIProtocolError.invalidLength
                }
            }
        }
        func number(_ field: UInt64) throws -> UInt64? {
            let matches = fields.filter { $0.0 == field }
            guard matches.count <= 1 else { throw GFDIConnectIQError.malformed }
            guard let value = matches.first?.1 else { return nil }
            guard case let .integer(number) = value else { throw GFDIConnectIQError.malformed }
            return number
        }
        func requiredUInt32(_ field: UInt64) throws -> UInt32 {
            guard let value = try number(field), let result = UInt32(exactly: value) else { throw GFDIConnectIQError.malformed }
            return result
        }
        func blobs(_ field: UInt64) -> [Data] {
            fields.compactMap { key, value in guard key == field, case let .bytes(data) = value else { return nil }; return data }
        }
        func blob(_ field: UInt64) throws -> Data? {
            let matches = fields.filter { $0.0 == field }
            guard matches.count <= 1 else { throw GFDIConnectIQError.malformed }
            guard let value = matches.first?.1 else { return nil }
            guard case let .bytes(data) = value else { throw GFDIConnectIQError.malformed }
            return data
        }
        func text(_ field: UInt64) throws -> String? {
            guard let data = try blob(field) else { return nil }
            guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else { throw GFDIConnectIQError.malformed }
            return text
        }
        static func varint(_ value: UInt64) -> Data {
            var remaining = value, bytes = Data()
            repeat { bytes.append(UInt8(remaining & 127) | (remaining > 127 ? 128 : 0)); remaining >>= 7 } while remaining != 0
            return bytes
        }
        static func integer(_ field: UInt64, _ value: UInt64) -> Data { varint(field << 3) + varint(value) }
        static func bytes(_ field: UInt64, _ value: Data) -> Data { varint((field << 3) | 2) + varint(UInt64(value.count)) + value }
    }
}

/// RTS notifications carry their own transport IDs, not the initiating query ID.
/// Correlate the response kind and device-returned composition instead (APK ru2/c, nu2/i1).
struct GFDIRealtimeSettingsQuery {
    let responseField: UInt64
    let compositionID: UInt32

    init?(_ data: Data) throws {
        typealias P = GFDIConnectIQ.Proto
        guard let bytes = try P(data).blob(42) else { return nil }
        let service = try P(bytes)
        let requests = try [UInt64(1), 3, 5].compactMap { field -> (UInt64, Data)? in
            try service.blob(field).map { (field, $0) }
        }
        // Startup itself uses request/response before the official client knows the mode.
        if try service.blob(8) != nil, requests.isEmpty { return nil }
        guard requests.count == 1, let request = requests.first else { throw GFDIConnectIQError.malformed }
        responseField = request.0 + 1
        compositionID = try P(request.1).requiredUInt32(1)
    }

    func accepts(_ data: Data) throws -> Bool {
        typealias P = GFDIConnectIQ.Proto
        guard let bytes = try P(data).blob(42) else { return false }
        let service = try P(bytes)
        let responses = try [UInt64(2), 4, 6].compactMap { field -> (UInt64, Data)? in
            try service.blob(field).map { (field, $0) }
        }
        guard responses.count == 1, let response = responses.first, response.0 == responseField else { return false }
        let body = try P(response.1)
        let settings = responseField == 6 ? try body.blob(3).map { [$0] } ?? [] : body.blobs(2)
        // Empty/error responses still reach the operation's strict decoder; never invent choices.
        guard !settings.isEmpty else { return true }
        return try settings.contains { try P($0).requiredUInt32(1) == compositionID }
    }

    static func isNotification(_ data: Data) throws -> Bool {
        typealias P = GFDIConnectIQ.Proto
        guard let bytes = try P(data).blob(42) else { return false }
        let service = try P(bytes)
        return try [UInt64(2), 4, 6, 7, 9, 11, 13].contains { try service.blob($0) != nil }
    }
}

/// Correlated protobuf fragments. Same jr2/d envelope for responses and notifications.
struct GFDIConnectIQTransfer {
    let requestID: UInt16
    private(set) var data = Data()
    private var totalSize: Int?
    private(set) var complete = false
    init(requestID: UInt16) { self.requestID = requestID }
    mutating func accept(_ payload: Data) throws -> (ack: Data, duplicate: Bool) {
        var reader = GFDIReader(payload)
        guard try reader.u16() == requestID else { throw GFDIProtocolError.invalidLength }
        let offset = Int(try reader.u32()), total = Int(try reader.u32()), size = Int(try reader.u32())
        guard total <= 512 * 1024 else { throw GFDIProtocolError.oversized }
        // Empty protobuf responses are valid transport frames (APK jr2/d).
        // Acknowledge them, then report the absent service data to the caller.
        if total == 0 {
            guard offset == 0, size == 0, reader.remaining == 0,
                  totalSize == nil || totalSize == 0 else { throw GFDIProtocolError.invalidLength }
            let duplicate = complete
            totalSize = 0; complete = true
            var ack = GFDIWriter(); ack.u16(requestID); ack.u32(0); ack.u8(0); ack.u8(duplicate ? 101 : 0)
            return (Data(ack.bytes), duplicate)
        }
        guard size > 0, size == reader.remaining, offset <= total, size <= total - offset,
              totalSize == nil || totalSize == total else { throw GFDIProtocolError.invalidLength }
        let bytes = try reader.data(size)
        let duplicate = offset < data.count
        if duplicate {
            guard size <= data.count - offset, data.subdata(in: offset..<(offset + size)) == bytes else { throw GFDIProtocolError.invalidCRC }
        } else {
            guard offset == data.count else { throw GFDIProtocolError.invalidLength }
            totalSize = total; data += bytes; complete = data.count == total
        }
        var ack = GFDIWriter(); ack.u16(requestID); ack.u32(UInt32(offset)); ack.u8(0); ack.u8(duplicate ? 101 : 0)
        return (Data(ack.bytes), duplicate)
    }
    static func request(id: UInt16, data: Data) -> Data {
        var payload = GFDIWriter(); payload.u16(id); payload.u32(0)
        payload.u32(UInt32(data.count)); payload.u32(UInt32(data.count)); payload.data(data)
        return Data(payload.bytes)
    }
}

/// Connect IQ Mobile SDK command channel (APK df2/h, ef2/a,b,r,s,v).
/// Opening returns a device prompt status, not proof of the final watchface display.
enum GFDIConnectIQSDK {
    static func uuidBytes(_ id: String) throws -> Data {
        // IQApp strips hyphens; ef2/v.d parses adjacent hex pairs in displayed order.
        // This is network byte order, not Microsoft's mixed-endian GUID encoding.
        guard let parsed = UUID(uuidString: id) else { throw GFDIConnectIQError.malformed }
        var value = parsed.uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    static func command(_ command: UInt8, appID: String) throws -> Data {
        guard command == 5 || command == 6 else { throw GFDIConnectIQError.malformed }
        return Data([0, command]) + (try uuidBytes(appID))
    }
    static func applicationVersion(_ data: Data, appID: String) throws -> UInt16 {
        guard data.count == 20, data.prefix(2) == Data([0, 5]),
              Data(data[2..<18]) == (try uuidBytes(appID)) else { throw GFDIConnectIQError.malformed }
        return UInt16(data[18]) | UInt16(data[19]) << 8
    }
    static func openStatus(_ data: Data, appID: String) throws -> UInt8 {
        guard data.count == 19, data.prefix(2) == Data([0, 6]),
              Data(data[2..<18]) == (try uuidBytes(appID)) else { throw GFDIConnectIQError.malformed }
        return data[18]
    }
}
