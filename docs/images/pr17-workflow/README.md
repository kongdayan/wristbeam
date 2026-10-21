# Daily workflow verification

Production SwiftUI captures from [PR #17](https://github.com/kongdayan/wristbeam/pull/17), source commit `4d762f4efd58c649d1c3a8d5c78018ead7fa2768`, [CI run 39545246634](https://github.com/kongdayan/wristbeam/actions/runs/39545246634).

Downloaded from the `native-interface-macos15` artifact and visually reviewed. Images are unchanged synthetic fixtures, with no account, private device or real health data. Disabled receive/refresh actions are intentional in preview mode. The fixture records a saved timestamp but does not create original FIT files, so its storage counter remains zero.

- Sync: status and action first, then Watch → Local → Cloud, local export, and collapsed settings/history/diagnostics.
- Empty search: explicit no-match explanation and Clear search action.
- Menu: Local only and Saved on this Mac; no cloud-login or pending-upload prompts.
- Activity list: stable cached records and a persistent search field.
- Narrow dashboard: 880 × 640 pt, 160% text; brand and navigation labels remain readable. Other main pages use 1020 × 768 pt and 115% text.

The native harness passed actual activity/list and dashboard/detail scroll restoration, retained search/page state, account-context cleanup, real sheet-parent/owner/modal keyboard gating and zero-network assertions. These images do not claim physical-watch pairing acceptance or live cloud activity downloads. Full build, package and security results are recorded in the linked CI run.
