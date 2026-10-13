import XCTest
@testable import GarminBar

final class DiscoveryTests: XCTestCase {
    func testRepeatedAdvertisementUpdatesOneDeviceAndExpiresAbsence() {
        let time = Date(), id = UUID()
        var store = WatchDiscoveryStore()
        for index in 0..<500 {
            store.insert(NearbyWatch(id: id, name: "Instinct 2 Solar", rssi: -60 + index % 5, lastSeen: time, offersHeartRate: false, offersGarmin: true), now: time)
        }
        let visible = store.visible(now: time)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.rssi, -56)
        XCTAssertEqual(store.visible(now: time.addingTimeInterval(21)).count, 0)
    }
    func testLargeScanRemainsBoundedAndPrioritizesGarminWithoutMergingDifferentDevices() {
        let time = Date(), garmin = UUID(), secondGarmin = UUID()
        var store = WatchDiscoveryStore(capacity: 40)
        for id in [garmin, secondGarmin] {
            store.insert(NearbyWatch(id: id, name: "Instinct 2 Solar", rssi: -100, lastSeen: time, offersHeartRate: false, offersGarmin: true), now: time)
        }
        for _ in 0..<1000 {
            store.insert(NearbyWatch(id: UUID(), name: "未命名设备", rssi: -20, lastSeen: time, offersHeartRate: false, offersGarmin: false), now: time)
        }
        let result = store.visible(now: time)
        XCTAssertEqual(result.count, 40)
        XCTAssertEqual(Set(result.prefix(2).map(\.id)), Set([garmin, secondGarmin]))
    }
}
