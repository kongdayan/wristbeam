import Foundation

struct GarminFITFileMetadata {
    let subtype: UInt8
    let serialNumber: UInt32?
    var dataType: GarminDataType { GarminDataType(fitSubtype: subtype) }
}

enum GarminFITFileClassifier {
    private struct Field { let number: UInt8; let size: Int }
    private struct Definition { let global: UInt16; let bigEndian: Bool; let fields: [Field]; let developerSize: Int }

    /// Inspect the FIT binary's file_id message, including the file CRC and architecture byte.
    /// File names and extensions do not determine the upload endpoint.
    static func inspect(_ data: Data) throws -> GarminFITFileMetadata {
        let bytes = [UInt8](data)
        guard bytes.count >= 14, bytes.count <= 64 * 1024 * 1024,
              bytes[8..<12].elementsEqual([0x2e, 0x46, 0x49, 0x54]) else {
            throw GarminCloudError.invalidFIT("这不是完整的 FIT 文件")
        }
        let header = Int(bytes[0])
        guard header == 12 || header == 14 else { throw GarminCloudError.invalidFIT("不支持的 FIT 文件头") }
        let length = Int(uint32(bytes, at: 4, bigEndian: false))
        let end = header + length
        guard end + 2 == bytes.count else { throw GarminCloudError.invalidFIT("FIT 文件尚未写入完整，等待下一次扫描") }
        let expected = uint16(bytes, at: end, bigEndian: false)
        guard crc16(Array(bytes[..<end])) == expected else { throw GarminCloudError.invalidFIT("FIT 文件 CRC 校验失败，原文件已保留") }
        if header == 14 {
            guard crc16(Array(bytes[..<12])) == uint16(bytes, at: 12, bigEndian: false) else {
                throw GarminCloudError.invalidFIT("FIT 文件头 CRC 校验失败")
            }
        }
        var definitions: [Int: Definition] = [:]
        var index = header
        while index < end {
            let record = bytes[index]; index += 1
            let compressed = (record & 0x80) != 0
            let local = compressed ? Int((record >> 5) & 0x03) : Int(record & 0x0f)
            if !compressed && record & 0x40 != 0 {
                guard index + 5 <= end else { throw GarminCloudError.invalidFIT("FIT 定义记录被截断") }
                let architecture = bytes[index + 1]
                guard architecture == 0 || architecture == 1 else { throw GarminCloudError.invalidFIT("FIT architecture 无效") }
                let big = architecture == 1
                let global = uint16(bytes, at: index + 2, bigEndian: big)
                let count = Int(bytes[index + 4]); index += 5
                guard index + count * 3 <= end else { throw GarminCloudError.invalidFIT("FIT 字段定义被截断") }
                var fields: [Field] = []
                for _ in 0..<count {
                    fields.append(Field(number: bytes[index], size: Int(bytes[index + 1])))
                    index += 3
                }
                var developerSize = 0
                if record & 0x20 != 0 {
                    guard index < end else { throw GarminCloudError.invalidFIT("FIT developer 字段被截断") }
                    let developerCount = Int(bytes[index]); index += 1
                    guard index + developerCount * 3 <= end else { throw GarminCloudError.invalidFIT("FIT developer 定义被截断") }
                    for _ in 0..<developerCount { developerSize += Int(bytes[index + 1]); index += 3 }
                }
                definitions[local] = Definition(global: global, bigEndian: big, fields: fields, developerSize: developerSize)
            } else {
                guard let definition = definitions[local] else { throw GarminCloudError.invalidFIT("FIT 数据没有对应的本地定义") }
                let size = definition.fields.reduce(definition.developerSize) { $0 + $1.size }
                guard index + size <= end else { throw GarminCloudError.invalidFIT("FIT 数据记录被截断") }
                if definition.global == 0 {
                    var offset = index
                    var subtype: UInt8?
                    var serial: UInt32?
                    for field in definition.fields {
                        if field.number == 0, field.size >= 1, bytes[offset] != 0xff { subtype = bytes[offset] }
                        if field.number == 3, field.size == 4 {
                            let value = uint32(bytes, at: offset, bigEndian: definition.bigEndian)
                            if value != 0 && value != UInt32.max { serial = value }
                        }
                        offset += field.size
                    }
                    if let subtype { return GarminFITFileMetadata(subtype: subtype, serialNumber: serial) }
                }
                index += size
            }
        }
        throw GarminCloudError.invalidFIT("FIT 中没有可用的 file_id.type，无法安全选择云端上传类别")
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xa001 : crc >> 1 }
        }
        return crc
    }

    private static func uint16(_ bytes: [UInt8], at index: Int, bigEndian: Bool) -> UInt16 {
        bigEndian ? UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]) : UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }
    private static func uint32(_ bytes: [UInt8], at index: Int, bigEndian: Bool) -> UInt32 {
        let values = bigEndian ? Array(bytes[index..<index + 4].reversed()) : Array(bytes[index..<index + 4])
        return UInt32(values[0]) | UInt32(values[1]) << 8 | UInt32(values[2]) << 16 | UInt32(values[3]) << 24
    }
}
