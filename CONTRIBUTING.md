# Contributing to WristBeam

Bug reports, device compatibility results, documentation translations and focused pull requests are welcome. Contributions use the [MIT license](LICENSE).

## Start here

- [Bug report](https://github.com/kongdayan/wristbeam/issues/new?template=bug_report.yml)
- [Device support report](https://github.com/kongdayan/wristbeam/issues/new?template=device_support.yml)
- [Feature request](https://github.com/kongdayan/wristbeam/issues/new?template=feature_request.yml)
- [Device matrix](docs/DEVICES.md) · [Metric catalog](docs/METRICS.md)

Keep one PR focused on one change. Explain the resulting behavior and the checks you ran. Screenshots help for visual changes; use the isolated demo, never personal account or health data.

## Build and test

macOS 13+, Swift 5.9+ and Command Line Tools are enough to build the app and run the CLT regression harness. Native `swift test` and CodeQL Swift analysis use full Xcode; CI provides it.

```sh
brew install actionlint gitleaks shellcheck swiftlint
zsh scripts/lint.sh
python3 scripts/check-repository.py
python3 scripts/check-localization.py
python3 scripts/check-secrets.py
python3 -m unittest discover -s Tests/ReleasePipeline -p 'test_*.py' -v
python3 scripts/test-core.py
zsh scripts/build.sh
python3 scripts/test-updater.py
```

With full Xcode, also run `swift test`. The lint wrapper selects the CLT SourceKit library when it is available. To avoid replacing a running local app, set `PULSE_OUTPUT_DIR` to a separate directory for both the build and package checks.

```sh
PULSE_OUTPUT_DIR=/tmp/pulse-build zsh scripts/build.sh
PULSE_OUTPUT_DIR=/tmp/pulse-build python3 scripts/test-updater.py
```

## Source map

| Directory | Responsibility |
| --- | --- |
| `Bluetooth/`, `Protocol/` | Discovery, pairing, Garmin notifications and original FIT transfer |
| `Cloud/` | Official sign-in, region routing, daily data and persistent uploads |
| `Models/`, `UI/` | Metric catalog, display preferences, charts, language and presentation |
| `App/` | Application lifecycle, local control and confirmed updates |
| `scripts/`, `.github/workflows/` | Local checks, signed packaging and automated releases |

## Keep these properties

- Save original files before acknowledging the last Bluetooth block. Do not delete watch files or write account GUIDs.
- Distinguish valid readings, unavailable values, daily summaries and estimates. Registering a service does not prove it supplies data.
- Preserve China/Global account isolation and per-account file ownership checks.
- Add meaningful protocol or packaging regression tests when behavior changes. Use temporary fixtures; never send synthetic FIT to Garmin.
- Add Chinese source strings to `Resources/Localization/en.json`, keeping placeholders identical. README translations are independent from app UI languages.
- Keep language navigation, device status and metric claims consistent in all five READMEs. Detail belongs in `docs/`, not the product introduction.

## Releasing

See [the release pipeline](docs/RELEASING.md). Stable `vX.Y.Z` tags must match `VERSION`. Every PR and tag runs the quality/security/build checks. Release jobs publish only after checks pass and never replace an already public release.

## Security

Do not submit credentials, account GUIDs, device serials, original FIT or health/location records. Follow [SECURITY.md](SECURITY.md) for private vulnerability reports.
