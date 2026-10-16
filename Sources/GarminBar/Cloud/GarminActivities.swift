import Foundation
import FoundationXML
import CoreFoundation

/// A deliberately small, account-free projection. Raw cloud JSON can contain names,
/// account/device IDs and coordinates and must never be passed through to MCP.
struct GarminActivity: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var type: String
    var startTimeGMT: String?
    var startTimeLocal: String?
    var statistics: [String: Double]
    var fetchedAt: Date
}

struct GarminActivitySeries: Codable, Equatable {
    var key: String
    var unit: String
    var factor: Double?
    var values: [Double?]
}

struct GarminActivityDetail: Codable, Equatable {
    var summary: GarminActivity
    var series: [GarminActivitySeries]
    var fetchedAt: Date
    /// This is the server's reduced chart, not the complete original recording.
    var chartPointLimit: Int
    var chartAvailable: Bool
}

enum GarminActivityFormat: String, CaseIterable, Identifiable, Codable {
    case tcx, gpx, original
    var id: String { rawValue }
    var label: String { self == .original ? "FIT / ZIP" : rawValue.uppercased() }
    var fileExtension: String { self == .original ? "zip" : rawValue }
    var endpoint: String { self == .original ? "/download-service/files/activity/" : "/download-service/export/\(rawValue)/activity/" }
}

enum GarminActivityError: Error, LocalizedError {
    case invalidResponse, unavailable, noRoute, notCached, storage, repeatedPage
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return L10n.text("运动数据格式无效或超过大小限制")
        case .unavailable: return L10n.text("暂时无法读取运动记录，请稍后重试")
        case .noRoute: return L10n.text("这条运动没有可导出的 GPS 轨迹，请选择 TCX 或原始文件")
        case .notCached: return L10n.text("尚未下载这条运动的数据")
        case .storage: return L10n.text("无法保存运动数据，请检查可用空间")
        case .repeatedPage: return L10n.text("历史列表没有前进，请刷新后重试")
        }
    }
}

enum GarminActivities {
    static let pageSize = 50
    static let chartLimit = 1000
    static let maximumJSONBytes = 8 * 1024 * 1024
    static let maximumFileBytes = 64 * 1024 * 1024
    static let statisticKeys: Set<String> = [
        "duration", "movingDuration", "elapsedDuration", "distance", "calories", "bmrCalories",
        "averageHR", "maxHR", "minHR", "averageSpeed", "maxSpeed", "averageMovingSpeed",
        "elevationGain", "elevationLoss", "steps", "activityTrainingLoad", "aerobicTrainingEffect",
        "anaerobicTrainingEffect", "moderateIntensityMinutes", "vigorousIntensityMinutes",
        "totalReps", "totalSets", "activeSets", "averagePower", "maxPower", "normalizedPower",
        "hrTimeInZone_1", "hrTimeInZone_2", "hrTimeInZone_3", "hrTimeInZone_4", "hrTimeInZone_5"
    ]
    static let seriesKeys: Set<String> = ["directTimestamp", "directHeartRate", "directSpeed", "directPower", "directCadence", "directElevation", "sumDistance", "sumDuration", "sumElapsedDuration", "sumMovingDuration"]

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 19 && id.utf8.allSatisfy { (48...57).contains($0) } && id.first != "0" && (Int64(id) ?? 0) > 0
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    static func object(_ data: Data) throws -> Any {
        guard data.count <= maximumJSONBytes else { throw GarminActivityError.invalidResponse }
        return try JSONSerialization.jsonObject(with: data)
    }
    static func summary(_ json: [String: Any], now: Date = Date()) throws -> GarminActivity {
        guard let id = stringValue(json["activityId"]), validID(id) else { throw GarminActivityError.invalidResponse }
        let values = json["summaryDTO"] as? [String: Any] ?? json
        let type = (json["activityType"] ?? json["activityTypeDTO"]) as? [String: Any]
        var statistics: [String: Double] = [:]
        for key in statisticKeys { if let value = number(values[key]) { statistics[key] = value } }
        if let value = number(values["trainingEffect"]) { statistics["aerobicTrainingEffect"] = value }
        if let value = number(values["totalExerciseReps"]) { statistics["totalReps"] = value }
        return GarminActivity(id: id, name: String((json["activityName"] as? String ?? "").prefix(200)),
                              type: String((type?["typeKey"] as? String ?? "unknown").prefix(80)),
                              startTimeGMT: (values["startTimeGMT"] as? String).map { String($0.prefix(40)) },
                              startTimeLocal: (values["startTimeLocal"] as? String).map { String($0.prefix(40)) },
                              statistics: statistics, fetchedAt: now)
    }
    static func list(_ data: Data, now: Date = Date()) throws -> [GarminActivity] {
        guard let rows = try object(data) as? [[String: Any]], rows.count <= pageSize else { throw GarminActivityError.invalidResponse }
        let result = try rows.map { try summary($0, now: now) }
        guard Set(result.map(\.id)).count == result.count else { throw GarminActivityError.invalidResponse }
        return result
    }
    static func detail(summary data: Data, chart: Data, expectedID: String, now: Date = Date()) throws -> GarminActivityDetail {
        guard let json = try object(data) as? [String: Any], let chartJSON = try object(chart) as? [String: Any],
              stringValue(chartJSON["activityId"]) == expectedID else { throw GarminActivityError.invalidResponse }
        let activity = try summary(json, now: now)
        guard activity.id == expectedID else { throw GarminActivityError.invalidResponse }
        let rows = chartJSON["activityDetailMetrics"] as? [[String: Any]] ?? []
        guard rows.count <= chartLimit * 2 else { throw GarminActivityError.invalidResponse }
        var series: [GarminActivitySeries] = []
        for descriptor in chartJSON["metricDescriptors"] as? [[String: Any]] ?? [] {
            guard let key = descriptor["key"] as? String, seriesKeys.contains(key), !series.contains(where: { $0.key == key }),
                  let rawIndex = number(descriptor["metricsIndex"]), rawIndex.rounded() == rawIndex, (0...255).contains(rawIndex) else { continue }
            let index = Int(rawIndex), unit = descriptor["unit"] as? [String: Any] ?? [:]
            let values: [Double?] = rows.map { row in
                guard let metrics = row["metrics"] as? [Any], metrics.indices.contains(index) else { return nil }
                return number(metrics[index])
            }
            series.append(.init(key: key, unit: String((unit["key"] as? String ?? "").prefix(40)), factor: number(unit["factor"]), values: values))
        }
        return .init(summary: activity, series: series, fetchedAt: now, chartPointLimit: chartLimit,
                     chartAvailable: !rows.isEmpty && !series.isEmpty)
    }
    static func listURL(region: GarminRegion, offset: Int) throws -> URL {
        guard (0...1_000_000).contains(offset) else { throw GarminActivityError.invalidResponse }
        var url = URLComponents(string: region.apiBase + "/activitylist-service/activities/search/activities")!
        url.queryItems = [.init(name: "start", value: String(offset)), .init(name: "limit", value: String(pageSize)),
                          .init(name: "sortBy", value: "startLocal"), .init(name: "sortOrder", value: "desc")]
        return url.url!
    }
    static func validateFile(_ data: Data, format: GarminActivityFormat) throws {
        guard !data.isEmpty, data.count <= maximumFileBytes else { throw GarminActivityError.invalidResponse }
        if format == .original {
            guard data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw GarminActivityError.invalidResponse }
            return // Preserve the server archive verbatim; never extract untrusted ZIP paths.
        }
        let delegate = ActivityXMLValidator(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.root == (format == .gpx ? "gpx" : "TrainingCenterDatabase"), !delegate.hasDTD else { throw GarminActivityError.invalidResponse }
        if format == .gpx && delegate.trackpoints == 0 { throw GarminActivityError.noRoute }
    }
}

