import Foundation

enum MetricGroup: String, CaseIterable { case live = "手表实时指标", daily = "今日同步汇总", solar = "太阳能记录" }

struct MetricDefinition {
    let id: String
    let title: String
    let unit: String
    let symbol: String
    let group: MetricGroup
    var short = ""
    var decimals = 0
    var service: UInt16?
    var characteristic: UInt16?
    var dailyKey: String?
    var scale: Double = 1
    var freshness: TimeInterval = 1800
}

/// A catalog rather than fixed switches lets every discovered phone metric be selected
/// independently. Stable raw IDs preserve preferences and the original telemetry format.
struct MetricKind: RawRepresentable, Codable, Hashable, CaseIterable, Identifiable {
    let rawValue: String
    init?(rawValue: String) { guard Self.definitions.contains(where: { $0.id == rawValue }) else { return nil }; self.rawValue = rawValue }
    var id: String { rawValue }
    var definition: MetricDefinition { Self.definitions.first { $0.id == rawValue }! }
    var title: String { L10n.text(definition.title) }
    var unit: String { L10n.text(definition.unit) }
    var symbol: String { definition.symbol }
    var group: MetricGroup { definition.group }
    var isDeviceStatus: Bool { self == .watchBattery }
    var short: String { definition.short.isEmpty ? title : L10n.text(definition.short) }
    static var allCases: [Self] { definitions.map { Self(rawValue: $0.id)! } }
    static let heartRate = Self(rawValue: "heartRate")!
    static let stress = Self(rawValue: "stress")!
    static let steps = Self(rawValue: "steps")!
    static let bodyBattery = Self(rawValue: "bodyBattery")!
    static let watchBattery = Self(rawValue: "watchBattery")!
    static let solarIntensity = Self(rawValue: "solarIntensity")!
    static let sunlightMinutes = Self(rawValue: "sunlightMinutes")!
    static let solarChargingMinutes = Self(rawValue: "solarChargingMinutes")!
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer(); let id = try container.decode(String.self)
        guard let value = Self(rawValue: id) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown metric") }
        self = value
    }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    static let definitions: [MetricDefinition] = {
        var values: [MetricDefinition] = [
            .init(id: "heartRate", title: "心率", unit: "BPM", symbol: "heart.fill", group: .live, short: "♥", service: 6, characteristic: 0x2501, freshness: 45),
            .init(id: "bodyBattery", title: "身体电量", unit: "/ 100", symbol: "battery.75percent", group: .live, short: "身体电量", service: 20, characteristic: 0x250D, dailyKey: "bodyBatteryMostRecentValue", freshness: 900),
            .init(id: "stress", title: "身体压力", unit: "/ 100", symbol: "speedometer", group: .live, short: "压", service: 13, characteristic: 0x2508, freshness: 60),
            .init(id: "steps", title: "今日步数", unit: "步", symbol: "shoeprints.fill", group: .live, short: "步", service: 7, characteristic: 0x2502, dailyKey: "totalSteps", freshness: 1800),
            .init(id: "calories", title: "今日总热量", unit: "千卡", symbol: "flame.fill", group: .live, short: "热量", service: 8, characteristic: 0x2503, dailyKey: "totalKilocalories"),
            .init(id: "floors", title: "上楼层数", unit: "层", symbol: "stairs", group: .live, short: "楼层", service: 9, characteristic: 0x2504, dailyKey: "floorsAscended"),
            .init(id: "intensityMinutes", title: "今日强度分钟", unit: "分", symbol: "figure.run", group: .live, short: "强度", service: 10, characteristic: 0x2505),
            .init(id: "respiration", title: "呼吸频率", unit: "次/分", symbol: "lungs.fill", group: .live, short: "呼吸", decimals: 1, service: 21, characteristic: 0x250F, dailyKey: "latestRespirationValue", freshness: 120),
            .init(id: "spo2", title: "血氧", unit: "%", symbol: "drop.fill", group: .live, short: "血氧", service: 19, characteristic: 0x250C, dailyKey: "latestSpo2", freshness: 1800),
            .init(id: "hrv", title: "心搏间期（RR）", unit: "毫秒", symbol: "heart.text.square", group: .live, short: "RR", service: 12, characteristic: 0x2507, freshness: 120),
            .init(id: "activeTime", title: "活动时长", unit: "分", symbol: "timer", group: .live, short: "活动", service: 26, characteristic: 0x2510, dailyKey: "activeSeconds", scale: 1 / 60),
            .init(id: "trainingReadiness", title: "训练准备度", unit: "/ 100", symbol: "figure.strengthtraining.traditional", group: .live, short: "准备度", service: 25, characteristic: 0x2511, freshness: 3600),
            .init(id: "pushes", title: "推行次数", unit: "次", symbol: "figure.roll", group: .live, short: "推行", service: 29, characteristic: 0x250E),
            .init(id: "watchBattery", title: "手表电池", unit: "%", symbol: "applewatch", group: .live, short: "表电", freshness: 3600)
        ]
        values += [
            .init(id: "hrv.lastNight", title: "夜间 HRV", unit: "毫秒", symbol: "waveform.path.ecg", group: .daily),
            .init(id: "hrv.weeklyAverage", title: "HRV 七天平均", unit: "毫秒", symbol: "waveform.path.ecg", group: .daily),
            .init(id: "hrv.status", title: "HRV 状态", unit: "", symbol: "heart.text.square", group: .daily),
            .init(id: "hrv.lastNightHigh", title: "HRV 最高五分钟", unit: "毫秒", symbol: "waveform.path.ecg", group: .daily)
        ]
        // Daily fields observed in this China account. IDs, algorithm versions and
        // profile identifiers are deliberately excluded from the health catalog.
        let fields: [(String, String, String, Double, Int)] = [
            ("restingHeartRate", "静息心率", "BPM", 1, 0), ("minHeartRate", "今日最低心率", "BPM", 1, 0), ("maxHeartRate", "今日最高心率", "BPM", 1, 0),
            ("averageStressLevel", "今日平均压力", "/ 100", 1, 0), ("maxStressLevel", "今日最高压力", "/ 100", 1, 0),
            ("bodyBatteryHighestValue", "今日最高身体电量", "/ 100", 1, 0), ("bodyBatteryLowestValue", "今日最低身体电量", "/ 100", 1, 0),
            ("bodyBatteryChargedValue", "今日身体电量恢复", "点", 1, 0), ("bodyBatteryDrainedValue", "今日身体电量消耗", "点", 1, 0),
            ("totalDistanceMeters", "今日距离", "公里", 0.001, 2), ("dailyStepGoal", "步数目标", "步", 1, 0),
            ("activeKilocalories", "活动热量", "千卡", 1, 0), ("bmrKilocalories", "静息热量", "千卡", 1, 0), ("netRemainingKilocalories", "剩余热量预算", "千卡", 1, 0),
            ("floorsDescended", "下楼层数", "层", 1, 0), ("userFloorsAscendedGoal", "上楼目标", "层", 1, 0),
            ("moderateIntensityMinutes", "中等强度分钟", "分", 1, 0), ("vigorousIntensityMinutes", "高强度分钟", "分", 1, 0), ("intensityMinutesGoal", "强度分钟目标", "分", 1, 0),
            ("sleepingSeconds", "今日睡眠时长", "小时", 1 / 3600, 1), ("sedentarySeconds", "静坐时长", "小时", 1 / 3600, 1), ("highlyActiveSeconds", "高强度活动时长", "分", 1 / 60, 0),
            ("averageSpo2", "平均血氧", "%", 1, 0), ("lowestSpo2", "最低血氧", "%", 1, 0),
            ("avgWakingRespirationValue", "平均清醒呼吸", "次/分", 1, 1), ("highestRespirationValue", "最高呼吸频率", "次/分", 1, 1), ("lowestRespirationValue", "最低呼吸频率", "次/分", 1, 1),
            ("restStressDuration", "压力休息时长", "分", 1 / 60, 0), ("lowStressDuration", "低压力时长", "分", 1 / 60, 0), ("mediumStressDuration", "中压力时长", "分", 1 / 60, 0), ("highStressDuration", "高压力时长", "分", 1 / 60, 0),
            ("activityStressDuration", "活动压力时长", "分", 1 / 60, 0), ("uncategorizedStressDuration", "未分类压力时长", "分", 1 / 60, 0),
            ("restStressPercentage", "压力休息占比", "%", 1, 0), ("lowStressPercentage", "低压力占比", "%", 1, 0), ("mediumStressPercentage", "中压力占比", "%", 1, 0), ("highStressPercentage", "高压力占比", "%", 1, 0),
            ("activityStressPercentage", "活动压力占比", "%", 1, 0), ("uncategorizedStressPercentage", "未分类压力占比", "%", 1, 0),
            ("lastSevenDaysAvgRestingHeartRate", "近七天静息心率", "BPM", 1, 0)
        ]
        values += fields.map { key, title, unit, scale, decimals in
            .init(id: "daily.\(key)", title: title, unit: unit, symbol: "chart.bar.fill", group: .daily, decimals: decimals, dailyKey: key, scale: scale)
        }
        values += [
            .init(id: "solarIntensity", title: "太阳能强度", unit: "%", symbol: "sun.max.fill", group: .solar, short: "光照", decimals: 2, freshness: 7200),
            .init(id: "sunlightMinutes", title: "日照时长（估算）", unit: "分", symbol: "sun.horizon.fill", group: .solar, short: "日照", freshness: 86400),
            .init(id: "solarChargingMinutes", title: "太阳能充电（估算）", unit: "分", symbol: "bolt.fill", group: .solar, short: "充电", freshness: 86400)
        ]
        return values
    }()
}

