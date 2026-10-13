# Garmin Pulse

[简体中文](README.md) · [Download](https://github.com/kongdayan/garmin-pulse/releases/latest)

A native macOS menu bar, floating panel and dashboard companion for Garmin watches. It uses normal Garmin Bluetooth services for live metrics and original FIT file transfer, then syncs those files to Garmin Connect China or Global. China account sync has been verified with an Instinct 2 Solar.

![Dashboard](docs/images/english.png)

![Display configuration](docs/images/display-settings.png)

The screenshots are real macOS windows captured with computer-use. Values are simulated in an isolated demo instance; no personal account or watch records are shown.

## Install

Download the ZIP for your Mac, extract it, and move **Garmin Pulse.app** into a writable Applications folder. The initial release supports Apple Silicon and macOS 13+. The app is ad hoc signed and is not Apple notarized.

Allow Bluetooth access. On Instinct 2 Solar, hold MENU → Phone → Pair Phone. Keep heart-rate broadcast off; temporarily disable phone Bluetooth if it occupies the connection. Follow the app's pairing guide, then sign in on Garmin's official page in the correct account region. Passwords are not stored.

## Features

- Only metrics with valid received readings appear in the grouped selection table. Dashboard, panel and menu bar have independent checkbox columns and group selection controls.
- Live heart rate, Body Battery, stress, steps, respiration, SpO₂, RR intervals and available daily summaries. RR is not presented as an overnight HRV score.
- Daily curves, interval bars, stress overlay, historical dates, 1/6-hour views, cursor readings and original record tables. Missing and future periods remain empty.
- Related summary links: resting heart rate opens the heart-rate chart. Unsupported hourly summaries do not link to an unrelated chart.
- Adjustable text size, light/dark/system themes, card sizes, column counts and drag ordering. Simplified Chinese, English and system language.
- Persistent original FIT uploads with content deduplication, retries, account ownership checks and separate China/Global state.
- GitHub Releases checks every 12 hours. Download and installation require confirmation; packages undergo SHA-256, archive, identity, architecture and signature checks. The previous app and all account/data/preferences are retained.

The app runs while open, including after its main window closes. It does not sync while the Mac sleeps. Desktop WidgetKit support is not included in the current release. Native MLR / CoreTransfer and application-level encryption are unsupported; real Global account uploads still need validation.

## Build and checks

```sh
python3 scripts/test-core.py
python3 scripts/check-localization.py
zsh scripts/build.sh
python3 scripts/test-updater.py
```

See [verification scope](VERIFICATION.md). Data and credentials stay under `~/Library/Application Support/GarminPulse/` and are excluded from the repository and app packages. The demo uses separate storage and preferences, with Bluetooth and uploads disabled.

This independent project is not affiliated with Garmin.
