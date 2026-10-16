# Reliability and integration review

Scope: the user-approved review dated 2026-10-16. Changes are submitted in
[PR #11](https://github.com/kongdayan/wristbeam/pull/11). This work does not authorize
a release, version bump or local upgrade. Required PR checks gate readiness.

## Implementation acceptance

- [x] Shared history reader for dashboard, export and MCP, including offline cold start.
- [x] Record/sync time, age and current-state suitability; dated overnight HRV and unknown measurement times.
- [x] Independent recent/history pagination with insertion/deletion recovery.
- [x] Background API reads/decoding and lightweight activity availability checks.
- [x] Visible storage failures, bounded retry/recovery, missing/corrupt distinction.
- [x] Connection stages and contextual recovery, including wake and manual disconnect policy.
- [x] Unified received/saved/pending/confirmed/retry sync status.
- [x] Data-driven chart updates, pixel sampling preserving extrema/gaps, independent cursor.
- [x] Versioned local storage/indexes, legacy migration reads, SQLite decision and original FIT retention.
- [x] Named credentials, individual revocation, scopes, last access and UI management.
- [x] Date-bounded health summary REST/MCP/Python SDK and documented coverage semantics.
- [x] Dashboard/device/settings responsibilities and contextual error actions.
- [x] Tiered CI, verified same-commit artifact reuse and cancellation-aware aggregation.
- [x] Scenario regressions: offline restart, pagination refresh, blocked storage,
      wake negotiation, network loss, account/region changes and scoped access.
- [x] Extract history, synchronization and diagnostic responsibilities from AppModel;
      regenerate the optional Xcode project references.

## Verification evidence

- Runtime implementation: `693a4b0`. Native macOS 14 ARM, macOS 15 ARM and Intel
  jobs passed 191 XCTest cases, protocol/core regression, HTTP/TLS/MCP/SDK/Webhook
  integration, signed package and installed-language/update lifecycle checks.
  [PR run](https://github.com/kongdayan/wristbeam/actions/runs/38879854395).
- The same PR run's **Verify uploaded package provenance** job downloaded the real
  ARM/Intel artifacts and verified the GitHub digest, embedded source/run identity,
  package digest, version and architecture. Negative fixtures cover wrong hashes,
  source/run/version/architecture and unsafe ZIP members. A PR audit does not make
  its artifacts eligible for release: publishing still requires successful exact
  main-push CI.
- [Full matrix run](https://github.com/kongdayan/wristbeam/actions/runs/38879864731)
  covers macOS 14/15/26 ARM and macOS 15 Intel, including all three CodeQL languages.
  Consult its run conclusion; a green subset is not a complete matrix result.
- Synthetic native renders from `693a4b0` were reviewed: Chinese/light Developer
  and Sync pages, English/dark Devices, English/light Dashboard and the Detailed
  floating panel at 160% text scale. Connection state is above setup help, client
  permissions have consistent padding, HRV shows its date, and enlarged floating
  text is not clipped. The harness renders both languages/themes; Intel compiles
  views because hosted Intel VMs have no usable rendering GPU.
- Documentation/project-reference updates and additional SDK summary transport
  assertions follow the runtime commit. The [current PR checks](https://github.com/kongdayan/wristbeam/pull/11/checks)
  are authoritative for the latest head; the above observations remain tied to the
  commit that produced them. No native builds or tests ran on the user's Mac.

### Performance measurements

Synthetic macOS 15 XCTest observations (debug builds on hosted runners, not a
real-device latency guarantee):

| Operation | Earlier `156f9bf` | `693a4b0` |
| --- | ---: | ---: |
| Cold read, 10,000 journal samples | 3.92 s | 0.75 s |
| Indexed read of the same day | 1.95 ms | 2.23 ms |
| Plot sampling, 86,400 source points at 300 px | 171 ms | 114 ms |
| 1,000 original-series cursor queries | 7.14 ms | 2.92 ms |

The rendered series has 2,348 points, retains extrema and gap segmentation, and
leaves all 86,400 source points intact. Reusing date parsers removes most cold-read
overhead. Indexed readings vary by runner and should be interpreted as roughly
1–2 ms, not as a guaranteed improvement at sub-millisecond precision.

## Boundaries and follow-up acceptance

Physical watch sleep/wake and adopting/revoking real client keys still require
installation and device acceptance. This PR uses synthetic protocol and loopback
fixtures and does not modify the installed app, real accounts or keys. No release
was triggered to test reuse; the real artifact download/audit and negative trust
fixtures cover that path without publishing.

The local archive remains original FIT plus journals, with rebuildable day indexes;
SQLite is assessed in [Local storage](LOCAL-STORAGE.md), not introduced prematurely.
See [API contract](developer/API.md) and [delivery workflow](RELEASING.md).
