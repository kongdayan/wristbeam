import Foundation
import CryptoKit
import CoreFoundation

struct LocalStoragePlan {
    struct File {
        let url: URL
        let digest: String
        let bytes: Int64
    }
    struct Journal {
        let file: File
        let outputDigest: String
        let outputBytes: Int64
        let discarded: Int
    }
    let root: URL
    let ledgerDigest: String?
    let confirmedJobs: Int
    let protectedJobs: Int
    let fitFiles: [File]
    let journals: [Journal]
    let telemetryBytes: Int64
    let protectedFiles: Int
    var fitBytes: Int64 { fitFiles.reduce(0) { $0 + $1.bytes } }
    var journalSavings: Int64 { journals.reduce(0) { $0 + $1.file.bytes - $1.outputBytes } }
}

/// A local-only preview. No receipt is inferred from a file's age or an empty pending queue.
/// Execution validates the preview again, keeps the ledger, and puts originals in Trash.
enum LocalStorageMaintenance {
    enum Failure: LocalizedError {
        case changed, unsafe, busy, rollback
        var errorDescription: String? {
            switch self {
            case .changed: return "文件或上传记录已变化，请重新检查后再清理。"
            case .unsafe: return "无法安全读取本地文件，原数据保留。"
            case .busy: return "请等待同步或导出完成后再清理。"
            case .rollback: return "清理未完成，部分原文件保留在本地恢复目录，请打开本地数据检查。"
            }
        }
    }
    static func confirmed(_ job: GarminUploadJob) -> Bool {
        guard let receipt = job.cloudStatus, receipt.state == job.state, receipt.fileName == job.fileName else { return false }
        if job.state == .accepted { return [200,201].contains(receipt.httpStatus ?? 0) }
        if job.state == .duplicate { return [200,201,409].contains(receipt.httpStatus ?? 0) }
        return false // In particular: HTTP 202 and empty data are not uploaded data.
    }
    private static func checked(_ file: URL, root: URL) throws {
        let base = root.standardizedFileURL
        guard base == base.resolvingSymlinksInPath().standardizedFileURL,
              file.standardizedFileURL.path.hasPrefix(base.path + "/"),
              file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.unsafe }
        let info = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw Failure.unsafe }
    }
    private static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount:1_048_576), !data.isEmpty { hash.update(data:data) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    private static func entry(_ file: URL, root: URL) throws -> LocalStoragePlan.File {
        try checked(file,root:root)
        return .init(url:file.standardizedFileURL,digest:try digest(file),bytes:Int64(try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0))
    }
    private static func relative(_ file: URL, root: URL) -> String {
        String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count+1))
    }
    static func inspect(root: URL, region: GarminRegion, account: String, now: Date = Date()) throws -> LocalStoragePlan {
        let fm = FileManager.default
        let ledger = root.appendingPathComponent("UploadQueue/upload-queue.json")
        var jobs: [GarminUploadJob] = [], ledgerHash: String?, protectedFiles = 0
        if fm.fileExists(atPath:ledger.path) {
            try checked(ledger,root:root)
            let bytes = try Data(contentsOf:ledger)
            jobs = try JSONDecoder().decode([GarminUploadJob].self,from:bytes)
            ledgerHash = GarminPrivateFile.digest(bytes)
        }
        let scoped = jobs.filter { !$0.accountGUID.isEmpty && $0.accountGUID == account && $0.effectiveRegion == region }
        let confirmedJobs = scoped.filter(confirmed)
        let grouped = Dictionary(grouping:jobs,by:\.fileName)
        var allowed: [String:Set<String>] = [:], blocked = Set<String>(), fits: [LocalStoragePlan.File] = []
        for (name, references) in grouped {
            guard name.count == 68, name.hasSuffix(".fit"), name.dropLast(4).allSatisfy({ "0123456789abcdef".contains($0) }) else { protectedFiles += 1; continue }
            let url = root.appendingPathComponent("UploadQueue/OriginalFIT").appendingPathComponent(name)
            guard fm.fileExists(atPath:url.path) else { continue }
            do {
                let file = try entry(url,root:root)
                let eligible = references.allSatisfy { confirmed($0) && !$0.accountGUID.isEmpty && $0.accountGUID == account && $0.effectiveRegion == region }
                guard eligible else { blocked.insert(file.digest); continue }
                let data = try Data(contentsOf:url,options:.mappedIfSafe)
                for job in references {
                    var identity = Data("\(job.deviceID):\(job.dataType.rawValue):".utf8); identity.append(data)
                    guard GarminPrivateFile.digest(identity) + ".fit" == name else { throw Failure.unsafe }
                }
                fits.append(file)
                allowed[file.digest,default:[]].formUnion(references.map(\.deviceID))
            } catch { protectedFiles += 1 }
        }
        // A pending or other-account reference to identical bytes protects every copy.
        fits.removeAll { blocked.contains($0.digest) }
        for hash in blocked { allowed[hash] = nil }
        let received = root.appendingPathComponent("Received")
        if received.standardizedFileURL == received.resolvingSymlinksInPath().standardizedFileURL,
           let enumerator = fm.enumerator(at:received,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles,.skipsPackageDescendants]) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "fit" {
                do {
                    let file = try entry(url,root:root)
                    if allowed[file.digest]?.contains(url.deletingLastPathComponent().lastPathComponent) == true { fits.append(file) }
                } catch { protectedFiles += 1 }
            }
        }
        var journals: [LocalStoragePlan.Journal] = [], telemetryBytes: Int64 = 0
        let folder = root.appendingPathComponent("Telemetry")
        if folder.standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL,
           let files = try? fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) {
            for file in files where file.pathExtension == "jsonl" {
                do {
                    try checked(file,root:root)
                    telemetryBytes += Int64(try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)
                    guard let day = GarminHRV.date(file.deletingPathExtension().lastPathComponent), day < Calendar.current.startOfDay(for:now) else { continue }
                    let original = try entry(file,root:root)
                    let result = try compact(file) { _ in }
                    guard original.digest == result.inputDigest else { throw Failure.changed }
                    if result.bytes < original.bytes { journals.append(.init(file:original,outputDigest:result.outputDigest,outputBytes:result.bytes,discarded:result.discarded)) }
                } catch { protectedFiles += 1 }
            }
        }
        return .init(root:root,ledgerDigest:ledgerHash,confirmedJobs:confirmedJobs.count,
                     protectedJobs:scoped.count-confirmedJobs.count,fitFiles:fits,journals:journals,
                     telemetryBytes:telemetryBytes,protectedFiles:protectedFiles)
    }
    private struct Key: Equatable { let stamp: String; let value: Double }
    struct Compaction {
        let inputDigest: String
        let outputDigest: String
        let bytes: Int64
        let discarded: Int
    }
    /// Preserve every distinct watch timestamp/value and every unrecognized line verbatim.
    /// Cloud/estimated rows were never consumed by HealthHistoryReader or CSV export.
    static func compact(_ file: URL, emit: (Data) throws -> Void) throws -> Compaction {
        let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
        var pending = Data(), input = SHA256(), output = SHA256(), bytes: Int64 = 0, discarded = 0
        var previous: [String:Key] = [:]
        func consume(_ raw: Data) throws {
            var keep = true
            if let row = try? JSONSerialization.jsonObject(with:raw) as? [String:Any],
               let kind = row["kind"] as? String, MetricKind(rawValue:kind) != nil,
               let stamp = row["timestamp"] as? String,
               let number = row["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                let origin = row["origin"] as? String ?? "watch"
                if origin == "cloud" || origin == "estimated" { keep = false }
                else if origin == "watch" {
                    let key = Key(stamp:stamp,value:number.doubleValue)
                    if previous[kind] == key { keep = false } else { previous[kind] = key }
                }
            }
            if keep { var line = raw; line.append(10); try emit(line); output.update(data:line); bytes += Int64(line.count) }
            else { discarded += 1 }
        }
        while let chunk = try handle.read(upToCount:65_536), !chunk.isEmpty {
            input.update(data:chunk); pending.append(chunk)
            while let end = pending.firstIndex(of:10) {
                try consume(pending.subdata(in:pending.startIndex..<end)); pending.removeSubrange(pending.startIndex...end)
            }
            guard pending.count < 1_000_000 else { throw Failure.unsafe }
        }
        if !pending.isEmpty { try consume(pending) }
        return .init(inputDigest:input.finalize().map { String(format:"%02x",$0) }.joined(),
                     outputDigest:output.finalize().map { String(format:"%02x",$0) }.joined(),bytes:bytes,discarded:discarded)
    }
    struct Result { let originals: Int; let compacted: Int; let appBytesReduced: Int64 }
    /// Call only while the telemetry writer and chart saves are exclusively held.
    /// Whole folders include today's readings, history indexes and all account chart caches.
    static func clearReadingHistory(root: URL,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at:$0,resultingItemURL:nil) }) throws -> Int64 {
        let fm = FileManager.default, root = root.standardizedFileURL
        guard root == root.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.unsafe }
        let folders = ["Telemetry", "Charts"].map { root.appendingPathComponent($0,isDirectory:true) }
        var bytes: Int64 = 0
        for folder in folders where fm.fileExists(atPath:folder.path) {
            guard try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]).isDirectory == true,
                  folder == folder.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.unsafe }
            var enumerationError: Error?
            guard let items = fm.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey],
                errorHandler:{ _, error in enumerationError = error; return false }) else { throw Failure.unsafe }
            for case let item as URL in items {
                let info = try item.resourceValues(forKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.fileSizeKey])
                guard info.isSymbolicLink != true, info.isRegularFile == true || info.isDirectory == true else { throw Failure.unsafe }
                if info.isRegularFile == true { bytes += Int64(info.fileSize ?? 0) }
            }
            if let enumerationError { throw enumerationError }
        }
        let stage = root.appendingPathComponent("Storage-Recovery-" + UUID().uuidString)
        try fm.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var moved: [(URL,URL)] = [], created: [URL] = []
        do {
            for folder in folders {
                if fm.fileExists(atPath:folder.path) {
                    let backup = stage.appendingPathComponent(folder.lastPathComponent,isDirectory:true)
                    try fm.moveItem(at:folder,to:backup); moved.append((folder,backup))
                }
                try fm.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                created.append(folder)
            }
            try trash(stage)
        } catch {
            var recovered = true
            for folder in created { do { try fm.removeItem(at:folder) } catch { recovered = false } }
            for (folder, backup) in moved.reversed() { do { try fm.moveItem(at:backup,to:folder) } catch { recovered = false } }
            if !recovered { throw Failure.rollback }
            try? fm.removeItem(at:stage)
            throw error
        }
        return bytes
    }
    static func execute(_ plan: LocalStoragePlan, removeFIT: Bool, compactLogs: Bool,
                        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at:$0,resultingItemURL:nil) }) throws -> Result {
        let fm = FileManager.default, root = plan.root
        let ledger = root.appendingPathComponent("UploadQueue/upload-queue.json")
        if let expected = plan.ledgerDigest { try checked(ledger,root:root); guard try digest(ledger) == expected else { throw Failure.changed } }
        else if fm.fileExists(atPath:ledger.path) { throw Failure.changed }
        let fits = removeFIT ? plan.fitFiles : [], journals = compactLogs ? plan.journals : []
        for journal in journals {
            guard let day = GarminHRV.date(journal.file.url.deletingPathExtension().lastPathComponent),
                  day < Calendar.current.startOfDay(for:Date()) else { throw Failure.changed }
        }
        guard !fits.isEmpty || !journals.isEmpty else { return .init(originals:0,compacted:0,appBytesReduced:0) }
        for file in fits + journals.map(\.file) { try checked(file.url,root:root); guard try digest(file.url) == file.digest else { throw Failure.changed } }
        let stage = root.appendingPathComponent("Storage-Recovery-" + UUID().uuidString)
        try fm.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var moved: [(URL,URL)] = [], replacements: [URL] = []
        do {
            // Prepare compacted outputs before moving any original.
            for item in journals {
                let output = stage.appendingPathComponent("new-" + item.file.url.lastPathComponent)
                guard fm.createFile(atPath:output.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw Failure.unsafe }
                let writer = try FileHandle(forWritingTo:output)
                let result: Compaction
                do { result = try compact(item.file.url) { try writer.write(contentsOf:$0) }; try writer.synchronize(); try writer.close() }
                catch { try? writer.close(); throw error }
                guard result.inputDigest == item.file.digest, result.outputDigest == item.outputDigest, result.bytes == item.outputBytes else { throw Failure.changed }
            }
            if let expected = plan.ledgerDigest { guard try digest(ledger) == expected else { throw Failure.changed } }
            for file in fits + journals.map(\.file) {
                // A second check closes the preview/preparation race.
                try checked(file.url,root:root); guard try digest(file.url) == file.digest else { throw Failure.changed }
                let relativePath = relative(file.url,root:root)
                let backup = stage.appendingPathComponent("Originals").appendingPathComponent(relativePath)
                try fm.createDirectory(at:backup.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                try fm.moveItem(at:file.url,to:backup); moved.append((file.url,backup))
                if let journal = journals.first(where:{ $0.file.url == file.url }) {
                    try fm.moveItem(at:stage.appendingPathComponent("new-"+journal.file.url.lastPathComponent),to:file.url)
                    replacements.append(file.url)
                }
            }
            let manifest = moved.map { ["path":relative($0.0,root:root)] }
            try GarminPrivateFile.write(JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted]),to:stage.appendingPathComponent("restore-paths.json"))
            try trash(stage)
        } catch {
            var recovered = true
            for url in replacements { do { try fm.removeItem(at:url) } catch { recovered = false } }
            for (original,backup) in moved.reversed() {
                do { try fm.moveItem(at:backup,to:original) } catch { recovered = false }
            }
            if recovered { try? fm.removeItem(at:stage) } else { throw Failure.rollback }
            throw error
        }
        return .init(originals:fits.count,compacted:journals.count,
                     appBytesReduced:(removeFIT ? plan.fitBytes : 0) + (compactLogs ? plan.journalSavings : 0))
    }
}
