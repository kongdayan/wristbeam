# Daily navigation and sync

The dashboard grouping and guided device setup from #15 and #16 are integrated with the independent preferences window from #14. The follow-up targets `main` directly, so a merged stacked branch cannot leave these changes outside the shipped source tree.

- The sidebar, dashboard status, menu popover and sync center use one connection/storage/cloud presentation. Local-only mode shows saved data without asking for cloud login or uploads. A fresh empty store shows “Waiting for watch data”; storage failures take priority over a saved status.
- Activity search and pagination survive opening details. List and dashboard scroll offsets are independent from detail offsets. Details start at the top; Back returns to the previous list/card position. Preferences do not replace the main view. Browsing state stays in memory and activity context clears on account-scope changes.
- Activity empty states distinguish loading, local-only/no cache, signed out, no records, no search matches and request failures. Existing cached records remain visible during loading or errors.
- Sync records starts with status and primary actions, followed by Watch → Local → Cloud and local export. Automatic-sync settings, file tools/upload history, and diagnostics/logs are expandable secondary sections. Cloud upload actions appear only when cloud sync is enabled.
- Activity rows, navigation and metric cards share hover/focus feedback; Connect IQ and the new workflow actions share button styling. Back controls have consistent size and spacing.

## Keyboard navigation

Commands appear in the macOS **Go** menu. Actions that do not apply to the active main window are disabled; open sheets prevent navigation commands.

| Shortcut | Action |
|---|---|
| Command–1…5 | Dashboard, Activities, Connect IQ, Devices, Sync records |
| Command–[ | Return from metric or activity detail |
| Command–F | Focus search in the activity list |
| Command–R | Refresh the current dashboard/detail/activity page; receive data on Sync records |
| Command–comma | Open preferences |

## Regression coverage

`WorkflowTests` covers local/cloud/storage presentation, empty-state priority, search/pagination and account-scoped offset cleanup. `scripts/test-interface-render.py` checks actual native scroll positions through activity/detail and dashboard/detail transitions, and renders the production sync, menu and empty-search views in Chinese/English and light/dark modes with synthetic data. Build, native tests, package checks and rendering run in GitHub Actions.