enum MetricOrigin: String, Codable { case watch, cloud, estimated }

enum MetricSelection {
    static func load(_ key: String, includeSolar: Bool) -> Set<MetricKind> {
        if let ids = AppPreferences.shared.object(forKey: key) as? [String] { return Set(ids.compactMap(MetricKind.init(rawValue:))) }
        var values: Set<MetricKind> = [.bodyBattery]
        for (kind, legacy) in [(MetricKind.heartRate, "showHeart"), (.stress, "showStress"), (.steps, "showSteps")] {
            if AppPreferences.shared.object(forKey: legacy) as? Bool ?? true { values.insert(kind) }
        }
        if includeSolar { values.formUnion([.solarIntensity, .sunlightMinutes]) }
        return values
    }
    static func save(_ values: Set<MetricKind>, key: String) { AppPreferences.shared.set(values.map(\.rawValue).sorted(), forKey: key) }
}

struct MetricSample: Codable, Identifiable {
    let id: UUID
    let kind: MetricKind
    let value: Double
    let timestamp: Date
    let source: String
    let origin: MetricOrigin
    init(kind: MetricKind, value: Double, source: String, timestamp: Date = Date(), origin: MetricOrigin = .watch) {
        id = UUID(); self.kind = kind; self.value = value; self.source = source; self.timestamp = timestamp; self.origin = origin
    }
    init(kind: MetricKind, value: Int, source: String, timestamp: Date = Date(), origin: MetricOrigin = .watch) {
        self.init(kind: kind, value: Double(value), source: source, timestamp: timestamp, origin: origin)
    }
    var formatted: String { value.formatted(.number.precision(.fractionLength(kind.definition.decimals))) }
}

