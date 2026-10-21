# Daily workflow verification

Production SwiftUI captures from [PR #17](https://github.com/kongdayan/wristbeam/pull/17), source commit `0ba238d311cabb3ae7050b91c7102baaf015e304`, [CI run 39543187105](https://github.com/kongdayan/wristbeam/actions/runs/39543187105).

Downloaded from the `native-interface-macos15` artifact and visually reviewed. Images are unchanged synthetic fixtures, with no account, private device or real health data. Disabled receive/refresh actions are intentional in preview mode. The fixture records a saved timestamp but does not create original FIT files, so its storage counter remains zero.

- Sync: status and action first, then Watch → Local → Cloud, local export, and collapsed settings/history/diagnostics.
- Empty search: explicit no-match explanation and Clear search action.
- Menu: Local only and Saved on this Mac; no cloud-login or pending-upload prompts.
- Activity list: stable cached records and a persistent search field.
- Narrow dashboard: 880 × 640 pt, 160% text; brand and navigation labels remain readable. Other main pages use 1020 × 768 pt and 115% text.

The ARM job passed 282 core checks, 53 developer integration checks, native list/detail and dashboard/detail scroll restoration, 282 XCTest cases, native rendering, signed packaging, isolated package localization/developer checks and 11 real-package updater checks. These images do not claim physical-watch pairing acceptance or live cloud activity downloads.
