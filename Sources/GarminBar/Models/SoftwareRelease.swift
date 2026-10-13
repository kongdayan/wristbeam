import Foundation
import CryptoKit

struct PulseVersion: Comparable, Equatable {
    let components: [Int]
    init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        components = parts.map { Int($0)! }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let a = index < lhs.components.count ? lhs.components[index] : 0
            let b = index < rhs.components.count ? rhs.components[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}

struct PulseRepository: Equatable {
    static let defaultName = "kongdayan/garmin-pulse"
    let owner: String
    let name: String
    var slug: String { "\(owner)/\(name)" }
    var url: URL { URL(string: "https://github.com/\(slug)")! }
    var latestURL: URL { URL(string: "https://api.github.com/repos/\(slug)/releases/latest")! }
    init?(_ input: String) {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("https://") {
            guard let url = URL(string: raw), url.host == "github.com", url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil else { return nil }
            raw = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if raw.hasSuffix(".git") { raw = String(raw.dropLast(4)) }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.allSatisfy({ !$0.isEmpty && $0.count <= 100 && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        owner = String(parts[0]); name = String(parts[1])
    }
    func permitsReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil && url.port == nil && url.path.hasPrefix("/\(slug)/releases/")
    }
}

struct PulseReleaseAsset: Decodable {
    let name: String
    let size: Int
    let digest: String?
    let browserDownloadURL: URL
    enum CodingKeys: String, CodingKey { case name, size, digest; case browserDownloadURL = "browser_download_url" }
    var sha256: String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let value = String(digest.dropFirst(7)).lowercased()
        return value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } ? value : nil
    }
}

struct PulseRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [PulseReleaseAsset]
    enum CodingKeys: String, CodingKey { case body, draft, prerelease, assets; case tagName = "tag_name"; case htmlURL = "html_url" }
    var version: PulseVersion? { PulseVersion(tagName) }
    func asset(repository: PulseRepository, architecture: String) -> PulseReleaseAsset? {
        guard !draft, !prerelease, version != nil, repository.permitsReleaseURL(htmlURL) else { return nil }
        return assets.first { $0.name == "GarminPulse-macOS-\(architecture).zip" && (1...100_000_000).contains($0.size) && $0.sha256 != nil && repository.permitsReleaseURL($0.browserDownloadURL) && $0.browserDownloadURL.path.hasPrefix("/\(repository.slug)/releases/download/") }
    }
}

enum PulseUpdatePolicy {
    static func permitsRedirect(_ url: URL, repository: PulseRepository) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return false }
        return repository.permitsReleaseURL(url) || ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
    }
    static func archivePathIsSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains("."), !components.dropLast().contains("") else { return false }
        return components.first == "Garmin Pulse.app" || (components.first == "__MACOSX" && components.count > 1)
    }
    static func fileDigest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hasher = SHA256()
        while let block = try file.read(upToCount: 1_048_576), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
