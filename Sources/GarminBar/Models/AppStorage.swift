import Foundation

enum PulseRuntime {
    static var isPreview: Bool { CommandLine.arguments.contains("--preview") || Bundle.main.object(forInfoDictionaryKey: "GarminPulsePreview") as? Bool == true }
}

final class AppPreferences {
    // Foundation rejects using the app's own bundle identifier as a suite name.
    // Access its persistent domain directly so bundled and direct launches agree.
    static let shared = AppPreferences(domain: PulseRuntime.isPreview ? "cn.wenyankong.garminpulse.preview" : "cn.wenyankong.garminpulse")
    private let domain: String
    private let defaults = UserDefaults.standard
    init(domain: String = "cn.wenyankong.garminpulse") { self.domain = domain }
    func object(forKey key: String) -> Any? { defaults.persistentDomain(forName: domain)?[key] }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    func set(_ value: Any?, forKey key: String) {
        var values = defaults.persistentDomain(forName: domain) ?? [:]
        values[key] = value
        defaults.setPersistentDomain(values, forName: domain)
        defaults.synchronize()
    }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
}

enum AppPaths {
    static let root: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(PulseRuntime.isPreview ? "GarminPulsePreview" : "GarminPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }()
    static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}

struct ActivityLog: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}

final class TelemetryJournal {
    private let encoder = JSONEncoder()
    private let queue = DispatchQueue(label: "cn.garminpulse.telemetry", qos: .utility)
    private var lastSaved: [MetricKind: Date] = [:]
    init() { encoder.dateEncodingStrategy = .iso8601 }
    func append(_ sample: MetricSample) {
        // A maximum of one sample per metric per second avoids duplicate sources.
        if let previous = lastSaved[sample.kind], sample.timestamp.timeIntervalSince(previous) < 1 { return }
        lastSaved[sample.kind] = sample.timestamp
        queue.async { [self] in
            guard var bytes = try? encoder.encode(sample) else { return }
            bytes.append(0x0A)
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            let file = AppPaths.directory("Telemetry").appendingPathComponent(formatter.string(from: sample.timestamp) + ".jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: bytes) } catch { /* retain UI samples; storage errors are not cloud success */ }
        }
    }
}
