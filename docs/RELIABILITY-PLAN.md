# Reliability and integration review

Scope: the user-approved review dated 2026-10-16. Changes ship through a reviewed
PR and GitHub Actions. This work does not authorize a release or local upgrade.

## Acceptance ledger

- [ ] One history reader for dashboard, export and MCP, including offline cold start.
- [ ] Record time, sync time, age and current-state suitability; dated overnight HRV.
- [ ] Independent recent/history pagination with insertion/deletion recovery.
- [ ] Background API reads and decoding; lightweight activity availability index.
- [ ] Visible storage failures, bounded retry, recovery, missing/corrupt distinction.
- [ ] Connection stages and contextual recovery, including sleep/wake.
- [ ] Unified received/saved/pending/confirmed/retry sync status.
- [ ] Data-driven chart updates, pixel sampling preserving extrema and gaps, independent cursor.
- [ ] Versioned local storage/index migrations; document SQLite decision; retain FIT.
- [ ] Named API credentials, individual revocation, scopes, last access and UI management.
- [ ] Date-bounded health summary API, MCP, SDK and documentation with data coverage.
- [ ] Clear dashboard/device/settings responsibilities and contextual error actions.
- [ ] Tiered CI and same-commit verified artifact reuse; cancelled checks remain cancelled.
- [ ] Scenario regression: offline restart, pagination refresh, disk failure, wake,
      network loss and account changes.
- [ ] Separate history/storage/sync/presentation responsibilities from AppModel.
- [ ] Actions tests, render review, performance evidence, PR and documentation complete.

## Evidence

Implementation and validation evidence will be recorded here as each item lands.
Unchecked items remain required; a passing subset does not complete this scope.

### First implementation passes

- `c150f2d`: shared local history, initial freshness/pagination/storage recovery.
- `ec906cc`: scoped credentials, summaries, connection/sync presentation, chart sampling,
  history extraction from AppModel. Actions run 38876299134 passed the macOS 14 and
  macOS 15 ARM jobs (core, HTTP/MCP, rendering, XCTest, signed package lifecycle).
  Intel, macOS 26 and Swift CodeQL were still running at this observation.
- Reviewed synthetic Chinese/light developer and sync screens and English/dark device
  screen from that run; client-management padding is improved in the next revision.
- Subsequent work adds date-index invalidation, unknown measurement timestamps,
  release reuse checks, scenario regression and API/storage documentation. These
  revisions require a new complete Actions run; earlier green jobs do not validate them.
