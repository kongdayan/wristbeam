import Foundation

struct NearbyWatch: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
    var offersHeartRate: Bool
    var offersGarmin: Bool
    var serviceSummary: String { offersGarmin ? "Garmin 蓝牙服务" : offersHeartRate ? "仅心率广播，未用于同步" : "其他蓝牙设备" }
    var shortID: String { String(id.uuidString.suffix(8)) }
}

struct WatchDiscoveryStore {
    private var records: [UUID: NearbyWatch] = [:]
    let capacity: Int
    let lifetime: TimeInterval
    init(capacity: Int = 40, lifetime: TimeInterval = 20) { self.capacity = max(1, capacity); self.lifetime = max(1, lifetime) }
    func contains(_ id: UUID) -> Bool { records[id] != nil }
    func knowsGarmin(_ id: UUID) -> Bool { records[id]?.offersGarmin == true }
    mutating func reset() { records.removeAll() }
    mutating func insert(_ incoming: NearbyWatch, now: Date) {
        var watch = incoming
        if let previous = records[watch.id] {
            if watch.name == "未命名设备" { watch.name = previous.name }
            watch.offersGarmin = watch.offersGarmin || previous.offersGarmin
            watch.offersHeartRate = watch.offersHeartRate || previous.offersHeartRate
        }
        records[watch.id] = watch
        _ = visible(now: now)
    }
    mutating func visible(now: Date) -> [NearbyWatch] {
        records = records.filter { now.timeIntervalSince($0.value.lastSeen) <= lifetime }
        let sorted = records.values.sorted {
            if $0.offersGarmin != $1.offersGarmin { return $0.offersGarmin }
            if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
            return $0.id.uuidString < $1.id.uuidString
        }
        let result = Array(sorted.prefix(capacity))
        records = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        return result
    }
}
