import Foundation

/// A deliberately small protobuf wire reader for the identity query only.
/// Field definitions come from the APK's generated GDICore/GDICoreExtension descriptors:
/// Smart.core_service = 13; CoreService.feature_capabilities_request = 8;
/// response = 9; request.garmin_guid = 1; response.guid_status = 1.
/// The GUID overwrite request (CoreService field 10) is never constructed.
enum GFDICoreIdentity {
    static func guidBytes(_ string: String) -> Data? {
        let text = string.replacingOccurrences(of: "-", with: "")
        guard text.count == 32, text.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { return nil }
        guard string.count == 32 || (string.count == 36 && UUID(uuidString: string) != nil) else { return nil }
        // The protobuf field is `bytes`, but its value is the UTF-8 customer GUID text,
        // not a decoded 128-bit UUID. APK cj0/f.b() calls customerGUID.getBytes(UTF_8),
        // and xq2/u passes those bytes unchanged to the Core service.
        return Data(string.utf8)
    }

    static func query(guid: Data) -> Data {
        let request = bytesField(1, guid) + integerField(2, 1) + bytesField(3, Data("GarminBar".utf8))
        return bytesField(13, bytesField(8, request))
    }

    static func guidStatus(_ smart: Data) throws -> UInt64? {
        guard let core = try byteFields(smart)[13], let response = try byteFields(core)[9] else { return nil }
        return try integerFields(response)[1]
    }

    static func bytesField(_ number: UInt64, _ value: Data) -> Data { var result = varint(number << 3 | 2); result += varint(UInt64(value.count)); result += value; return result }
    static func integerField(_ number: UInt64, _ value: UInt64) -> Data { var result = varint(number << 3); result += varint(value); return result }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes: [UInt8] = []
        while value >= 128 { bytes.append(UInt8(value & 127) | 128); value >>= 7 }
        bytes.append(UInt8(value))
        return Data(bytes)
    }

    private enum Value { case bytes(Data), integer(UInt64) }

    private static func fields(_ data: Data) throws -> [(UInt64, Value)] {
        var reader = GFDIReader(data)
        func readVarint(_ reader: inout GFDIReader) throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                let byte = try reader.u8()
                guard index < 9 || byte < 2 else { throw GFDIProtocolError.invalidLength }
                value |= UInt64(byte & 127) << (index * 7)
                if byte & 128 == 0 { return value }
            }
            throw GFDIProtocolError.invalidLength
        }
        var result: [(UInt64, Value)] = []
        while reader.remaining > 0 {
            let tag = try readVarint(&reader)
            guard tag >> 3 > 0 else { throw GFDIProtocolError.invalidLength }
            switch tag & 7 {
            case 0: result.append((tag >> 3, .integer(try readVarint(&reader))))
            case 1: _ = try reader.data(8)
            case 2:
                let size = try readVarint(&reader)
                guard size <= UInt64(reader.remaining) else { throw GFDIProtocolError.truncated }
                result.append((tag >> 3, .bytes(try reader.data(Int(size)))))
            case 5: _ = try reader.data(4)
            default: throw GFDIProtocolError.invalidLength
            }
        }
        return result
    }

    private static func byteFields(_ data: Data) throws -> [UInt64: Data] {
        var result: [UInt64: Data] = [:]
        for (key, value) in try fields(data) { if case let .bytes(bytes) = value { result[key] = bytes } }
        return result
    }

    private static func integerFields(_ data: Data) throws -> [UInt64: UInt64] {
        var result: [UInt64: UInt64] = [:]
        for (key, value) in try fields(data) { if case let .integer(integer) = value { result[key] = integer } }
        return result
    }
}
