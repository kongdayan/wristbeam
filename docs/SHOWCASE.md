# Product showcase

The five READMEs use native WristBeam views with isolated synthetic data. Chinese documentation uses Chinese captures and captions; English, Japanese, Korean and Russian documentation use the English image set. No personal accounts, health records, device identifiers or activity locations enter these assets.

## 0.3.10 documentation refresh

The current hero, menu, themes, settings and floating-panel images come from the UI changes in [PR #20](https://github.com/kongdayan/wristbeam/pull/20), application commit `2d2296fdd2960324b0acd4847613f7c3b722a4f3`. They were rendered in [GitHub Actions run 39894382413](https://github.com/kongdayan/wristbeam/actions/runs/39894382413) and copied unchanged from its `showcase-macos15` artifact. The release preparation updates version metadata separately; these images show the UI shipping in 0.3.10.

| Image | What it shows | Chinese version |
| --- | --- | --- |
| [Hero](images/showcase-hero.png) | Dashboard, icon-only status item and menu panel | [中文](images/showcase-hero-zh.png) |
| [Menu](images/showcase-menu.png) | Menu readings and click-to-open panel | [中文](images/showcase-menu-zh.png) |
| [Themes](images/showcase-themes.png) | Light and dark dashboard | [中文](images/showcase-themes-zh.png) |
| [Settings](images/showcase-settings.png) | Separate preferences window, appearance, text size and layout | [中文](images/showcase-settings-zh.png) |
| [Floating panels](images/showcase-floating.png) | Compact readings and Detailed trends | [中文](images/showcase-floating-zh.png) |

Raw dashboard, menu, floating and display-settings captures in `docs/images/` are refreshed from the same artifact. The icon-only [status item](images/raw-menu-bar.png) remains the earlier computer-use capture; that component was not changed by this UI update. The [sharing examples](images/share-cards-en.png) and [Chinese sharing example](images/share-cards-zh.png) retain their existing synthetic exports.

## How the images are made

`scripts/test-interface-render.py` constructs the real `AppModel` in isolated preview mode, disables Bluetooth/account recovery/uploads and asserts zero cloud requests. It renders production SwiftUI views through `NSHostingView.cacheDisplay`. The current suite exports 152 PNGs covering Chinese/English, light/dark, Compact/Detailed panels, device battery, HRV, activities, expanded sections, narrow windows and 100%/160% text samples.

The same CI harness separately exercises native mouse events for disclosure headers and metric selection, plus list/detail scroll restoration. A screenshot alone does not prove interaction behavior. Local installed-client computer-use checks remain subject to tool availability; see [verification scope](../VERIFICATION.md).

`scripts/render-floating-showcase.swift` arranges unchanged native captures on an original gradient, adding frames and shadows. CI renders the composites; maintainers download the artifact instead of building local demo apps. The earlier [English](showcase/index.html) and [Chinese](showcase/index.zh-CN.html) HTML layouts remain available as historical artwork sources, but the current README composites use the Swift renderer.

The settings layout and Compact/Detailed presentation were inspired by [Pulse](https://github.com/qunqin24/Pulse). WristBeam's implementation, icons and artwork are independently authored; no Pulse source or artwork is bundled. The human-battery and footprint glyphs are drawn in [MetricIcon.swift](../Sources/GarminBar/UI/MetricIcon.swift); other glyphs use macOS SF Symbols. Body Battery keeps its full name in panels and accessibility descriptions.

## Refresh checklist

1. Run CI for the intended UI revision; download `showcase-macos15` and `native-interface-macos15`.
2. Inspect both language sets, including long pages, large text, menu and floating panels.
3. Copy the intended PNGs into `docs/images/`; preserve captures without painting over controls or values.
4. Update the source commit/run above and all five README descriptions; check image links and language selection.
5. Keep the app icon, original status-item capture and unchanged sharing exports unless those components need a new capture.

Only the historical [abstract backdrop](images/showcase-background.png) was made with image generation; product screenshots were not generated or retouched. The [app icon](images/app-icon.png) comes from the project's own vector drawing script. Project-authored artwork follows the [MIT license](../LICENSE).
