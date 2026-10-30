# WristBeam

A macOS companion for Garmin watches. Connect your watch over Bluetooth, keep your data on your Mac, and use it in your own tools or AI assistant.

[English](README.md) · [简体中文](README.cn.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md)

**[Download for macOS](https://github.com/kongdayan/wristbeam/releases/latest/download/WristBeam-macOS-universal.zip)** · [Release notes](CHANGELOG.md) · [Report an issue](https://github.com/kongdayan/wristbeam/issues)

Requires macOS 13 or later. One Universal app supports both Apple Silicon and Intel Macs.

## Get started

1. Download and unzip the app, then move **WristBeam.app** to **Applications**.
2. Open **Devices → Connection**. Follow the pairing guide, allow Bluetooth access and select your watch.
3. Open **Dashboard** to view available readings. Customize the menu bar and floating panel in **Settings**.

You can use watch data locally without signing in. To access Garmin cloud history or upload files, connect your account in **Devices → Device account**, then choose what to sync in **Sync records**.

[Connection and setup guide](docs/SETUP.md). Current builds are ad hoc signed and are not Apple notarized.

![WristBeam dashboard, menu bar and floating panel using demo data](docs/images/showcase-hero.webp)

## What you can do

- **Keep your data locally.** Receive original activity and health FIT files from your watch, keep them on your Mac and export them when needed. Garmin cloud sync is optional.
- **Connect AI and automation.** Query cached health and workout data through read-only MCP, HTTP/HTTPS API or the Python SDK. Configure webhooks for your own workflows; integrations are off until enabled.
- **See your daily health at a glance.** View heart rate, Body Battery, stress, steps and available trends in the dashboard, menu bar or floating panel.
- **Review workouts.** Browse activity history, open charts and statistics, and export JSON, TCX, GPX or original files where available.
- **Manage watch faces.** Search Connect IQ, install watch-face packages over Bluetooth and edit supported settings. Switching the active face depends on controls supplied by the watch.

## Compatibility

**Instinct 2 Solar** has been tested on a physical device. Other Garmin models and firmware need individual verification. Available metrics depend on the watch and data source; cloud-only records require a connected account.

[Supported devices](docs/DEVICES.md) · [Available metrics](docs/METRICS.md) · [Verification scope](VERIFICATION.md)

## Documentation and contributing

- [Setup and troubleshooting](docs/SETUP.md)
- [Connect IQ watch faces](docs/CONNECTIQ.md)
- [MCP, API and Python SDK](docs/developer/API.md)
- [Build and contribute](CONTRIBUTING.md) · [Security reports](SECURITY.md)
- [More screenshots](docs/SHOWCASE.md) · [Changelog](CHANGELOG.md)

Open source under the [MIT license](LICENSE). Device reports, bug fixes and translations are welcome.
