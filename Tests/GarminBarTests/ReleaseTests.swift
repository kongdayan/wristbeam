import XCTest
@testable import GarminBar

final class ReleaseTests: XCTestCase {
    func testStableVersionsCompareNumericallyAndRejectMalformedTags() {
        XCTAssertTrue(PulseVersion("v0.10.0")! > PulseVersion("0.9.9")!)
        XCTAssertEqual(PulseVersion("1.2"), PulseVersion("1.2.0"))
        for tag in ["1", "v1.2-beta", "1..2", "1.2+bad", "-1.2", "1.2.99999999999999999999999"] { XCTAssertNil(PulseVersion(tag)) }
    }
    func testRepositoriesAndAssetsStayOnSelectedPublicReleaseScope() throws {
        let repo = try XCTUnwrap(PulseRepository("https://github.com/kongdayan/garmin-pulse.git"))
        XCTAssertEqual(repo.slug, PulseRepository.defaultName)
        for value in ["../garmin-pulse", "a/b/c", "https://evil.test/a/b", "https://user@github.com/a/b", "a/..", "https://github.com/a/b?token=x"] { XCTAssertNil(PulseRepository(value)) }
        let json = """
        {"tag_name":"v0.3.0","html_url":"https://github.com/kongdayan/garmin-pulse/releases/tag/v0.3.0","draft":false,"prerelease":false,"assets":[{"name":"GarminPulse-macOS-arm64.zip","size":900,"digest":"sha256:\(String(repeating: "a", count: 64))","browser_download_url":"https://github.com/kongdayan/garmin-pulse/releases/download/v0.3.0/GarminPulse-macOS-arm64.zip"}]}
        """
        let release = try JSONDecoder().decode(PulseRelease.self, from: Data(json.utf8))
        XCTAssertNotNil(release.asset(repository: repo, architecture: "arm64"))
        XCTAssertNil(release.asset(repository: repo, architecture: "x86_64"))
        XCTAssertNil(release.asset(repository: PulseRepository("another/repo")!, architecture: "arm64"))
        for replacement in [json.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true"), json.replacingOccurrences(of: "sha256:", with: "sha1:"), json.replacingOccurrences(of: "/releases/download/", with: "/archive/")] {
            let bad = try JSONDecoder().decode(PulseRelease.self, from: Data(replacement.utf8))
            XCTAssertNil(bad.asset(repository: repo, architecture: "arm64"))
        }
    }
    func testArchiveTraversalAndDownloadRedirectsAreRejected() {
        for path in ["/tmp/evil", "Garmin Pulse.app/../../escape", "Garmin Pulse.app/./Contents", "Garmin Pulse.app//Contents", "Garmin Pulse.app/Contents\nfile", "Another.app/Contents", "Garmin Pulse.app\\Contents"] { XCTAssertFalse(PulseUpdatePolicy.archivePathIsSafe(path)) }
        XCTAssertTrue(PulseUpdatePolicy.archivePathIsSafe("Garmin Pulse.app/Contents/MacOS/GarminPulse"))
        let repo = PulseRepository(PulseRepository.defaultName)!
        XCTAssertTrue(PulseUpdatePolicy.permitsRedirect(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/file?sig=public")!, repository: repo))
        for url in ["http://github.com/kongdayan/garmin-pulse/releases/download/v1/a.zip", "https://github.com/another/repo/releases/download/v1/a.zip", "https://release-assets.githubusercontent.com.evil.test/a", "https://user@objects.githubusercontent.com/a"] { XCTAssertFalse(PulseUpdatePolicy.permitsRedirect(URL(string: url)!, repository: repo)) }
    }
    func testStreamingDigestDetectsChangedPackageBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try PulseUpdatePolicy.fileDigest(url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try Data("abd".utf8).write(to: url)
        XCTAssertNotEqual(try PulseUpdatePolicy.fileDigest(url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
