# Menu bar quick overview

The menu bar window supports a quick glance at selected health readings and a route into the main window. It uses the existing SwiftUI/AppKit visual language and a native transient NSPopover.

- Show connection and battery status separately from each reading's source and recorded time. Disconnected or expired readings retain their last finite value with a visible old-reading label. Missing or future-dated values show a dash.
- Prefer Body Battery, heart rate, stress and steps within the user's existing selection. Show four metrics without scrolling and link overflow to the dashboard. Keep the current metric-selection preferences.
- Click a metric to open its detail at the record's date; route through the main-window handler so the popover closes first. Keep Open Dashboard and Show/Hide Panel in fixed footer positions.
- Put metric selection, Receive Watch Files, Sync Records, Settings and Quit in a native actions menu. Disable file reception while the channel is unavailable or another watch operation is in flight.
- Show storage/sync status inline and an indeterminate progress indicator during transfer. Closing the window does not cancel operations. Opening it starts no sync or upload.
- Show MCP status only when configured or running; link to Developer integrations without displaying credentials or connection details.
- Support Escape through SwiftUI and AppKit's responder chain; outside clicks and the menu bar icon use the native transient/toggle behavior.

Local verification covers 40 synthetic-data renders: Chinese/English, light/dark, 160% text, disconnected cached values, missing readings, empty selection, overflow enabled-but-stopped MCP, combined large-text/cloud/MCP state, storage error and long values. Layout records assert that controls stay inside the viewport and metric rows remain aligned. Native mouse/key events verify metric details, dashboard routing, panel toggling and Escape. The fixture asserts zero cloud requests, no Bluetooth session and no MCP listener.

The Dev bundle is explicitly marked with `WristBeamDevelopmentBuild`, shown beside the product name. The local build defaults to one Universal package; the CLT fallback assembles its two slices within one script and validates the final signed app. Public release metadata is unchanged. Local installation backs up the existing app/data and moves the superseded bundle to Trash while preserving preferences and health files.

References: Apple HIG [Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers), [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar), [Layout](https://developer.apple.com/design/human-interface-guidelines/layout), [Typography](https://developer.apple.com/design/human-interface-guidelines/typography).
