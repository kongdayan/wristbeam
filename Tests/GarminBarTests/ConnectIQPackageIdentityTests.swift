import Foundation
import XCTest
@testable import GarminBar

final class ConnectIQPackageIdentityTests: XCTestCase {
    private let storeID = "00112233-4455-6677-8899-aabbccddeeff"
    private let runtimeID = "ffeeddcc-bbaa-9988-7766-554433221100"
    private func be32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    private func section(_ tag: UInt32, _ data: Data) -> Data { be32(tag) + be32(UInt32(data.count)) + data }
    private func entry() throws -> Data {
        Data([0, 1]) + (try GFDIConnectIQSDK.uuidBytes(runtimeID)) + Data(repeating: 0, count: 20)
    }
    private func package() throws -> Data {
        be32(0x1d) + be32(20) + be32(32) + (try GFDIConnectIQSDK.uuidBytes(storeID))
            + section(0xd000d000, Data([1, 2, 3])) + section(0x6060c0de, try entry())
            + section(0xc0debabe, Data([0x01, 0x02]))
    }
    func testDistinctStoreAndRuntimeUUIDsComeFromBoundedSections() throws {
        let identity = try GFDIConnectIQPackageIdentity.parse(package(), expectedStoreAppID: storeID.uppercased())
        XCTAssertEqual(identity.storeAppID, storeID)
        XCTAssertEqual(identity.runtimeAppID, runtimeID)
        XCTAssertEqual(identity.packageVersion, 32)
        let runtimeBytes = try GFDIConnectIQSDK.uuidBytes(runtimeID)
        XCTAssertEqual(try GFDIConnectIQSDK.command(6, appID: identity.runtimeAppID), Data([0, 6]) + runtimeBytes)
    }
    func testStoreMismatchTruncationAndUnstructuredUUIDsAreRejected() throws {
        let data = try package()
        XCTAssertThrowsError(try GFDIConnectIQPackageIdentity.parse(data, expectedStoreAppID: runtimeID))
        XCTAssertThrowsError(try GFDIConnectIQPackageIdentity.parse(data.dropLast(), expectedStoreAppID: storeID))
        XCTAssertThrowsError(try GFDIConnectIQPackageIdentity.parse(data + Data([0]), expectedStoreAppID: storeID))
        XCTAssertThrowsError(try GFDIConnectIQPackageIdentity.parse(Data(repeating: 0, count: 28) + GFDIConnectIQSDK.uuidBytes(runtimeID), expectedStoreAppID: storeID))
    }
    func testDuplicateEntryMultipleEntriesAndOtherAppTypesAreRejected() throws {
        let data = try package()
        XCTAssertThrowsError(try GFDIConnectIQPackageIdentity.parse(data + section(0x6060c0de, entry()), expectedStoreAppID: storeID))
        let prefix = data.prefix(39)
        var multiple = try entry(); multiple[1] = 2
        XCTAssertThrowsError(try GFDIConnectIQPackageIdentity.parse(prefix + section(0x6060c0de, multiple), expectedStoreAppID: storeID))
        var app = try entry(); app[37] = 1
        XCTAssertThrowsError(try GFDIConnectIQPackageIdentity.parse(prefix + section(0x6060c0de, app), expectedStoreAppID: storeID))
        var invalidLength = data; invalidLength[43] = 0xff
        XCTAssertThrowsError(try GFDIConnectIQPackageIdentity.parse(invalidLength, expectedStoreAppID: storeID))
    }
}
