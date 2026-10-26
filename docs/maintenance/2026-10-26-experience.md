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

| Requested area | Implementation and evidence to collect |
| --- | --- |
| UI/navigation | Native split container, adaptive columns/actions, semantic card borders; preserve Connect IQ and independent preferences. Inspect current-source renders. |
| Interaction | Existing native click/scroll/shortcut gating regressions, card accessibility and chart arrow inspection. No foreground keyboard interactions on the user's desktop. |
| Guidance | Independent watch/cloud onboarding; current pairing and permissions retained. Inspect onboarding/device fixtures. |
| Data display | Origin labels, sync-versus-measurement timestamp preservation, localized sport labels and workout wall time. Run refresh/presentation regressions. |
| Feedback | Inline image/export/cache notices, cancel/retry controls and operation descriptions. Inspect busy/empty/offline states. |
| Motion | Existing brief reduced-motion-aware control feedback retained. Custom content does not animate incoming health samples. |
| Loading/flows | Cached details remain available; cancel owned library work; sign-in reload/activity; choose destination before export. Run cancellation and navigation regressions. |
| Images | Encode share PNG once off UI actor, suppress stale results and provide retry; opaque share sheet. Connect IQ thumbnails are bounded and cached. Run native canvas/thumbnail tests and inspect share/Connect IQ fixtures. |
| Downloads/resources | Account scope, inventory/sizes, safe checked operations, reversible Trash, update byte progress/cancellation and failed staging cleanup. Run real synthetic Trash/restore, inventory and cancellation tests. |
| Maintenance/delivery | Local commits and this record; update setup guidance. Full exact-source validation pending; no release/install. |

Connect IQ artwork limits: existing network loader caps encoded bytes at 16 MiB and permits only Garmin media endpoints; thumbnail input dimensions are at most 8192 per side and 20 million pixels. Display thumbnails are at most 1024 pixels per side. The process cache has an 80-image / 32 MiB cost target based on decoded row bytes, and can evict automatically. Cancellation prevents a reused cell from publishing an earlier image.

## Verification status

The current-main integration requires its own complete Actions run and artifact review. Stale-base runs 40307141672, 40307676004, 40309089226 and 40309391444 were superseded/cancelled. They do not prove final readiness. Earlier synthetic review identified a wrapped sidebar brand and transparent share-sheet capture; the current integration retains main's one-line brand and an explicitly opaque share surface, with an alpha assertion and a fixture wait for asynchronous image generation.

Prepared regression coverage includes width-aware column counts, regular-file/filename/symlink allowlists, real Trash-and-restore of a synthetic copy while preserving a synthetic index and original stand-in, unknown-measurement-time propagation through cloud refresh, owned-request cancel/retry, bounded artwork thumbnail decoding and existing workflow/Connect IQ tests. No executable test or Swift compilation has run locally.

Append exact commit/run identity, terminal results, package provenance and current-source artifact findings before declaring completion.
