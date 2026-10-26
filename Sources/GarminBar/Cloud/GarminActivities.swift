import Foundation
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
    var heartRateZones: [GarminActivityZone]? = nil
    var laps: [GarminActivityLap]? = nil
    var unavailableSections: [String]? = nil
}

struct GarminActivityZone: Codable, Equatable, Identifiable {
    var number: Int
    var seconds: Double
    var lowerBPM: Double?
    var id: Int { number }
}

struct GarminActivityLap: Codable, Equatable, Identifiable {
    var index: Int
    var statistics: [String: Double]
    var id: Int { index }
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
    static let statisticKeys = Set(ActivityMetricCatalog.statistics.map(\.key))
    static let seriesKeys = Set(ActivityMetricCatalog.charts.map(\.key)).union(["directTimestamp"])

    static func statistics(_ values: [String: Any]) -> [String: Double] {
        var result: [String: Double] = [:]
        for key in statisticKeys { if let value = number(values[key]) { result[key] = value } }
        if let value = number(values["trainingEffect"]) { result["aerobicTrainingEffect"] = value }
        if let value = number(values["totalExerciseReps"]) { result["totalReps"] = value }
        return result
    }

    static func zones(_ data: Data) throws -> [GarminActivityZone] {
        guard let rows = try object(data) as? [[String: Any]], rows.count <= 20 else { throw GarminActivityError.invalidResponse }
        let result = try rows.map { row -> GarminActivityZone in
            guard let index = number(row["zoneNumber"]), index.rounded() == index, (0...20).contains(index),
                  let seconds = number(row["secsInZone"]), seconds >= 0 else { throw GarminActivityError.invalidResponse }
            return .init(number: Int(index), seconds: seconds, lowerBPM: number(row["zoneLowBoundary"]))
        }.sorted { $0.number < $1.number }
        guard Set(result.map(\.number)).count == result.count else { throw GarminActivityError.invalidResponse }
        return result
    }

