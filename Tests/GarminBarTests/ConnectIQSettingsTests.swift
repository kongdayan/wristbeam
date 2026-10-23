import Foundation
import XCTest
@testable import GarminBar

final class ConnectIQSettingsTests: XCTestCase {
    func testMalformedPropertiesReportStructureWithoutValues() throws {
        let privateValue = "synthetic-secret-do-not-log"
        let bytes = try GFDIMonkeyCodec.encode(.dictionary(["private-key": .string(privateValue)]))
        XCTAssertThrowsError(try GFDIMonkeyCodec.decode(bytes + Data([0]))) { error in
            guard let diagnostic = error as? GFDISettingsParseError else { return XCTFail("Missing structural diagnostic") }
            XCTAssertTrue(diagnostic.stage.hasPrefix("object-size-"))
            XCTAssertFalse(diagnostic.diagnostic.contains(privateValue))
            XCTAssertFalse(diagnostic.diagnostic.contains("private-key"))
            XCTAssertEqual(diagnostic.localizedDescription, GFDIConnectIQSettingsError.malformed.localizedDescription)
        }
    }
    func testBreadthFirstMonkeyValuesRoundTripWithoutLosingTypes() throws {
        let value: GFDIMonkeyValue = .dictionary([
            "text": .string("中文 ✓"), "bool": .bool(true), "null": .null,
            "integer": .int32(-123), "long": .int64(8_000_000_000),
            "float": .float(1.5), "double": .double(1.0000000001),
            "character": .character(20013), "bytes": .bytes(Data([0, 128, 255])),
            "nested": .array([.dictionary(["child": .array([.int32(3), .string("中文 ✓")])]), .bool(false)])
        ])
        let bytes = try GFDIMonkeyCodec.encode(value)
        XCTAssertEqual(try GFDIMonkeyCodec.decode(bytes), value)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: value.jsonData()) as? [String: Any])
        XCTAssertEqual(try GFDIMonkeyCodec.decode(Data()), .dictionary([:]))
        XCTAssertEqual(try GFDIMonkeyCodec.decode(Data([0xda,0x7a,0xda,0x7a,0,0,0,0])), .dictionary([:]))
    }
    func testMonkeyBoundsUnknownTagsAndBadStringReferencesFailClosed() throws {
        let bytes = try GFDIMonkeyCodec.encode(.dictionary(["a": .int32(3)]))
        XCTAssertThrowsError(try GFDIMonkeyCodec.decode(bytes.dropLast()))
        XCTAssertThrowsError(try GFDIMonkeyCodec.decode(bytes + Data([0])))
        XCTAssertThrowsError(try GFDIMonkeyCodec.decode(Data([0xda,0x7a,0xda,0x7a,0,0,0,1,0xff])))
        XCTAssertThrowsError(try GFDIMonkeyCodec.decode(Data([0xda,0x7a,0xda,0x7a,0,0,0,5,3,0,0,0,0])))
        XCTAssertThrowsError(try GFDIMonkeyCodec.encode(.dictionary(["bad": .double(.nan)])))
        var nested: GFDIMonkeyValue = .array([])
        for _ in 0..<34 { nested = .array([nested]) }
        XCTAssertThrowsError(try GFDIMonkeyCodec.encode(nested))
    }
    func testSettingsServiceUsesStoreUUIDAndCorrelatedSuccess() throws {
        let id = "00112233-4455-6677-8899-aabbccddeeff"
        let uuid = try GFDIConnectIQSDK.uuidBytes(id)
        let p = GFDIConnectIQ.Proto.self
        XCTAssertEqual(try GFDIConnectIQSettings.request(appID: id), Data([0x22,20,0x0a,18,0x0a,16]) + uuid)
        let response = p.bytes(4, p.bytes(4, p.bytes(1, uuid) + p.integer(2, 1)))
        XCTAssertNoThrow(try GFDIConnectIQSettings.checkResponse(response, appID: id, saving: true))
        XCTAssertThrowsError(try GFDIConnectIQSettings.checkResponse(response, appID: "11112233-4455-6677-8899-aabbccddeeff", saving: true))
        XCTAssertThrowsError(try GFDIConnectIQSettings.checkResponse(p.bytes(4, p.bytes(4, p.bytes(1, uuid))), appID: id, saving: true))
        let binary = try GFDIMonkeyCodec.encode(.dictionary(["key": .int32(7)]))
        let push = p.bytes(4, p.bytes(5, p.bytes(1, uuid) + p.bytes(2, binary)))
        XCTAssertEqual(try GFDIConnectIQSettings.push(push)?.appID, id)
        XCTAssertEqual(try GFDIConnectIQSettings.push(push)?.data, binary)
        XCTAssertEqual(GFDIConnectIQSettings.pushResponse, Data([0x22,4,0x32,2,8,1]))
    }
}
