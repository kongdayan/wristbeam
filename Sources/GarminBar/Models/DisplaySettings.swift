import Foundation

enum PulseAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return L10n.text("跟随系统"); case .light: return L10n.text("白天"); case .dark: return L10n.text("夜间") } }
}

enum PulseCardSize: String, CaseIterable, Identifiable {
    case compact, regular, spacious
    var id: String { rawValue }
    var title: String { switch self { case .compact: return L10n.text("紧凑"); case .regular: return L10n.text("标准"); case .spacious: return L10n.text("宽松") } }
    var chartHeight: Double { switch self { case .compact: return 38; case .regular: return 60; case .spacious: return 86 } }
    var readingSize: Double { switch self { case .compact: return 28; case .regular: return 36; case .spacious: return 44 } }
    var minimumWidth: Double { switch self { case .compact: return 170; case .regular: return 220; case .spacious: return 280 } }
    var padding: Double { switch self { case .compact: return 14; case .regular: return 20; case .spacious: return 24 } }
}

enum PulsePanelSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { switch self { case .small: return L10n.text("小"); case .medium: return L10n.text("中"); case .large: return L10n.text("大") } }
    var width: Double { switch self { case .small: return 360; case .medium: return 460; case .large: return 620 } }
    var columns: Int { switch self { case .small: return 1; case .medium: return 2; case .large: return 3 } }
}

enum MetricDestination: String, CaseIterable, Identifiable {
    case dashboard, floating, menu
    var id: String { rawValue }
    var title: String { switch self { case .dashboard: return L10n.text("健康看板"); case .floating: return L10n.text("浮窗"); case .menu: return L10n.text("菜单栏") } }
}

enum MetricCategory: String, CaseIterable, Identifiable {
    case heart, body, stress, movement, sleep, respiratory, solar, energy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .heart: return L10n.text("心率与心搏间期"); case .body: return L10n.text("身体电量与恢复"); case .stress: return L10n.text("压力与休息")
        case .movement: return L10n.text("步数与活动"); case .sleep: return L10n.text("睡眠"); case .respiratory: return L10n.text("呼吸与血氧"); case .solar: return L10n.text("太阳能与光照"); case .energy: return L10n.text("热量与能量预算")
        }
    }
    var symbol: String {
        switch self {
        case .heart: return "heart.fill"; case .body: return "battery.75percent"; case .stress: return "waveform.path"
        case .movement: return "figure.walk"; case .sleep: return "bed.double.fill"; case .respiratory: return "lungs.fill"; case .solar: return "sun.max.fill"; case .energy: return "flame.fill"
        }
    }
    var metrics: [MetricKind] { MetricKind.allCases.filter { $0.category == self } }
}

extension MetricKind {
    var relatedTrend: MetricKind? {
        if isOvernightHRV { return nil }
        guard timelineKind == nil else { return timelineKind }
        switch category {
        case .heart: return .heartRate
        case .body: return .bodyBattery
        case .stress: return .stress
        case .solar: return .solarIntensity
        case .movement:
            if rawValue.lowercased().contains("floor") { return MetricKind(rawValue: "floors") }
            if rawValue.lowercased().contains("intensity") { return MetricKind(rawValue: "intensityMinutes") }
            if rawValue.lowercased().contains("seconds") { return MetricKind(rawValue: "activeTime") }
            return .steps
        case .energy: return MetricKind(rawValue: "calories")
        case .sleep, .respiratory: return nil
        }
    }
    var category: MetricCategory {
        let key = rawValue.lowercased()
        if group == .solar { return .solar }
        if key.contains("heartrate") || key == "hrv" || isOvernightHRV { return .heart }
        if key.contains("bodybattery") || key == "watchbattery" || key == "trainingreadiness" { return .body }
        if key.contains("stress") { return .stress }
        if key.contains("sleep") { return .sleep }
        if key.contains("spo2") || key.contains("respiration") { return .respiratory }
        if key.contains("calories") || key.contains("kilocalories") { return .energy }
        return .movement
    }
}

enum MetricLayout {
    /// Availability is evidence based. Missing or invalid readings alone cannot
    /// advertise a capability, and temporary disconnects do not erase choices.
    static func available(readings: Set<MetricKind>, registered: Set<MetricKind>, discovered: Set<MetricKind>) -> Set<MetricKind> {
        // A registration acknowledgement can exist for a service which never
        // yields measurements on this model (for example wheelchair pushes).
        readings
    }
    static func ordered(selection: Set<MetricKind>, order: [String]) -> [MetricKind] {
        var result: [MetricKind] = [], seen: Set<MetricKind> = []
        for raw in order {
            if let kind = MetricKind(rawValue: raw), selection.contains(kind), seen.insert(kind).inserted { result.append(kind) }
        }
        result += MetricKind.allCases.filter { selection.contains($0) && !seen.contains($0) }
        return result
    }
    static func moving(_ kind: MetricKind, before target: MetricKind, in items: [MetricKind]) -> [String] {
        guard kind != target, items.contains(kind), items.contains(target) else { return items.map(\.rawValue) }
        var result = items.filter { $0 != kind }
        if let index = result.firstIndex(of: target) { result.insert(kind, at: index) }
        return result.map(\.rawValue)
    }
    static func selected(_ key: String, fallback: Set<MetricKind>) -> Set<MetricKind> {
        guard let ids = AppPreferences.shared.object(forKey: key) as? [String] else { return fallback }
        return Set(ids.compactMap(MetricKind.init(rawValue:)))
    }
}
