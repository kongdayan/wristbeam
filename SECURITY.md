# Security policy

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/kongdayan/wristbeam/security/advisories/new). Please include the affected version, reproduction steps and a minimal sanitized example. Do not publish secrets or private health/location data in public issues.

Only the latest stable release is actively maintained. Older releases remain available as historical artifacts; there is no guaranteed response or patch deadline.

## Credentials and health data

Passwords are entered on Garmin's official sign-in page and are not stored by the app. Tokens and original records stay under `~/Library/Application Support/GarminPulse/`, with private directory/file permissions. Do not attach that directory, `runtime-state.json`, authorization files, raw telemetry or original FIT to an issue.

The demo uses separate storage/preferences and disables Bluetooth and uploads. Use it for public screenshots.

## Repository controls

PR and release checks include Gitleaks over Git history/current source, SwiftLint, shell/workflow analysis and CodeQL for Swift, Python and GitHub Actions. Actions are pinned to commit SHAs and maintained by Dependabot. Fork PRs do not run a publishing job or receive release credentials.

Release assets have SHA-256 checksums, a commit-bound manifest and GitHub build-provenance attestations. The updater requires confirmation and validates the download, archive, application identity, version, architecture and signature before replacement.

Packages currently use ad hoc signatures, not Developer ID signing or Apple notarization. A checksum proves consistency with the published artifact; it is not a substitute for publisher identity or notarization. Never bypass an unexpected identity, checksum or account-ownership error.
