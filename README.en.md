<div align="center">
<img src="docs/images/app-icon.png" width="76" alt="WristBeam" />

# WristBeam

Your wrist, in view.

[![CI](https://github.com/kongdayan/wristbeam/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/kongdayan/wristbeam/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/kongdayan/wristbeam)](https://github.com/kongdayan/wristbeam/releases/latest)
[![MIT](https://img.shields.io/badge/license-MIT-91d8b1)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-13%2B-1d2628?logo=apple)](https://github.com/kongdayan/wristbeam/releases/latest)

[简体中文](README.md) · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md)

</div>

![WristBeam](docs/images/showcase-hero.png)

**Menu bar · Floating panel · Dashboard.** Receive data through normal Garmin Bluetooth services, download original FIT files and sync to Garmin Connect China or Global. Verified with Instinct 2 Solar and a China account.

[Download](https://github.com/kongdayan/wristbeam/releases/latest) · [Issues & device reports](https://github.com/kongdayan/wristbeam/issues) · [Contribute](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

## A closer look

![Menu bar and click-to-open panel](docs/images/showcase-menu.png)

![Themes and dashboard](docs/images/showcase-themes.png)

![Display configuration](docs/images/showcase-settings.png)

![Compact and Detailed floating panels](docs/images/showcase-floating.png)

Real app UI with isolated demo data. [Original captures and artwork notes](docs/SHOWCASE.md).

## Features

- Compact dimensional cards with timestamps beside the title. Customize layout and essentials in one panel; share the dashboard, selected cards or a single value as a framed image in light or dark, with copy, save and native sharing.
- Independent menu bar, panel and dashboard selections, group toggles, search, drag ordering, adjustable text and layout.
- Daily curves, interval bars, date/time ranges, cursor readings and original records. Gaps remain empty.
- Garmin Bluetooth pairing guide, persistent original-FIT queue, deduplication and cloud sync.
- Light/dark/system themes, Chinese/English app UI, and updates that require confirmation.

Opt-in read-only MCP, HTTP/HTTPS API, Python SDK and signed webhooks in Settings → Developer integrations. [Developer API](docs/developer/API.md).

![Framed sharing preview with three synthetic metric cards](docs/images/share-cards-en.png)

## Device support

Currently compatible with **Garmin** watches; verified models are listed below. Other brands and devices may be added later.

| Watch | Live metrics | Original FIT + China cloud | Solar records | Status |
| --- | --- | --- | --- | --- |
| Instinct 2 Solar | ✓ | ✓ | ✓ | Device verified |
| Instinct 2 / 2S / 2X | Unverified | Unverified | Model dependent | Reports welcome |
| fēnix / epix / Forerunner | Unverified | Unverified | Model dependent | Reports welcome |
| Venu / vívoactive and other models | Unverified | Unverified | Model dependent | Reports welcome |

Support depends on firmware and available services; an entire family is not assumed compatible. [Detailed matrix and reporting](docs/DEVICES.md).

## Data you can collect

| Metric | Source | Presentation |
| --- | --- | --- |
| Heart rate, Body Battery, stress | Garmin notifications + daily cloud records | Current readings, daily curves |
| Steps | Bluetooth + cloud | Daily total, interval increments |
| Respiration, SpO₂ | Measurements emitted by watch / cloud | Readings, daily trends |
| RR intervals | Bluetooth | Milliseconds; not an overnight HRV score |
| Overnight HRV | Cloud sleep records | Nightly / seven-day average, status, baseline and night chart; missing fields stay empty |
| Watch battery | Garmin Bluetooth protocol | Verified on Instinct 2; change notifications + periodic refresh |
| Calories, floors, intensity minutes | Fields supplied by watch / cloud | Daily totals; some interval data |
| Resting heart rate, sleep duration, recovery summaries | Daily cloud summary | Summary values and related trends |
| Solar intensity | Valid cloud minute records | Midnight-to-midnight curve |
| Sunlight / solar charging duration | Estimated from valid input minutes | Explicitly labeled estimates |
| Activity and health FIT | Original watch files | Retained locally, uploaded to cloud |

The catalog has **61 metric definitions**. Only metrics with valid received data appear; availability varies by watch. [Full catalog and evidence](docs/METRICS.md).

## Install

| Mac | Download |
| --- | --- |
| Apple Silicon | [arm64](https://github.com/kongdayan/wristbeam/releases/latest/download/WristBeam-macOS-arm64.zip) |
| Intel | [x86_64](https://github.com/kongdayan/wristbeam/releases/latest/download/WristBeam-macOS-x86_64.zip) |
| Either architecture | [Universal](https://github.com/kongdayan/wristbeam/releases/latest/download/WristBeam-macOS-universal.zip) |

Requires macOS 13+. Extract and move the app to a writable Applications folder. Open Devices → Connection, prepare the watch with heart-rate broadcast off, then click a connection button to allow Bluetooth. Choose China/Global in Device account and sign in on Garmin's official page; choose manual or automatic uploads in Sync records. Connecting at launch is off by default and can be enabled after pairing.

Ad hoc signed; not Apple notarized. Real Global uploads and other firmware remain unverified. Application-level encryption, native MLR / CoreTransfer and desktop widgets are unsupported. The Mac cannot sync immediately while asleep. [Verification scope](VERIFICATION.md).

## Contribute and share

PRs, translations, device results and ideas are welcome. **[MIT](LICENSE)** permits use, modification and redistribution with the license retained. This independent project is not affiliated with Garmin.

[Development & PR guide](CONTRIBUTING.md) · [Security reports](SECURITY.md) · [Automated releases](docs/RELEASING.md)
