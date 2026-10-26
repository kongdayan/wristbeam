# WristBeam experience improvement — 2026-10-26

## Scope and delivery

Improve the macOS SwiftUI companion across navigation, onboarding, readings, feedback, motion, loading, task flows, image rendering and downloaded resources. Keep accounts, preferences, health history and original watch files intact. Use local commits, no PR, no release/version bump or installed-app replacement. Compilation, executable tests and native rendering run only in GitHub Actions. Local verification is limited to source/catalog analysis and inspection of downloaded synthetic artifacts. The installed release is a baseline, not evidence of the edited source.

## Review and direction

The product serves people who want to glance at watch readings while working, and inspect a workout without having to understand Bluetooth or cloud implementation. Its signature is the quiet daily trace alongside each reading. Keep native controls, system typography, a restrained green accent and an opaque reading surface. Remove decorative gradients/shadows on every metric card; spend visual emphasis on current readings and actionable status.

Source review findings (not measured runtime claims):

- High: the first-run guide presents watch pairing, cloud account and sync as numbered prerequisites, although local watch use and cloud history are independent. Offer those two entry paths with contextual follow-through.
- High: activity list has no empty/search-result states and blocks detail/export behind one undifferentiated busy flag. Make operation context explicit, preserve cached content, support cancellation and prevent cancelled/account-switched work from committing results.
- High: downloaded activity exports have no inventory, storage size or reversible removal. Add an account-scoped download manager, with clear offline availability and Trash recovery; preserve the index and original received FIT files.
- Medium: cards use layered gradients, thin low-opacity strokes and individual shadows. Use a common opaque surface and semantic border, with a visible keyboard focus and hover affordance.
- Medium: refresh disables an icon with no activity feedback; export and image failures can be silent or modal. Keep status near the initiating action and allow retry.
- Medium: compact layouts, large text, keyboard interaction and accessibility settings need explicit paths. Let card columns fit available width; preserve labels, focus, optional motion and opaque surfaces.

References read from the installed apple-design skill:

- `accessibility.md > Vision`: “Convey information with more than color alone.” Label status and icon controls; use contrast-aware borders and readable text.
- `layout.md > Visual hierarchy`: “Use progressive disclosure to make layouts cleaner and easier to interact with.” Hide troubleshooting and low-frequency settings until needed.
- `typography.md > Supporting Dynamic Type`: “Keep text truncation to a minimum as font size increases.” Prefer wrapping, adaptive columns and stacked actions.
- `color.md > Best practices`: prefer system-defined colors and verify custom palette contrast.
- `designing-for-macos.md`: familiar controls, keyboard navigation and resizable windows.
- `loading.md > Best practices`: preserve useful content while loading and explain waiting.
- `feedback.md > Best practices`: “Consider integrating status feedback into your interface.”
- `progress-indicators.md > Best practices`: “When it’s feasible, let people halt processing.” Use determinate progress only when byte totals are known.
- `motion.md > Best practices`: “Make motion optional.” No looping decorative animation; respect Reduce Motion.
- `onboarding.md > Best practices`: “Teach through interactivity.” Optional paths rather than a mandatory tutorial.

## Compact design system

System SF for controls/body; rounded SF only for readings; monospaced digits for numbers/timestamps. Requested point scale: 27 title, 17 section, 13 body, 12 supporting, 11 caption. Reading size follows existing card preference. Semantic system label/secondary label and separator follow appearance and increased contrast. Custom palette roles (light/dark) and computed contrast are recorded below after implementation.

Regular layout:

```text
[sidebar] [Health dashboard              Watch / Cloud]
          [refresh status             Share / Display]
          [key readings, fitted columns             ]
          [other metric groups                      ]
```

Compact / large-text layout:

```text
[hideable sidebar] [Health dashboard]
                   [Watch / Cloud]
                   [status]
                   [actions wrap]
                   [cards fit available width]
```

Motion: a short 0.16 s surface highlight/disclosure transition, disabled by Reduce Motion. Keep changing readings and charts stable rather than animating incoming health samples.

## Implementation and verification ledger

In progress. Record changed flows, static checks, CI run/commit identity, synthetic artifact review and remaining limits here. No claim of completion until all requested areas have evidence.

## Palette evidence (computed from source RGB, WCAG luminance)

| Role | Light | Dark |
| --- | --- | --- |
| background | #F2F7F6 | #111417 |
| surface | #FFFFFF | #1B1F22 |
| accent | #146E4C | #8AF0BF |
| onAccent | #FFFFFF | #000000 |

