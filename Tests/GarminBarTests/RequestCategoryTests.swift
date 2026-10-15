import Foundation
import XCTest
@testable import GarminBar

final class RequestCategoryTests: XCTestCase {
    func testLegacyLogKeepsUnclassifiedHistoryWithoutInventingRequests() throws {
        let old = Data(#"{"schemaVersion":1,"events":[],"totalEvents":0,"omittedRoutineMessages":24}"#.utf8)
        var log = try JSONDecoder().decode(GFDIRequestLog.self, from: old)
        XCTAssertEqual(log.historicalRoutineMessages, 24)
        XCTAssertTrue(log.routineCategories.isEmpty)
        log.append(GFDIMessage(number: 5023, payload: Data([80])), direction: .watchToMac)
        XCTAssertEqual(log.omittedRoutineMessages, 25)
        XCTAssertEqual(log.historicalRoutineMessages, 24)
        XCTAssertEqual(log.routineCategories.first?.number, 5023)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(GFDIRequestLog.self, from: log.encoded())
        XCTAssertEqual(restored.schemaVersion, 2)
        XCTAssertEqual(restored.historicalRoutineMessages, 24)
        XCTAssertEqual(restored.routineCategories.first?.count, 1)
    }

    func testRoutineTotalsSeparateDirectionAndAcknowledgementTarget() throws {
        var log = GFDIRequestLog()
        let time = Date(timeIntervalSince1970: 100)
        let block = GFDIMessage(number: 5004, payload: Data(repeating: 11, count: 30))
        for offset in 0..<24 {
            log.append(block, direction: .watchToMac, at: time.addingTimeInterval(Double(offset)))
        }
        log.append(block, direction: .macQueued, at: time)
        log.append(block.response(), direction: .macQueued, at: time)
        log.append(GFDIMessage(number: 5024).response(), direction: .macQueued, at: time)
        log.append(GFDIMessage(number: 5014).response(), direction: .macQueued, at: time)
        XCTAssertEqual(log.omittedRoutineMessages, 27)
        XCTAssertEqual(log.routineCategories.count, 4)
        XCTAssertEqual(log.routineCategories.reduce(0) { $0 + $1.count }, 27)
        XCTAssertEqual(log.routineCategories[0].count, 24)
        XCTAssertEqual(log.routineCategories[0].lastSeen, time.addingTimeInterval(23))
        XCTAssertEqual(log.routineCategories[1].direction, .macQueued)
        XCTAssertNil(log.routineCategories[1].replyTo)
        XCTAssertEqual(log.routineCategories[2].number, 5000)
        XCTAssertEqual(log.routineCategories[2].replyTo, 5004)
        XCTAssertEqual(log.routineCategories[3].replyTo, 5024)
        XCTAssertEqual(log.totalEvents, 1) // Non-routine weather ACK stays in the detailed log.
        XCTAssertEqual(log.events.first?.replyTo, 5014)
        XCTAssertEqual(log.historicalRoutineMessages, 0)
    }

    func testUnknownAcknowledgementsCannotGrowCategoryKeysOrRevealPayloads() throws {
        var log = GFDIRequestLog()
        let privateData = Data("private-identity-health-account-location".utf8)
        let routine: [UInt16] = [5000, 5001, 5002, 5003, 5004, 5005, 5006, 5007, 5008, 5009,
                                 5022, 5023, 5024, 5027, 5044, 5045, 5054]
        for direction in [GFDIRequestLog.Direction.watchToMac, .macQueued] {
            for number in routine {
                // A truncated ACK has no trustworthy target; all other payloads are opaque.
                let message = GFDIMessage(number: number, payload: number == 5000 ? Data() : privateData)
                log.append(message, direction: direction)
                log.append(message.response(payload: privateData), direction: direction)
            }
            for number in UInt16(5200)..<UInt16(7200) {
                log.append(GFDIMessage(number: number, payload: privateData).response(payload: privateData), direction: direction)
            }
        }
        XCTAssertTrue(log.routineCategories.count <= GFDIRequestLog.categoryLimit)
        XCTAssertEqual(log.events.count, GFDIRequestLog.limit)
        XCTAssertEqual(log.unclassifiedRoutineMessages, 0)
        XCTAssertEqual(log.routineCategories.reduce(0) { $0 + $1.count }, log.omittedRoutineMessages)
        let data = try log.encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(String(decoding: privateData, as: UTF8.self)))
        XCTAssertFalse(text.contains(privateData.base64EncodedString()))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let categories = try XCTUnwrap(json["routineCategories"] as? [[String: Any]])
        let allowed = Set(["direction", "number", "replyTo", "count", "lastSeen"])
        XCTAssertTrue(categories.allSatisfy { Set($0.keys).isSubset(of: allowed) })
    }

    func testInvalidCategoryBoundsOrTotalsAreRejectedOnRestore() throws {
        var log = GFDIRequestLog()
        log.append(GFDIMessage(number: 5004), direction: .watchToMac)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: log.encoded()) as? [String: Any])
        let category = try XCTUnwrap((original["routineCategories"] as? [[String: Any]])?.first)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var oversized = original
        oversized["routineCategories"] = Array(repeating: category, count: GFDIRequestLog.categoryLimit + 1)
        oversized["omittedRoutineMessages"] = GFDIRequestLog.categoryLimit + 1
        XCTAssertThrowsError(try decoder.decode(GFDIRequestLog.self, from: JSONSerialization.data(withJSONObject: oversized)))
        var duplicate = original
        duplicate["routineCategories"] = [category, category]
        duplicate["omittedRoutineMessages"] = 2
        XCTAssertThrowsError(try decoder.decode(GFDIRequestLog.self, from: JSONSerialization.data(withJSONObject: duplicate)))
        var impossibleTotal = original
        impossibleTotal["omittedRoutineMessages"] = 0
        XCTAssertThrowsError(try decoder.decode(GFDIRequestLog.self, from: JSONSerialization.data(withJSONObject: impossibleTotal)))
    }
}
