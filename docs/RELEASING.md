# Release pipeline

Stable tags create public release assets automatically after every required check succeeds. The published assets are:

| Asset | Use |
| --- | --- |
| `WristBeam-macOS-arm64.zip` | Apple Silicon; used by the updater on arm64 |
| `WristBeam-macOS-x86_64.zip` | Intel; used by the updater on x86_64 |
| `WristBeam-macOS-universal.zip` | Both architectures in one app |
| `SHA256SUMS.txt` | SHA-256 for all three ZIPs |
| `release-manifest.json` | Version, exact commit, minimum OS, sizes and digests |

All packages target macOS 13+. CI builds/tests on macOS 14, 15 and 26, with native Intel and Apple Silicon jobs. Hosted macOS 13 testing is not available in this matrix. Runner labels follow [GitHub's supported runner table](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

## Maintainer steps

1. Update `VERSION`, the fallback version in `SoftwareUpdater.swift`, `project.yml` marketing/build versions, and `CHANGELOG.md`. Regenerate the Xcode project with `xcodegen generate --spec project.yml`.
2. Run local checks listed in [CONTRIBUTING.md](../CONTRIBUTING.md), then open a focused PR. Wait for `CI passed` before merging.
3. From a clean, updated main branch, push a stable tag matching `VERSION`:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

4. Watch [Release](https://github.com/kongdayan/wristbeam/actions/workflows/release.yml). It reuses the full CI, combines validated native apps with `lipo`, re-signs the universal app, checks every package and writes the manifest/checksums.
5. The publishing job creates a draft, uploads assets, verifies GitHub's reported sizes/digests, then publishes. A retry can resume a draft; it cannot overwrite an already public release. Fix a published build with a new version/tag.
6. Download the public ZIPs and verify their SHA-256. Confirm the app's production updater recognizes the release and selects the appropriate native asset.

The release-only job receives `contents: write` and provenance permissions; PR jobs do not. No personal Garmin credentials are needed for CI or packaging.

## Signing and provenance

Current packages are ad hoc signed and are not Apple notarized. Developer ID signing and notarization are a separate future task. Every ZIP has a [GitHub build-provenance attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds):

```sh
gh attestation verify WristBeam-macOS-arm64.zip --repo kongdayan/wristbeam
shasum -a 256 -c SHA256SUMS.txt
```

Download all three ZIPs before checking the complete checksum file, or check an individual hash. Do not claim a Developer ID identity from an ad hoc signature.

## Checks

- SwiftLint safety/quality rules; Actionlint and ShellCheck.
- Source syntax, local documentation links, five-language navigation and localization coverage.
- Gitleaks over full Git history and current public-source files, including local unstaged edits.
- Production protocol/cloud regression harness and native XCTest on each runner.
- Signed update-package rejection tests plus release archive/manifest regression tests.
- CodeQL `security-extended` for Swift, Python and Actions. Swift analysis uses a native Intel macOS runner and an explicit build, following [GitHub's compiled-language setup](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/codeql-for-compiled-languages).

CodeQL uploads branch/PR analysis to the repository security dashboard. Tag validation runs analysis without uploading a tag result. Dependabot maintains pinned action revisions; a scheduled workflow also scans the main branch weekly.

## Brand transition from 0.3.0

WristBeam retains the previous application bundle identifier, executable identity, private data directory and preference domain so an existing account and original files stay available. The 0.3.1 updater migrates only the known old repository address to `kongdayan/wristbeam`; custom repositories are preserved. New releases use `WristBeam.app` and `WristBeam-macOS-*.zip`. The updater recognizes both the new and legacy archive roots, with exactly one application per package.

The old 0.3.0 updater pins the former repository path and cannot interpret GitHub's renamed release URLs. For this transition, download WristBeam once from the new Release page, quit the old app and launch WristBeam. Your private data and preferences are retained. Subsequent releases use the normal confirmed update flow.

## CI tiers and artifact reuse

PR checks cover native Apple Silicon and Intel builds, tests, UI rendering on ARM and CodeQL. Main, merge-queue and full release fallback cover macOS 14/15/26 ARM plus Intel. Cancelled workflows skip the aggregate gate rather than reporting a secondary failure.

Release first looks for a successful `ci.yml` main-push run for the exact tag commit. If that run is still active it waits up to 35 minutes; without a usable run/artifact it executes full release checks. Reuse verifies GitHub's artifact SHA-256, allowed archive members, embedded source commit/run ID/version/architecture, and package SHA-256. Existing native signature, architecture and version validation still runs before universal packaging and publication. PR artifacts and artifacts from another commit are never reusable. API contract: [GitHub artifact endpoints](https://docs.github.com/en/rest/actions/artifacts).

A release is still an explicit operator action. These workflows do not create version tags automatically.
