import Foundation

enum PulseRuntime {
    static var isPreview: Bool { CommandLine.arguments.contains("--preview") || Bundle.main.object(forInfoDictionaryKey: "GarminPulsePreview") as? Bool == true }
    static var previewsOnboarding: Bool { isPreview && (CommandLine.arguments.contains("--preview-onboarding") || Bundle.main.object(forInfoDictionaryKey: "WristBeamPreviewOnboarding") as? Bool == true) }
}

final class AppPreferences {
    // Foundation rejects using the app's own bundle identifier as a suite name.
    // Access its persistent domain directly so bundled and direct launches agree.
    static let shared = AppPreferences(domain: PulseRuntime.previewsOnboarding ? "cn.wenyankong.garminpulse.preview.onboarding" : PulseRuntime.isPreview ? "cn.wenyankong.garminpulse.preview" : "cn.wenyankong.garminpulse")
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
    var cloudSyncEnabled: Bool {
        if let saved = object(forKey: "cloudSyncEnabled") as? Bool { return saved }
        // Preserve existing cloud users; a fresh installation is local-first.
        return bool(forKey: "autoSync") || ["garmin.cn", "garmin.com"].contains {
            !(string(forKey: "\($0).selectedDeviceID") ?? "").isEmpty
        }
    }
    func prepareSetupDefaults() {
        // Freeze the migration once; receiving files later must not opt into cloud access.
        if object(forKey: "cloudSyncEnabled") == nil { set(cloudSyncEnabled, forKey: "cloudSyncEnabled") }
        guard object(forKey: "setupDefaultsVersion") == nil else { return }
        let legacyWatch = string(forKey: "watchIdentifier").flatMap(UUID.init(uuidString:)) != nil
        if object(forKey: "autoSync") == nil { set(legacyWatch, forKey: "autoSync") }
        if object(forKey: "floatingEnabled") == nil { set(legacyWatch, forKey: "floatingEnabled") }
        if object(forKey: "watchConnectOnLaunch") == nil { set(false, forKey: "watchConnectOnLaunch") }
        set(1, forKey: "setupDefaultsVersion")
    }
}

enum AppPaths {
    static let root: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(PulseRuntime.previewsOnboarding ? "WristBeamOnboardingPreview" : PulseRuntime.isPreview ? "GarminPulsePreview" : "GarminPulse", isDirectory: true)
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
    enum Event { case saved(Date), failed(Int) }
    var onEvent: ((Event) -> Void)?
    private let queue = DispatchQueue(label: "cn.wristbeam.telemetry", qos: .utility)
    private let directory: URL
    private let write: (Data, URL) throws -> Void
    private var lastSaved: [MetricKind: Date] = [:]
    private var pending: [(MetricSample, Data)] = []
    private var attempts = 0
    private var scheduled = false
    private var dropped = 0
    init(directory: URL = AppPaths.directory("Telemetry"), writer: ((Data, URL) throws -> Void)? = nil) {
        self.directory = directory
        self.write = writer ?? { bytes, file in
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            let offset = try handle.seekToEnd()
            do { try handle.write(contentsOf: bytes); try handle.synchronize() }
            catch { try? handle.truncate(atOffset: offset); throw error }
        }
    }
    func append(_ sample: MetricSample) {
        queue.async { [self] in
            if let previous = lastSaved[sample.kind], sample.timestamp.timeIntervalSince(previous) < 1 { return }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            guard var bytes = try? encoder.encode(sample) else { onEvent?(.failed(pending.count + 1)); return }
            bytes.append(0x0A)
            guard pending.count < 4096 else { dropped += 1; onEvent?(.failed(pending.count + dropped)); return }
            lastSaved[sample.kind] = sample.timestamp
            pending.append((sample, bytes))
            if attempts < 3 && !scheduled { flush() }
        }
    }
    func retry() { queue.async { [self] in attempts = 0; if !scheduled { flush() } } }
    private func flush() {
        while let item = pending.first {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
            let file = directory.appendingPathComponent(formatter.string(from: item.0.timestamp) + ".jsonl")
            do { try write(item.1, file); pending.removeFirst(); attempts = 0; onEvent?(.saved(Date())) }
            catch {
                attempts += 1; onEvent?(.failed(pending.count + dropped))
                if attempts < 3 {
                    scheduled = true
                    queue.asyncAfter(deadline: .now() + Double(attempts)) { [self] in scheduled = false; flush() }
                }
                return
            }
        }
        if dropped > 0 { onEvent?(.failed(dropped)) }
    }
}
