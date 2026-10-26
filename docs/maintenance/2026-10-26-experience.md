# WristBeam experience improvement — 2026-10-26

## Current baseline and delivery

The authoritative baseline is `be6d897` on main, which already contains the released 0.3.10 source, Connect IQ, independent preferences, browsing/scroll restoration, full-width disclosure controls and scoped CI. This work preserves those features and the existing version. The installed `/Applications/WristBeam.app` reports 0.3.10; it has not been replaced or upgraded.

The initial prototype started from the stale local 0.3.7 checkout (`712f577`). That was corrected after comparing the installed version with remote main. Prototype commits remain on `codex/experience-2026-10-26` and `backup/experience-before-main-2026-10-26`, with a local Git bundle backup. Their CI runs and image reviews are historical development evidence, not acceptance of the current application. Current work is integrated on `codex/experience-main-2026-10-26` using current main's architecture and interaction regressions.

No PR, main merge, release workflow, release tag, version bump or local application installation is authorized by this development work. Only isolated validation branches are pushed for Actions. Build, executable tests, signing and native rendering run in GitHub Actions. Local work consists of editing, static checks, project-reference generation and downloaded-artifact review. Foreground computer use stopped when requested. User AGENTS.md changes and social drafts are preserved separately and excluded from app commits.

## Review and direction

WristBeam helps people glance at watch readings while working and inspect saved workouts. Its defining element is the quiet daily trace beside a reading. Keep native navigation, system typography, opaque reading surfaces and a restrained green accent. Preserve the main application's five destinations, independent preferences, Go menu shortcuts, list search/page state and per-detail scroll restoration.

Current-main source review findings and fixes:

- High: workout cache/export copies lacked inventory and reversible management. Add an account-scoped download sheet with formats, byte counts, Finder reveal and confirmed Trash movement. Revalidate directory/file identity at action time. Preserve the index, credentials, preferences, health history and received original FIT files.
- High: Connect IQ previews used default AsyncImage downloading/decoding without explicit process memory accounting. Reuse the cookie-free, redirect-allowlisted, size-bounded artwork loader, downsample off the UI actor and cache thumbnails by URL/resolution. Reject corrupt or excessive image dimensions before decoding.
- Medium: region-source presentation rebuilt cloud samples without retaining the unknown-measurement-time flag. Preserve timestamp semantics and label origins plus sync/record/overnight times for VoiceOver.
- Medium: workout export downloaded before choosing a save destination and performed file reads/writes on the UI actor. Choose the destination first; cancel without a download; move reads/writes off the UI actor and show inline outcomes.
- Medium: first-run guidance favored a watch-first sequence. Offer independent live-watch and cloud-history paths; retain context-specific pairing help and permission timing.
- Medium: refresh, image generation, sign-in navigation, export and storage scans need visible local feedback. Add activity/cancel/retry states while preserving usable cached content. Coalesce storage scans.
- Medium: narrow/large-text headers can compress controls. Fit card columns and wrap independent actions while preserving existing grouped/flat layout preferences and native click targets. Add stronger semantic boundaries in increased contrast.

