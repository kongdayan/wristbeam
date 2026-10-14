import AppKit
import Combine

@MainActor
final class PulseUpdater: ObservableObject {
    @Published var repository: String = {
        let saved = AppPreferences.shared.string(forKey: "updateRepository") ?? PulseRepository.defaultName
        return PulseRepository(saved)?.slug == PulseRepository.defaultName ? PulseRepository.defaultName : saved
    }() {
        didSet { AppPreferences.shared.set(repository, forKey: "updateRepository"); release = nil; lastChecked = nil; AppPreferences.shared.removeObject(forKey: "lastUpdateCheck"); status = "更新仓库已保存" }
    }
    @Published var automaticChecks = AppPreferences.shared.object(forKey: "automaticUpdateChecks") as? Bool ?? true {
        didSet { AppPreferences.shared.set(automaticChecks, forKey: "automaticUpdateChecks") }
    }
    @Published private(set) var release: PulseRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var status = "准备检查 GitHub Releases"
    @Published private(set) var lastChecked = AppPreferences.shared.object(forKey: "lastUpdateCheck") as? Date
    var onConfirmation: (() -> Void)?
    var canInstall: (() -> Bool)?
    init() {
        if AppPreferences.shared.string(forKey: "updateRepository") != repository {
            AppPreferences.shared.set(repository, forKey: "updateRepository")
        }
    }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.2" }
    var parsedRepository: PulseRepository? { PulseRepository(repository) }
    // Local package tests exercise the production validation/install path. This
    // entry point is absent from Release builds and never changes the server.
    var validationFixture: URL? {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--update-fixture"), CommandLine.arguments.count > index + 1 {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: "GarminPulseUpdateFixture") as? String { return URL(fileURLWithPath: path) }
        #endif
        return nil
    }
    var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    var available: Bool {
        guard let release, let version = release.version, let current = PulseVersion(currentVersion) else { return false }
        return version > current
    }
    var installable: Bool { available && parsedRepository.flatMap { release?.asset(repository: $0, architecture: architecture) } != nil && Bundle.main.bundleURL.pathExtension == "app" }
    func check(automatic: Bool = false) async {
        guard !isChecking, !isInstalling, !automatic || (automaticChecks && Date().timeIntervalSince(lastChecked ?? .distantPast) >= 43_200) else { return }
        guard let repo = parsedRepository else { status = "请输入有效的 GitHub owner/repo 或仓库链接"; return }
        isChecking = true; status = "正在检查 GitHub 最新版本"
        defer { isChecking = false }
        do {
            var request = URLRequest(url: repo.latestURL); request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("WristBeam/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let data: Data
            let response: URLResponse
            if let fixture = validationFixture {
                data = try Data(contentsOf: fixture)
                response = HTTPURLResponse(url: repo.latestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard repo == parsedRepository else { return }
            guard let http = response as? HTTPURLResponse else { throw UpdateError.invalidResponse }
            lastChecked = Date(); AppPreferences.shared.set(lastChecked, forKey: "lastUpdateCheck")
            if http.statusCode == 404 { release = nil; status = "仓库尚无正式版本，或仓库不可访问"; return }
            if [403, 429].contains(http.statusCode) { status = "GitHub 暂时限制请求，请稍后再试"; return }
            guard http.statusCode == 200, data.count <= 2_000_000 else { throw UpdateError.invalidResponse }
            let candidate = try JSONDecoder().decode(PulseRelease.self, from: data)
            guard !candidate.draft, !candidate.prerelease, candidate.version != nil, repo.permitsReleaseURL(candidate.htmlURL) else { throw UpdateError.invalidResponse }
            release = candidate
            status = available ? "发现新版本 \(candidate.tagName)" : "已是最新版本 \(currentVersion)"
            if automatic && available && AppPreferences.shared.string(forKey: "skippedUpdateVersion.\(repo.slug)") != candidate.tagName { onConfirmation?() }
        } catch { status = "检查更新失败：\(error.localizedDescription)" }
    }
    func requestUpgrade() { if installable && !isInstalling { onConfirmation?() } }
    func skipVersion() { if let release, let repo = parsedRepository { AppPreferences.shared.set(release.tagName, forKey: "skippedUpdateVersion.\(repo.slug)") } }
    func installConfirmed() async {
        guard installable, !isInstalling, canInstall?() != false, let release, let repo = parsedRepository,
              let asset = release.asset(repository: repo, architecture: architecture) else { status = "请等待文件同步结束后再升级"; return }
        isInstalling = true; status = "正在下载更新；你的账户和数据会保留"
        defer { isInstalling = false }
        let directory = AppPaths.directory("Updates").appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var request = URLRequest(url: asset.browserDownloadURL); request.timeoutInterval = 120
            request.setValue("WristBeam/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let delegate = ReleaseDownloadDelegate(repository: repo, maximumBytes: asset.size)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let temporary: URL
            let response: URLResponse
            if let fixture = validationFixture {
                temporary = directory.appendingPathComponent("fixture-download.zip")
                try FileManager.default.copyItem(at: fixture.deletingLastPathComponent().appendingPathComponent("release.zip"), to: temporary)
                response = HTTPURLResponse(url: asset.browserDownloadURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            } else {
                (temporary, response) = try await session.download(for: request)
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let finalURL = http.url, PulseUpdatePolicy.permitsRedirect(finalURL, repository: repo) else { throw UpdateError.invalidResponse }
            let archive = directory.appendingPathComponent("release.zip")
            try FileManager.default.moveItem(at: temporary, to: archive)
            let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue
            guard size == asset.size else { throw UpdateError.invalidArchive }
            status = "校验安装包与应用签名"
            let target = Bundle.main.bundleURL
            let prepared = try await Task.detached(priority: .utility) {
                guard try PulseUpdatePolicy.fileDigest(archive) == asset.sha256 else { throw UpdateError.checksum }
                return try PulseUpdatePreparation.prepare(archive: archive, directory: directory, target: target, version: release.tagName, architecture: selfArchitecture())
            }.value
            guard canInstall?() != false else { throw UpdateError.busy }
            guard let helper = Bundle.main.url(forResource: "update-helper", withExtension: "sh") else { throw UpdateError.installLocation }
            let result = directory.appendingPathComponent("result.txt")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), prepared.path, target.path, directory.path, result.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            status = "更新已校验，即将重新启动"
            NSApplication.shared.terminate(nil)
        } catch { status = "升级未完成：\(error.localizedDescription)" }
    }
}

private func selfArchitecture() -> String {
    #if arch(arm64)
    return "arm64"
    #else
    return "x86_64"
    #endif
}

private final class ReleaseDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let repository: PulseRepository
    let maximumBytes: Int
    init(repository: PulseRepository, maximumBytes: Int) { self.repository = repository; self.maximumBytes = maximumBytes }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { PulseUpdatePolicy.permitsRedirect($0, repository: repository) } == true ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

enum UpdateError: LocalizedError {
    case invalidResponse, invalidArchive, checksum, installLocation, identity, busy
    var errorDescription: String? {
        let text: String
        switch self {
        case .invalidResponse: text = "GitHub 返回的版本信息或下载地址无效"
        case .invalidArchive: text = "安装包大小、目录或格式不符合要求"
        case .checksum: text = "安装包 SHA-256 校验失败"
        case .installLocation: text = "无法替换当前应用，请先将软件放在可写的 Applications 文件夹"
        case .identity: text = "应用身份、版本、架构或签名校验失败"
        case .busy: text = "文件仍在同步，请完成后重试"
        }
        return L10n.text(text)
    }
}

enum PulseUpdatePreparation {
    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.identity }
        return String(decoding: data, as: UTF8.self)
    }
    static func prepare(archive: URL, directory: URL, target: URL, version: String, architecture: String) throws -> URL {
        let paths = try command("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n").map(String.init)
        guard !paths.isEmpty, paths.count <= 10_000, paths.allSatisfy(PulseUpdatePolicy.archivePathIsSafe) else { throw UpdateError.invalidArchive }
        let listing = try command("/usr/bin/zipinfo", ["-l", archive.path])
        guard !listing.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw UpdateError.invalidArchive }
        let totals = try command("/usr/bin/zipinfo", ["-t", archive.path])
        let expression = try NSRegularExpression(pattern: "([0-9]+) bytes uncompressed")
        guard let match = expression.firstMatch(in: totals, range: NSRange(totals.startIndex..., in: totals)),
              let range = Range(match.range(at: 1), in: totals), let expandedSize = Int(totals[range]), expandedSize < 500_000_000 else { throw UpdateError.invalidArchive }
        let expanded = directory.appendingPathComponent("Expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: true)
        _ = try command("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
        let roots = Set(paths.compactMap { $0.split(separator: "/").first.map(String.init) }.filter { ["WristBeam.app", "Garmin Pulse.app"].contains($0) })
        guard roots.count == 1, let appName = roots.first else { throw UpdateError.invalidArchive }
        let app = expanded.appendingPathComponent(appName, isDirectory: true)
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "cn.wenyankong.garminpulse",
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "GarminPulse",
              let installedVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              PulseVersion(installedVersion) == PulseVersion(version),
              let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
              let required = PulseVersion(minimum) else { throw UpdateError.identity }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        guard required <= PulseVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")! else { throw UpdateError.identity }
        let architectures = try command("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/GarminPulse").path])
        guard architectures.split(whereSeparator: \.isWhitespace).contains(Substring(architecture)) else { throw UpdateError.identity }
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let currentSigning = try command("/usr/bin/codesign", ["-d", "--verbose=4", target.path])
        let nextSigning = try command("/usr/bin/codesign", ["-d", "--verbose=4", app.path])
        if let team = currentSigning.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") && $0 != "TeamIdentifier=not set" }) {
            guard nextSigning.split(separator: "\n").contains(team) else { throw UpdateError.identity }
        }
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.installLocation }
        let stage = parent.appendingPathComponent(".GarminPulse-update-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: app, to: stage)
        return stage
    }
}
