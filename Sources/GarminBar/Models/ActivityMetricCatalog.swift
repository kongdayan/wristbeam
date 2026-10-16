import Foundation

struct ActivityMetricDefinition: Identifiable {
    let key: String
    let label: String
    let unit: String
    let group: String
    var id: String { key }
    init(_ key: String, _ label: String, _ unit: String = "", _ group: String = "运动统计") {
        self.key = key; self.label = label; self.unit = unit; self.group = group
    }
    func formatted(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if unit == "s" { return ActivityMetricCatalog.duration(value) }
        if unit == "m", abs(value) >= 1000, key == "distance" || key == "sumDistance" {
            return String(format: "%.2f km", value / 1000)
        }
        if unit == "m/s", key != "maxVerticalSpeed", key != "directVerticalSpeed" {
            return String(format: "%.1f km/h", value * 3.6)
        }
        return String(format: value.rounded() == value ? "%.0f" : "%.1f", value) + (unit.isEmpty ? "" : " " + unit)
    }
}

enum ActivityMetricCatalog {
    static let groups = ["运动统计", "心率与训练", "速度与海拔", "温度与补水", "力量与功率", "心率区间"]
    static let statistics: [ActivityMetricDefinition] = [
        .init("duration", "计时时长", "s"), .init("movingDuration", "移动时长", "s"), .init("elapsedDuration", "经过时长", "s"),
        .init("distance", "距离", "m"), .init("calories", "热量", "kcal"), .init("bmrCalories", "静息热量", "kcal"), .init("steps", "步数"),
        .init("averageHR", "平均心率", "bpm", "心率与训练"), .init("maxHR", "最高心率", "bpm", "心率与训练"), .init("minHR", "最低心率", "bpm", "心率与训练"),
        .init("aerobicTrainingEffect", "有氧训练效果", "", "心率与训练"), .init("anaerobicTrainingEffect", "无氧训练效果", "", "心率与训练"),
        .init("activityTrainingLoad", "训练负荷", "", "心率与训练"), .init("moderateIntensityMinutes", "中等强度时间", "min", "心率与训练"),
        .init("vigorousIntensityMinutes", "高强度时间", "min", "心率与训练"),
        .init("averageSpeed", "平均速度", "m/s", "速度与海拔"), .init("averageMovingSpeed", "平均移动速度", "m/s", "速度与海拔"),
        .init("maxSpeed", "最高速度", "m/s", "速度与海拔"), .init("elevationGain", "累计爬升", "m", "速度与海拔"),
        .init("elevationLoss", "累计下降", "m", "速度与海拔"), .init("avgElevation", "平均海拔", "m", "速度与海拔"),
        .init("minElevation", "最低海拔", "m", "速度与海拔"), .init("maxElevation", "最高海拔", "m", "速度与海拔"),
        .init("maxVerticalSpeed", "最大垂直速度", "m/s", "速度与海拔"), .init("minActivityLapDuration", "最快分段用时", "s", "速度与海拔"),
        .init("averageTemperature", "平均温度", "°C", "温度与补水"), .init("minTemperature", "最低温度", "°C", "温度与补水"),
        .init("maxTemperature", "最高温度", "°C", "温度与补水"), .init("waterEstimated", "估计汗液流失", "mL", "温度与补水"),
        .init("totalReps", "重复次数", "", "力量与功率"), .init("totalSets", "总组数", "", "力量与功率"), .init("activeSets", "活动组数", "", "力量与功率"),
        .init("averagePower", "平均功率", "W", "力量与功率"), .init("maxPower", "最大功率", "W", "力量与功率"), .init("normalizedPower", "标准化功率", "W", "力量与功率")
    ] + (1...5).map { ActivityMetricDefinition("hrTimeInZone_\($0)", "Z\($0)", "s", "心率区间") }
    // Values are already in the descriptor's units. Its factor is metadata,
    // not a divisor: verified speed/elevation/distance against exported TCX.
    static let charts: [ActivityMetricDefinition] = [
        .init("directHeartRate", "心率", "bpm"), .init("directSpeed", "速度", "m/s"), .init("directPower", "功率", "W"),
        .init("directCadence", "步频", "rpm"), .init("directDoubleCadence", "步频", "spm"),
        .init("directFractionalCadence", "小数步频", "spm"), .init("directElevation", "海拔", "m"),
        .init("directAirTemperature", "温度", "°C"), .init("directVerticalSpeed", "垂直速度", "m/s"),
        .init("directCaloriesBurnRate", "热量消耗速率", "kcal/min"), .init("sumDistance", "累计距离", "m"),
        .init("sumDuration", "计时时长", "s"), .init("sumElapsedDuration", "经过时长", "s"), .init("sumMovingDuration", "移动时长", "s")
    ]
    static func duration(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 1_000_000_000 else { return "—" }
        let seconds = Int(value.rounded())
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct ActivityChartPoint: Identifiable {
    let id: Int
    let time: Date
    let value: Double
    let segment: Int
    static func points(_ detail: GarminActivityDetail, metric: String) -> [ActivityChartPoint] {
        guard let values = detail.series.first(where: { $0.key == metric })?.values,
              let times = detail.series.first(where: { $0.key == "directTimestamp" })?.values else { return [] }
        var segment = 0
        var previousTime: Double?
        return values.enumerated().compactMap { index, value in
            guard let value, value.isFinite, times.indices.contains(index), let time = times[index], time.isFinite,
                  time > 0, time < 253_402_300_800_000 else { segment += 1; return nil }
            if let previousTime, time <= previousTime { segment += 1 }
            previousTime = time
            return .init(id: index, time: Date(timeIntervalSince1970: time / 1000), value: value, segment: segment)
        }
    }
}
