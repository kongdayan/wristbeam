# Product showcase

The README uses actual app views from the isolated **WristBeam Demo** instance. Its values are simulated, its preferences/storage are separate, and Bluetooth, saved account recovery and uploading are disabled. No user's health data, account identifiers, device IDs or activity locations appear in these assets.

| Image | What it shows |
| --- | --- |
| [Hero](images/showcase-hero.png) | Native dashboard, status item and expanded menu panel |
| [Menu](images/showcase-menu.png) | Actual icon-only menu readings and the click-to-open panel |
| [Themes](images/showcase-themes.png) | Native light and dark dashboard captures |
| [Settings](images/showcase-settings.png) | Grouped three-surface selection matrix |

## Capture method

Computer-use opens and operates the native demo app. The native computer-use screenshot service returned oversized Retina extents on this Mac. To keep the real UI intact, computer-use invokes the Demo's Save demo screenshot command (⌘S), which exports only its own actual AppKit hosting view at 3× resolution. Native view captures are [raw-dashboard-en.png](images/raw-dashboard-en.png), [dashboard-light.png](images/dashboard-light.png), [dashboard-dark.png](images/dashboard-dark.png) and [display-settings.png](images/display-settings.png).

Clicking **Open menu bar** opens the real `NSPopover`. Only in Demo mode, the app exports its actual `NSStatusItem` button and hosting view at 3× resolution using AppKit view rendering: [raw-menu-bar.png](images/raw-menu-bar.png), [raw-menu-popup.png](images/raw-menu-popup.png). This avoids global desktop capture and the focus change that closes transient popovers in the computer-use tool. These are actual native components, not generated interface illustrations.

The human-battery and footprint glyphs are original code-drawn vectors in [MetricIcon.swift](../Sources/GarminBar/UI/MetricIcon.swift). Other glyphs use macOS SF Symbols. Body Battery keeps its full name in panels and accessibility descriptions; no BB abbreviation is used.

[HTML/CSS artwork](showcase/index.html) places the unmodified native PNGs on a background with rounded frames and shadows. [The local WKWebView viewer](../scripts/showcase-viewer.swift) renders four scenes; keys 1–4 switch scenes. Computer-use operates the resulting viewer and its “Save showcase image” command. The viewer exports its actual WKWebView rectangle through WebKit snapshot rendering, avoiding an incorrect Retina window extent in the native computer-use screenshot service. No AI-generated controls, values or fake product UI are added. Rounded shells and shadows are decorative layout around unchanged captures.

## Background brief

The original background brief used the former working name Garmin Pulse; the name is updated here for readability. No brand or product text is rendered into the backdrop.

Only [the abstract backdrop](images/showcase-background.png) was generated with the built-in image generation tool. It was not used to edit the app screenshots.

> Use case: ads-marketing. Background plate for premium independent macOS WristBeam product showcase. Generate only abstract backdrop, no device/interface/text/logos. Wide 16:9, quiet pearl/off-white center, subtle translucent mint-green and warm amber outer halos, frosted glass and very subtle film grain, restrained light, clean negative space for real screenshots. Avoid busy patterns, diagrams, simulated UI, hard borders, stock photos, neon and watermarks.

The background is reused consistently across four native HTML/CSS scenes. The [app icon](images/app-icon.png) comes from the project's own vector drawing script. Project-authored artwork follows [the MIT license](../LICENSE); Garmin and platform marks remain their owners' marks.
