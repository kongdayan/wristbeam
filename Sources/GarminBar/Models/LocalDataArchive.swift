import Foundation
import CoreFoundation

struct LocalDataSummary {
    var fitFiles = 0
    var telemetryDays = 0
    var bytes: Int64 = 0
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// An allowlist export: never walks auth, settings, diagnostics or cloud caches.
enum LocalDataArchive {
    private static func files(root: URL) -> [URL] {
        let manager = FileManager.default
        var result: [URL] = []
        for (folder, suffix) in [("Received", "fit"), ("UploadQueue/OriginalFIT", "fit"), ("Telemetry", "jsonl")] {
            let directory = root.resolvingSymlinksInPath().appendingPathComponent(folder)
            // Reject redirected roots as well as redirected descendants.
            guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL,
                  let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true, values.isRegularFile == true,
                      url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL,
                      url.pathExtension.lowercased() == suffix else { continue }
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }
    static func summary(root: URL) -> LocalDataSummary {
        var result = LocalDataSummary()
        for url in files(root: root) {
            if url.pathExtension.lowercased() == "fit" { result.fitFiles += 1 } else { result.telemetryDays += 1 }
            result.bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return result
    }
    static func export(root: URL, to destination: URL) throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("WristBeam-export-\(UUID().uuidString)")
        let payload = temporary.appendingPathComponent("WristBeam-Local-Data")
        let fits = payload.appendingPathComponent("FIT")
        try manager.createDirectory(at: fits, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        let csv = payload.appendingPathComponent("watch-readings.csv")
        try GarminPrivateFile.write(Data("timestamp,metric,value\n".utf8), to: csv)
        let writer = try FileHandle(forWritingTo: csv)
        defer { try? writer.close() }
        try writer.seekToEnd()
        let formatter = ISO8601DateFormatter()
        var identities = Set<String>(), readings = 0
        for url in files(root: root) {
            if url.pathExtension.lowercased() == "fit" {
                let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                let digest = GarminPrivateFile.digest(bytes)
                if identities.insert(digest).inserted { try GarminPrivateFile.write(bytes, to: fits.appendingPathComponent(digest + ".fit")) }
            } else {
                try lines(url) { line in
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          (object["origin"] as? String ?? "watch") == "watch",
                          let raw = object["kind"] as? String, let kind = MetricKind(rawValue: raw), !kind.isDeviceStatus,
                          let stamp = object["timestamp"] as? String, let date = GarminHealthMetrics.gmtDate(stamp),
                          let value = object["value"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return }
                    let row = "\(formatter.string(from: date)),\(kind.rawValue),\(value.doubleValue)\n"
                    try writer.write(contentsOf: Data(row.utf8)); readings += 1
                }
            }
        }
        try writer.synchronize()
        let manifest: [String: Any] = ["formatVersion": 1, "fitFiles": identities.count, "watchReadings": readings,
                                       "readingsSource": "watch", "createdAt": ISO8601DateFormatter().string(from: Date())]
        try GarminPrivateFile.write(JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]), to: payload.appendingPathComponent("manifest.json"))
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".wristbeam-export-\(UUID().uuidString).zip")
        defer { try? manager.removeItem(at: staged) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", payload.path, staged.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: staged) }
        else { try manager.moveItem(at: staged, to: destination) }
    }
    private static func lines(_ url: URL, body: (Data) throws -> Void) throws {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var pending = Data()
        while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                try body(pending.subdata(in: pending.startIndex..<end))
                pending.removeSubrange(pending.startIndex...end)
            }
            guard pending.count < 1_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        }
        if !pending.isEmpty { try body(pending) }
    }
}