enum MetricPacketError: Error, Equatable {
    case truncated, invalidValue
}

enum MetricPacketParser {
    /// APK gf2/c maps Multilink services to yk2/e,f,d,l,k,q,o,c,t,n.
    /// Decode only declared numeric readings; unavailable signed/sentinel values are rejected.
    static func realtime(service: UInt16, data: Data) throws -> (MetricKind, Double) {
        guard let kind = MetricKind.allCases.first(where: { $0.definition.service == service }) else { throw MetricPacketError.invalidValue }
        let bytes = Array(data)
        func byte(_ index: Int = 0) throws -> Int {
            guard bytes.count > index else { throw MetricPacketError.truncated }
            let value = Int(Int8(bitPattern: bytes[index])); guard value >= 0 else { throw MetricPacketError.invalidValue }; return value
        }
        func short() throws -> Int {
            guard bytes.count >= 2 else { throw MetricPacketError.truncated }
            let value = Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8))
            guard value >= 0 else { throw MetricPacketError.invalidValue }; return value
        }
        let value: Int
        switch service {
        case 6: value = try multiLinkHeartRate(data)
        case 13: value = try multiLinkStress(data)
        case 7, 8, 26, 29: value = try garminSteps(data)
        case 9: guard data.count >= 6 else { throw MetricPacketError.truncated }; value = try short()
        case 10: guard data.count >= 14 else { throw MetricPacketError.truncated }; value = try short()
        case 12: value = try short()
        case 20, 21: value = try byte()
        case 19: guard data.count >= 5 else { throw MetricPacketError.truncated }; value = try byte()
        case 25: guard data.count >= 4 else { throw MetricPacketError.truncated }; value = try byte()
        default: throw MetricPacketError.invalidValue
        }
        if [19, 20, 25].contains(service), value > 100 { throw MetricPacketError.invalidValue }
        if [12, 19, 21].contains(service), value == 0 { throw MetricPacketError.invalidValue }
        return (kind, Double(value) * kind.definition.scale)
    }

    /// Bluetooth SIG Heart Rate Measurement: flag bit 0 selects uint8/uint16.
    static func standardHeartRate(_ data: Data) throws -> Int {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw MetricPacketError.truncated }
        let value: Int
        if bytes[0] & 1 != 0 {
            guard bytes.count >= 3 else { throw MetricPacketError.truncated }
            value = Int(bytes[1]) | Int(bytes[2]) << 8
        } else { value = Int(bytes[1]) }
        guard value > 0, value < 400 else { throw MetricPacketError.invalidValue }
        return value
    }
    /// APK yk2/i.java: source + current/resting/low/high, FF means unavailable.
    static func garminHeartRate(_ data: Data) throws -> Int {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { throw MetricPacketError.truncated }
        guard bytes[1] != 255, bytes[1] > 0 else { throw MetricPacketError.invalidValue }
        return Int(bytes[1])
    }
    /// APK yk2/r.java: signed little-endian int32 steps, optional int32 goal.
    static func garminSteps(_ data: Data) throws -> Int {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw MetricPacketError.truncated }
        let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let value = Int(Int32(bitPattern: raw))
        guard value >= 0, value < 1_000_000 else { throw MetricPacketError.invalidValue }
        return value
    }
    /// APK yk2/s.java: signed little-endian int16 + status byte. Negative states
    /// represent non-measurement states; only actual 0...100 readings are shown.
    static func garminStress(_ data: Data) throws -> Int {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { throw MetricPacketError.truncated }
        let raw = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        let value = Int(Int16(bitPattern: raw))
        guard (0...100).contains(value) else { throw MetricPacketError.invalidValue }
        return value
    }
    static func multiLinkHeartRate(_ data: Data) throws -> Int {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { throw MetricPacketError.truncated }
        guard bytes[1] != 255, bytes[1] > 0 else { throw MetricPacketError.invalidValue }
        return Int(bytes[1])
    }
    static func multiLinkStress(_ data: Data) throws -> Int {
        if data.count >= 3 { return try garminStress(data) }
        guard data.count == 1, let first = data.first else { throw MetricPacketError.truncated }
        let value = Int(Int8(bitPattern: first))
        guard (0...100).contains(value) else { throw MetricPacketError.invalidValue }
        return value
    }
}
