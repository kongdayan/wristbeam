import Foundation

/// Independently encoded from the APK GDIDeviceStatus / GDIDeviceStatusExtension
/// descriptors and e82/a (legacy BatteryStatusDataHandler). No account data is involved.
enum GFDIBattery {
    struct Reading: Equatable {
        let percent: Int
        let charging: Bool?
        let estimatedHoursRemaining: UInt32?
    }

    // Smart.device_status_service = 8; DeviceStatusService.request = 2 (empty).
    static let query = Data([0x42, 0x02, 0x12, 0x00])

    static func response(_ smart: Data) throws -> Reading? {
        guard let service = try bytes(smart, field: 8), let response = try bytes(service, field: 3) else { return nil }
        let fields = try integers(response)
        // Missing/default proto2 values are not measurements. ResponseStatus.OK = 1.
        guard fields[1] == 1, let percent = fields[2], percent <= 100 else { return nil }
        let charging: Bool?
        switch fields[3] {
        case 4: charging = true
        case 1, 2, 3, 5, 7: charging = false
        default: charging = nil
        }
        let hours = fields[4].flatMap { UInt32(exactly: $0) }
        return Reading(percent: Int(percent), charging: charging, estimatedHoursRemaining: hours)
    }

    static func isChangeNotification(_ smart: Data) throws -> Bool {
        guard let service = try bytes(smart, field: 8) else { return false }
        return try bytes(service, field: 1) != nil
    }

    static func legacy(_ payload: Data) throws -> Reading? {
        // APK e82/a checks >= 6 bytes and reads unsigned byte 2 as capacity.
        guard payload.count >= 6 else { throw GFDIProtocolError.truncated }
        let percent = Int(payload[payload.startIndex + 2])
        guard percent <= 100 else { return nil }
        // The high nibble of byte 0 is a battery-condition enum, not a charging bit.
        return Reading(percent: percent, charging: nil, estimatedHoursRemaining: nil)
    }

    private enum Value { case bytes(Data), integer(UInt64) }

    private static func fields(_ data: Data) throws -> [(UInt64, Value)] {
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
        var result: [(UInt64, Value)] = []
        while reader.remaining > 0 {
            let tag = try varint()
            guard tag >> 3 > 0 else { throw GFDIProtocolError.invalidLength }
            switch tag & 7 {
            case 0: result.append((tag >> 3, .integer(try varint())))
            case 1: _ = try reader.data(8)
            case 2:
                let size = try varint()
                guard size <= UInt64(reader.remaining) else { throw GFDIProtocolError.truncated }
                result.append((tag >> 3, .bytes(try reader.data(Int(size)))))
            case 5: _ = try reader.data(4)
            default: throw GFDIProtocolError.invalidLength
            }
        }
        return result
    }

    private static func bytes(_ data: Data, field: UInt64) throws -> Data? {
        var result: Data?
        for (number, value) in try fields(data) where number == field {
            if case let .bytes(bytes) = value { result = bytes }
        }
        return result
    }

    private static func integers(_ data: Data) throws -> [UInt64: UInt64] {
        var result: [UInt64: UInt64] = [:]
        for (number, value) in try fields(data) {
            if case let .integer(integer) = value { result[number] = integer }
        }
        return result
    }
}

/// APK jr2/d: request ID u16, offset/total/length u32, then protobuf bytes.
/// Battery messages are small; a strict 4 KiB bound prevents unrelated allocations.
struct GFDIBatteryTransfer {
    let requestID: UInt16
    private(set) var data = Data()
    private var expectedSize: Int?
    private(set) var complete = false

    init(requestID: UInt16) { self.requestID = requestID }

    mutating func accept(_ payload: Data) throws -> (ack: Data, duplicate: Bool) {
        var reader = GFDIReader(payload)
        guard try reader.u16() == requestID else { throw GFDIProtocolError.invalidLength }
        let offset = Int(try reader.u32())
        let total = Int(try reader.u32())
        let size = Int(try reader.u32())
        guard total > 0, total <= 4096 else { throw GFDIProtocolError.oversized }
        guard size > 0, size == reader.remaining, offset <= total, size <= total - offset,
              expectedSize == nil || expectedSize == total else { throw GFDIProtocolError.invalidLength }
        let fragment = try reader.data(size)
        let duplicate = offset < data.count
        if duplicate {
            guard size <= data.count - offset, data.subdata(in: offset..<(offset + size)) == fragment else { throw GFDIProtocolError.invalidCRC }
        } else {
            guard offset == data.count else { throw GFDIProtocolError.invalidLength }
            expectedSize = total
            data += fragment
            complete = data.count == total
        }
        var ack = GFDIWriter()
        ack.u16(requestID); ack.u32(UInt32(offset)); ack.u8(0); ack.u8(duplicate ? 101 : 0)
        return (Data(ack.bytes), duplicate)
    }

    static func request(id: UInt16) -> Data {
        var writer = GFDIWriter()
        writer.u16(id); writer.u32(0)
        writer.u32(UInt32(GFDIBattery.query.count)); writer.u32(UInt32(GFDIBattery.query.count))
        writer.data(GFDIBattery.query)
        return Data(writer.bytes)
    }
}
