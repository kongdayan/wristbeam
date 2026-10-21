import Foundation

/// Identifies the program entry point inside a verified official watchface package.
/// Supported envelope: BE32 tag 0x1d, BE32 length 20, BE32 package version, store UUID.
/// PRG section/entry layout: pzl/ciqdb sections.go and entries.go (original parser).
/// The distinct runtime UUID was confirmed by SDK command 5 against the installed version.
/// This does not verify authenticity: callers must first verify the downloaded package SHA256.
struct GFDIConnectIQPackageIdentity: Equatable {
    let storeAppID: String
    let runtimeAppID: String
    let packageVersion: UInt32

    static func parse(_ data: Data, expectedStoreAppID: String) throws -> Self {
        guard let expected = UUID(uuidString: expectedStoreAppID),
              data.count >= 28 + 8, data.count <= 32 * 1024 * 1024 else {
            throw IdentityError.invalidPackage
        }
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        func uuid(_ offset: Int) throws -> String {
            let value = Array(bytes[offset..<offset + 16])
            guard value.contains(where: { $0 != 0 }), value.contains(where: { $0 != 255 }) else {
                throw IdentityError.invalidPackage
            }
            return UUID(uuid: (value[0],value[1],value[2],value[3],value[4],value[5],value[6],value[7],
                               value[8],value[9],value[10],value[11],value[12],value[13],value[14],value[15])).uuidString.lowercased()
        }
        guard u32(0) == 0x1d, u32(4) == 20 else { throw IdentityError.unsupportedPackage }
        let storeID = try uuid(12)
        guard storeID == expected.uuidString.lowercased() else { throw IdentityError.storeMismatch }
        var offset = 28, sectionCount = 0
        var runtimeID: String?
        while offset < bytes.count {
            guard bytes.count - offset >= 8, sectionCount < 256 else { throw IdentityError.invalidPackage }
            let tag = u32(offset), length = Int(u32(offset + 4)), start = offset + 8
            guard length <= bytes.count - start else { throw IdentityError.invalidPackage }
            if sectionCount == 0, tag != 0xd000d000 { throw IdentityError.unsupportedPackage }
            if tag == 0x6060c0de {
                // A single 36-byte watchface entry, preceded by the BE16 count.
                // Multiple/background entry formats need separate evidence before support.
                guard runtimeID == nil, length == 38,
                      bytes[start] == 0, bytes[start + 1] == 1,
                      u32(start + 34) == 0 else { throw IdentityError.unsupportedPackage }
                runtimeID = try uuid(start + 2)
            }
            offset = start + length; sectionCount += 1
        }
        guard offset == bytes.count, let runtimeID else { throw IdentityError.invalidPackage }
        return Self(storeAppID: storeID, runtimeAppID: runtimeID, packageVersion: u32(8))
    }

    enum IdentityError: LocalizedError {
        case invalidPackage, unsupportedPackage, storeMismatch
        var errorDescription: String? {
            switch self {
            case .invalidPackage: return "表盘包结构无效，请重新下载"
            case .unsupportedPackage: return "此表盘包暂不支持从 Mac 打开"
            case .storeMismatch: return "本地表盘包与所选表盘不一致，请重新下载"
            }
        }
    }
}