    static func laps(_ data: Data, expectedID: String) throws -> [GarminActivityLap] {
        guard let json = try object(data) as? [String: Any], identifier(json["activityId"]) == expectedID,
              let rows = json["lapDTOs"] as? [[String: Any]], rows.count <= 5000 else { throw GarminActivityError.invalidResponse }
        let result = try rows.enumerated().map { offset, row -> GarminActivityLap in
            let index = number(row["lapIndex"]) ?? Double(offset + 1)
            guard index.rounded() == index, (0...100_000).contains(index) else { throw GarminActivityError.invalidResponse }
            return .init(index: Int(index), statistics: statistics(row))
        }
        guard Set(result.map(\.index)).count == result.count else { throw GarminActivityError.invalidResponse }
        return result
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 19 && id.utf8.allSatisfy { (48...57).contains($0) } && id.first != "0" && (Int64(id) ?? 0) > 0
    }
    static func identifier(_ value: Any?) -> String? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard let id = stringValue(value), validID(id) else { return nil }
        return id
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
        guard let id = identifier(json["activityId"]) else { throw GarminActivityError.invalidResponse }
        let values = json["summaryDTO"] as? [String: Any] ?? json
        let type = (json["activityType"] ?? json["activityTypeDTO"]) as? [String: Any]
        return GarminActivity(id: id, name: String((json["activityName"] as? String ?? "").prefix(200)),
                              type: String((type?["typeKey"] as? String ?? "unknown").prefix(80)),
                              startTimeGMT: (values["startTimeGMT"] as? String).map { String($0.prefix(40)) },
                              startTimeLocal: (values["startTimeLocal"] as? String).map { String($0.prefix(40)) },
                              statistics: statistics(values), fetchedAt: now)
    }
    static func list(_ data: Data, now: Date = Date()) throws -> [GarminActivity] {
        guard let rows = try object(data) as? [[String: Any]], rows.count <= pageSize else { throw GarminActivityError.invalidResponse }
        let result = try rows.map { try summary($0, now: now) }
        guard Set(result.map(\.id)).count == result.count else { throw GarminActivityError.invalidResponse }
        return result
    }
    static func detail(summary data: Data, chart: Data, expectedID: String, now: Date = Date()) throws -> GarminActivityDetail {
        guard let json = try object(data) as? [String: Any], let chartJSON = try object(chart) as? [String: Any],
              identifier(chartJSON["activityId"]) == expectedID else { throw GarminActivityError.invalidResponse }
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
    var schemaVersion: Int? = 2
    var historyAnchorID: String?
    var historyAnchorTime: String?
    var needsHistoryRebase: Bool?

    mutating func mergePage(_ rows: [GarminActivity], offset: Int, older: Bool) {
        let previous = activities
        if older || previous.isEmpty {
            nextOffset = offset + rows.count
            reachedEnd = rows.isEmpty
            if let last = rows.last {
                historyAnchorID = last.id
                historyAnchorTime = last.startTimeGMT ?? last.startTimeLocal
            }
            needsHistoryRebase = false
        } else {
            // Refreshing the head must not reset a cursor deep in history.
            if let overlap = rows.enumerated().first(where: { row in previous.contains { $0.id == row.element.id } }),
               let oldPosition = previous.firstIndex(where: { $0.id == overlap.element.id }) {
                nextOffset = max(0, nextOffset + overlap.offset - oldPosition)
            } else if !rows.isEmpty {
                needsHistoryRebase = true; reachedEnd = false
            }
        }
        var byID = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for row in rows { byID[row.id] = row }
        activities = byID.values.sorted {
            let a = $0.startTimeGMT ?? $0.startTimeLocal ?? "", b = $1.startTimeGMT ?? $1.startTimeLocal ?? ""
            return a == b ? (Int64($0.id) ?? 0) > (Int64($1.id) ?? 0) : a > b
        }
        schemaVersion = 2
        if !older { refreshedAt = Date() }
    }
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
    func hasDetail(_ id: String) -> Bool {
        guard let url = try? file(id, extension: "json") else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    func formats(_ id: String) -> [String] {
        GarminActivityFormat.allCases.filter {
            guard let url = try? file(id, extension: $0.fileExtension) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }.map(\.rawValue)
    }
    func save(_ detail: GarminActivityDetail) throws { try GarminPrivateFile.write(JSONEncoder().encode(detail), to: file(detail.summary.id, extension: "json")) }
}

/// Metadata only; file contents and private account paths never enter the view model.
struct ActivityDownload: Identifiable, Equatable {
    let filename: String
    let activityID: String
    let fileExtension: String
    let bytes: Int64
    let modifiedAt: Date?
    var id: String { filename }
    var formatLabel: String { fileExtension == "json" ? "JSON" : fileExtension == "zip" ? "FIT / ZIP" : fileExtension.uppercased() }
    static func isManagedFilename(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && GarminActivities.validID(String(parts[0])) && ["json", "tcx", "gpx", "zip"].contains(String(parts[1]))
    }
    func checkedFile(in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(filename)
        guard Self.isManagedFilename(filename), file.pathExtension == fileExtension,
              file.deletingPathExtension().lastPathComponent == activityID,
              directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL,
              file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL else { throw GarminActivityError.storage }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw GarminActivityError.storage }
        return file
    }
    func moveToTrash(in directory: URL) throws -> URL {
        let file = try checkedFile(in: directory)
        var result: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &result)
        guard let result else { throw GarminActivityError.storage }
        return result as URL
    }
    static func inventory(in directory: URL) -> [Self] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url -> Self? in
            guard isManagedFilename(url.lastPathComponent), let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return Self(filename: url.lastPathComponent, activityID: url.deletingPathExtension().lastPathComponent,
                        fileExtension: url.pathExtension, bytes: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate)
        }.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }
}

extension GarminActivity {
    var displayType: String {
        switch type.lowercased() {
        case "running", "treadmill_running", "trail_running", "track_running": return L10n.text("跑步")
        case "cycling", "indoor_cycling", "mountain_biking", "road_biking": return L10n.text("骑行")
        case "walking", "casual_walking", "hiking": return L10n.text("步行与徒步")
        case "swimming", "lap_swimming", "open_water_swimming": return L10n.text("游泳")
        case "strength_training", "fitness_equipment": return L10n.text("力量训练")
        case "badminton": return L10n.text("羽毛球")
        case "yoga", "pilates": return L10n.text("瑜伽与普拉提")
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var displaySymbol: String {
        switch type.lowercased() {
        case let value where value.contains("running"): return "figure.run"
        case let value where value.contains("cycling") || value.contains("biking"): return "bicycle"
        case let value where value.contains("swimming"): return "figure.pool.swim"
        case "walking", "casual_walking", "hiking": return "figure.walk"
        case "strength_training", "fitness_equipment": return "dumbbell"
        case "badminton": return "figure.badminton"
        case "yoga", "pilates": return "figure.yoga"
        default: return "figure.mixed.cardio"
        }
    }
    /// startTimeLocal is already the workout's local wall time; don't shift it
    /// into the Mac's current time zone when formatting a trip's activity.
    var displayStartTime: String {
        guard let raw = startTimeLocal else { return "—" }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "yyyy-MM-dd HH:mm:ss"; parser.isLenient = false
        let normalized = String(raw.prefix(19)).replacingOccurrences(of: "T", with: " ")
        guard let date = parser.date(from: normalized) else { return raw }
        let formatter = DateFormatter(); formatter.locale = L10n.locale; formatter.timeZone = parser.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMdHm")
        return formatter.string(from: date)
    }
}
