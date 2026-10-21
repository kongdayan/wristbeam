# Local UX review — 2026-10-21

Native SwiftUI captures for PRs [#14](https://github.com/kongdayan/wristbeam/pull/14), [#15](https://github.com/kongdayan/wristbeam/pull/15) and [#16](https://github.com/kongdayan/wristbeam/pull/16). Each PR is compared with its immediate parent, not with an unrelated release.

| PR | Before | After |
|---|---|---|
| #14 | `dba7b37fb7ef5e5b29ed6292ffd146937b14c31a` | `5a8c849f9505a3fdeaf3aadfe669726f590a9a77` |
| #15 | `5a8c849f9505a3fdeaf3aadfe669726f590a9a77` | `5ab958aed0c2b9da20e1afb447fb9242ceb0f3b1` |
| #16 | `5ab958aed0c2b9da20e1afb447fb9242ceb0f3b1` | `9424d54ccb0c390d14aa1573273d70d2f3c63a00` |

## Capture and verification

- All four snapshots compiled and rendered locally on macOS arm64, explicitly requested for this review. The final #16 snapshot also passed a complete `swift build -c debug -j 4` in 50.97 seconds, including the application entry point.
- A temporary adaptation of `scripts/test-interface-render.py` rendered the production views through `NSHostingView`; these are actual native view captures, not mockups or screenshots of the installed release. Production view sources were not edited.
- The harness used the existing synthetic preview fixtures and synthetic activity `1001`. A temporary copy of `AppStorage.swift` redirected preferences and files to separate review-only stores. Each snapshot asserted zero cloud requests. No personal health readings, account data or device identifiers are included.
- 40 captures per snapshot (160 total) completed successfully. This folder contains 20 selected originals, reviewed visually; no image pixels have been retouched.
- Standard views: 1020 × 768 points, 115% text. Narrow dashboard: 880 × 640 points, 160% text. Pairing cards: 640 points wide, 115% text, intrinsic height. PNGs use native 2× resolution. English/light and Chinese/dark pairs have matching settings.
- Page captures show the initial visible viewport; content below the viewport requires scrolling. Pairing states are injected preview states, not live Bluetooth sessions. Preview mode disables connection actions. Current-clock timestamps can differ slightly between snapshots.
- The settings-context comparison starts on a synthetic activity detail, calls `openSettings(.settings)`, then captures the main view. Before #14 it becomes settings; after #14 the activity detail remains. Preferences are captured separately. This does not test macOS window focus or keyboard events.

## Visual observations

- **#14:** the dedicated preferences sidebar removes the crowded nested navigation; English labels such as Network and refresh / Developer integrations wrap instead of truncating. Activity detail remains visible in the main view when preferences open.
- **#15:** category hierarchy and flatter cards are clearer. At 1020 points and 115% text, three highlights occupy a two-plus-one layout with an empty cell, reducing visible metric density. At 880 points / 160% text the adaptive single column fixes truncated metric names, but the sidebar still wraps WristBeam and clips Sync records. Those sidebar issues are visible in both the before and after snapshots.
- **#16:** connection diagnostics collapse into details and the active step is easier to scan. The four synthetic states show prepare, scanning, confirming and choosing local/cloud sync. Real device pairing, reconnect, forgetting a device, and cloud sync were not exercised by this visual review.

The screenshot commit is documentation only. It does not modify the feature branches, merge the PRs, publish a release or install another app.