What already works and is retained: independent Preferences, Command-1…5/Command-[ /Command-F/Command-R routing and sheet gating, account-scoped browsing context, wide clickable disclosure headers, Connect IQ task/install validation, local/cloud workflow interpretation and optional automatic upload. The current main's native interaction harness must continue proving these behaviors.

## Design system and references

SF system fonts for navigation/body; rounded SF for readings; monospaced digits for numeric values and timestamps. Requested sizes: 27 title, 17 section, 13 body, 12 supporting, 11 caption. Card sizing honors the standard 115% baseline and reduces columns when text is enlarged. A native split container provides the main sidebar; preferences remain a separate window.

| Role | Light | Dark |
| --- | --- | --- |
| Background | #F2F7F6 | #111417 |
| Card surface | #FFFFFF | #1B1F22 |
| Accent | #146E4C | #8AF0BF |
| Accent label | #FFFFFF | #000000 |

Source RGB calculations: accent on surface 6.27:1 light / 12.10:1 dark; button label on accent 6.27:1 light / 15.26:1 dark. System label, secondary-label and separator colors are resolved by macOS; fixed contrast figures are not invented for them. Increased contrast strengthens card borders. Existing short hover/press transitions respect Reduce Motion; no continuously animated readings or decorative loading were added. The floating panel respects Reduce Transparency.

References read from the installed apple-design skill:

- `accessibility.md > Vision`: “Convey information with more than color alone.”
- `layout.md > Visual hierarchy`: “Use progressive disclosure to make layouts cleaner and easier to interact with.”
- `typography.md > Supporting Dynamic Type`: “Keep text truncation to a minimum as font size increases.”
- `color.md > Best practices`: use system colors and verify custom color contrast.
- `designing-for-macos.md > Best practices`: resizable windows, familiar commands and keyboard navigation.
- `loading.md > Best practices`: preserve useful content while loading.
- `feedback.md > Best practices`: “Consider integrating status feedback into your interface.”
- `progress-indicators.md > Best practices`: “When it’s feasible, let people halt processing.”
- `motion.md > Best practices`: “Make motion optional.”
- `onboarding.md > Best practices`: “Teach through interactivity.”

The existing app-specific appearance preference is retained as a deliberate compatibility/personalization choice. New content surfaces still use semantic colors and accessibility settings.

## Implementation coverage

| Requested area | Implementation and acceptance evidence |
| --- | --- |
| UI/navigation | Native split container, adaptive columns/actions, semantic card borders; Connect IQ and independent preferences retained. Reviewed normal three-column and narrow 160% single-column dashboards, settings and activities. |
| Interaction | Native mouse click/disclosure, scroll/context restoration and shortcut/sheet gating regressions pass. Card values have consolidated accessibility descriptions; chart arrow inspection remains available. |
| Guidance | Independent watch/cloud onboarding; current pairing and permissions retained. Reviewed synthetic onboarding and device fixtures. |
| Data display | Origin labels, sync-versus-measurement timestamp preservation, localized sport labels and workout wall time. Refresh/presentation regressions pass. |
| Feedback | Inline image/export/cache notices, cancel/retry controls and operation descriptions. Native fixture captures cached, empty, offline and operation states. |
| Motion | Existing brief reduced-motion-aware control feedback retained. Custom content does not animate incoming health samples. |
| Loading/flows | Cached details remain available; cancel owned library work; sign-in reload/activity; choose destination before export. Owned-request cancel/retry and navigation regressions pass. |
| Images | Share PNG encoded once off UI actor, stale results suppressed, retry provided; opaque share sheet. Actual completed normal/160% previews reviewed. Native canvas and bounded thumbnail tests pass; Connect IQ empty-state render reviewed. |
| Downloads/resources | Account scope, inventory/sizes, checked file operations, reversible Trash, update byte progress/cancellation and failed staging cleanup. Synthetic Trash/restore, inventory and cancellation tests pass; downloads sheet reviewed. |
| Maintenance/delivery | Local commits, setup guidance and this record. Full matrix/security/package evidence below; final heading-only render follow-up tracked separately. No release/install. |

Connect IQ artwork limits: existing network loader caps encoded bytes at 16 MiB and permits only Garmin media endpoints; thumbnail input dimensions are at most 8192 per side and 20 million pixels. Display thumbnails are at most 1024 pixels per side. The process cache has an 80-image / 32 MiB cost target based on decoded row bytes, and can evict automatically. Cancellation prevents a reused cell from publishing an earlier image.

## Verified full validation

[Run 40315508544](https://github.com/kongdayan/wristbeam/actions/runs/40315508544) completed successfully for application/test source `d5475cf38452b90d4107ca1cc2493313cc3c04cb`, with full-validation, showcase and test-package enabled:

- macOS 14/15/26 Apple Silicon and macOS 15 Intel: each passed the 289-method core assertion harness and 289 native XCTest methods with zero failures. These are two executions of the same test set, not 578 distinct tests.
- Developer HTTP/TLS/MCP/SDK/webhook integration; native share rendering; all selected native settings/floating/interface checks; signed app/package and installed-language/update lifecycle regressions passed.
- Native mouse events cover disclosure labels/whitespace/chevrons, independent content, selection cells and disabled states. List/detail/dashboard scroll restoration, search/page retention, independent preferences and sheet/modal keyboard gating passed.
- Swift, Python and Actions CodeQL; source/localization/documentation checks; full-history secret scan; required CI gate passed.
- Provenance audit downloaded this run's artifacts and verified source commit, run identity, artifact hashes and package hashes.

New regressions cover fitted columns, regular-file/filename/symlink allowlists, real Trash/restore of a synthetic copy while preserving a synthetic index and original stand-in, unknown-measurement-time propagation through cloud refresh, owned-request cancel/retry and bounded artwork decoding. No executable test, Swift build, native render or application installation ran locally.

Downloaded synthetic artifacts were visually reviewed: normal grouped dashboard, narrow 160% dashboard, independent preferences, activity library, downloads, onboarding, Connect IQ and floating panel. The normal/160% share sheets display the completed image and full-width snapshot guidance. Cloud-request count remains zero in the interface fixture. Images contain isolated synthetic data only.

Verification boundary: the changed application has not been installed or exercised against the user's real watch/account. Native interactions and network/cancellation behavior are covered by isolated CI fixtures; the installed 0.3.10 app remains unchanged. Live sign-in, watch pairing and production Connect IQ artwork retrieval are therefore not newly accepted end-to-end flows in this maintenance task.

The preceding current-main run [40312543429](https://github.com/kongdayan/wristbeam/actions/runs/40312543429) also passed the full matrix for `9917545`. Its share capture exposed an opaque but still-loading preview and truncated guidance. Follow-up rendering waits for actual completion while yielding the main actor; the synchronous native click/scroll checks remain intact. The sheet has a full-width note and a shorter selection list at large text sizes.

| macOS 15 ARM interface fixture | `9917545` | `d5475cf` |
| --- | --- | --- |
| Compile elapsed | 56.061 s | 81.385 s |
| Render elapsed | 281.658 s | 50.047 s |
| Largest-child peak RSS | 2,314,027,008 bytes | 255,983,616 bytes |

The later fixture detaches/closes snapshot windows and uses a local bitmap autorelease pool. It also adds large-text completed-share scenarios. These are observed whole-fixture results on hosted runners, not controlled application benchmarks or normal app memory/speed claims.

Stale-base runs 40307141672, 40307676004, 40309089226 and 40309391444 remain historical and are not acceptance evidence. Grouped dashboard ordering retains main's existing first-three-highlights semantics and “Move to front” action. Finder reveal reconciles the active account; download-count wording avoids singular/plural ambiguity.

## Final heading-only follow-up

Visual review found that the English share-selection heading truncated at 160% despite the preview and guidance being complete. `ca22e9673d38cb00cac567d111ed2fd85bb3af94` adds one vertical fixed-size modifier so the heading can wrap. It is the only app/test source change after `d5475cf`.

[Run 40317295740](https://github.com/kongdayan/wristbeam/actions/runs/40317295740) completed successfully for that exact commit with showcase rendering enabled. The macOS 15 Apple Silicon core/XCTest, integration, native interface/share render, signed build and lifecycle checks passed, together with quality/secrets, all three CodeQL analyses and the required CI gate. Package upload/provenance was intentionally not selected for this heading-only follow-up; four-platform/package evidence remains the full run above.

Downloaded this follow-up's native artifact and reviewed English light/dark 160% share sheets: “Choose what to share” now wraps fully onto two lines, the rendered preview is complete, and selection controls, snapshot guidance and export actions remain visible. The same fixture reports 46.790 s rendering and 251,707,392 bytes largest-child peak RSS, with exit code zero.

Final local checks: 1,517 localization keys and placeholders, 417 public source/documentation files, and diff whitespace checks pass. App/test/scripts content after the validated `ca22e96` source commit is unchanged; the closing commit updates only this maintenance record. No PR exists for the validation branch. The version/configuration is unchanged from main, the latest public release remains v0.3.10, and the installed app still reports 0.3.10. The user's AGENTS.md changes, local skills/catalog and social drafts remain outside these commits.