private final class ActivityXMLValidator: NSObject, XMLParserDelegate {
    var root: String?
    var trackpoints = 0
    var hasDTD = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = String(elementName.split(separator: ":").last ?? "")
        if root == nil { root = name }
        if name == "trkpt", let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
           lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) { trackpoints += 1 }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { hasDTD = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { hasDTD = true; parser.abortParsing() }
}

struct GarminActivityIndex: Codable {
    var activities: [GarminActivity] = []
    var nextOffset = 0
    var reachedEnd = false
    var refreshedAt: Date?
}

/// Each cloud account/region gets a separate private directory. File names are
/// constructed from validated decimal IDs, never supplied by a remote response.
struct GarminActivityStore {
    let directory: URL
    init(root: URL, scope: String) { directory = root.appendingPathComponent(GarminPrivateFile.digest(Data(scope.utf8)), isDirectory: true) }
    init(directory: URL) { self.directory = directory }
    func loadIndex() -> GarminActivityIndex {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")), data.count <= 64 * 1024 * 1024,
              let index = try? JSONDecoder().decode(GarminActivityIndex.self, from: data) else { return .init() }
        return index
    }
    func saveIndex(_ index: GarminActivityIndex) throws { try GarminPrivateFile.write(JSONEncoder().encode(index), to: directory.appendingPathComponent("index.json")) }
    func file(_ id: String, extension ext: String) throws -> URL {
        guard GarminActivities.validID(id), ["json", "tcx", "gpx", "zip"].contains(ext) else { throw GarminActivityError.invalidResponse }
        return directory.appendingPathComponent(id + "." + ext)
    }
    func detail(_ id: String) -> GarminActivityDetail? {
        guard let url = try? file(id, extension: "json"), let data = try? Data(contentsOf: url), data.count <= GarminActivities.maximumJSONBytes,
              let result = try? JSONDecoder().decode(GarminActivityDetail.self, from: data), result.summary.id == id else { return nil }
        return result
    }
    func save(_ detail: GarminActivityDetail) throws { try GarminPrivateFile.write(JSONEncoder().encode(detail), to: file(detail.summary.id, extension: "json")) }
}