Accent on card surface: 6.27:1 light; 12.10:1 dark.
Button label on accent: 6.27:1 light; 15.26:1 dark.
Semantic label, secondary label and separator are resolved by macOS and are not assigned invented fixed contrast figures here. Increased contrast strengthens card boundaries; the content is opaque and custom motion checks Reduce Motion.

## Implemented, awaiting CI evidence

- Native resizable/hideable split-view sidebar, keyboard navigation and application menus; wrapping action layout.
- Optional watch/cloud entry paths and less prominent troubleshooting details.
- Width-aware metric columns, key readings before category sections, preserved custom order and explicit focus/hover.
- Workout loading, cancellation, offline and empty/search states, visible pagination, sport labels/icons and locale-aware wall-time formatting.
- Account-scoped download inventory and sizes; symlink/filename filtering; Finder reveal and confirmed recoverable Trash actions.
- Detail reads, export-file reads, PNG encoding and file writes moved away from the UI actor where appropriate. Save destination is selected before a workout export download.
- Image generation debounce, cancellation guards, inline failure/retry, cached PNG output and save/copy feedback.
- Actual update download bytes, determinate progress and cancellation; failed/cancelled staging cleanup. No updater was invoked locally.
- Sync/export activity feedback, ordinary device copy without peripheral identifiers and labeled floating controls.
- Chinese/English catalog coverage and source/repository checks pass locally. New behavior regression tests and synthetic render cases are prepared for Actions; no local Swift compilation or executable test ran.

## Delivery boundary

Use a dedicated validation branch for GitHub Actions, without a PR or merge. Retain commits locally. No release workflow, release tag, version bump, installed application change, private data upload or foreground verification. Existing unrelated AGENTS.md and social drafts are excluded from commits.

## Follow-up source review

- Preserve a saved custom dashboard order as one grid; category grouping is the default only when no custom order exists. This keeps drag/reorder actions honest.
- Bind the displayed workout detail to the cache revision so account changes cannot briefly display an old cached detail for a reused activity ID.
- Tag update progress callbacks with the request identity; late callbacks cannot update a newer download. Repository edits are disabled during check/install.
- Add keyboard cursor inspection and accessible values to workout charts; label date-navigation controls and settings controls.
- Remove the redundant device-platform card, tuck manual device identifiers under a disclosure, add reading origin labels, and use the current date in the dashboard subtitle.
- Keep existing appearance preferences as a deliberate compatibility/personalization choice; new surfaces still follow system semantic colors and accessibility settings.

First validation: [Actions run for e15944a](https://github.com/kongdayan/wristbeam/actions/runs/40307141672). Quality/catalog/repository/secret analysis passed; native matrix was still running when this entry was written. Follow-up changes require a new exact-commit run.

## Loading and data semantics follow-up

The official sign-in web view now exposes navigation activity and reload, with Escape to close. Connection diagnostics sit behind an explicit disclosure. Sync status shows active transfer/upload work. A source audit found region-name presentation rebuilding cloud samples without preserving `timestampIsMeasurement`; the refresh now retains that flag, with a fixture-based refresh regression so a sync timestamp is not advertised as a measurement time. No service contract or stored health values are changed.

Storage scans are coalesced while running and show activity. Update installation waits for workout downloads, cache management and local exports as well as watch/cloud file transfer. Workout online availability is published even when the same account cache is retained in local-only mode, keeping controls in sync with network policy. PNG encoding uses a bounded autorelease lifetime.

## Synthetic artifact review — d8b8db1

Downloaded the `native-interface-macos15` artifact from run 40307676004 to a temporary review directory; no bundle was installed. Inspected Chinese/dark dashboard; English/light compact dashboard at 160%; English/light downloads, activities and devices; English/dark onboarding and detailed floating panel at 160%; and the share sheet.

Findings corrected from that evidence:

- The sidebar brand wrapped its last letter at 160% scale. Keep it on one line and scale only that brand label to fit.
- The normal-width dashboard unnecessarily reduced a preferred three-card row to two. Card minimum widths now use the standard 115% text baseline; 160%/narrow windows still reduce columns for readability.
- The standalone share sheet capture exposed a transparent root surface (black against a transparent PNG viewer) and its fixture captured before asynchronous preview generation. Give the real sheet an opaque theme surface, wait for the image task in the fixture and assert background alpha. The separate share-canvas rendering checks remain in place.

The other inspected views retained readable labels, no clipped controls, contextual offline states and complete floating-panel content. These observations are limited to synthetic render artifacts; keyboard interactions and live sign-in were not performed on the user's desktop.
