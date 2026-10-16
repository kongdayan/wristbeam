# Local health storage

WristBeam retains original FIT files and original-resolution watch journals until
the user explicitly clears them. This change performs no destructive migration.

## Read model

`HealthHistoryReader` is the shared, network-free reader for dashboard restoration
and developer queries; CSV export uses the same streaming sample parser. A missing
file is empty history. Invalid records and unreadable files are reported separately,
while valid earlier records remain usable. No file-size cutoff silently removes a
large day. Future samples and day mismatches are excluded from returned series.

Completed days get a rebuildable `Telemetry/Index/YYYY-MM-DD.json` index. Its v1
envelope records the source file size, modification time and inode. A changed file
invalidates the index. Active days use in-memory snapshots after restoration so
API polling does not repeatedly scan the growing journal or continuously write
derived indexes. Original samples remain available for CSV export.

Account-scoped chart files use a v1 envelope and still accept legacy array files.
An unsupported/corrupt chart produces an issue, not a fabricated empty success.
Activity indexes use schema version 2, retaining the previous fields and adding
history anchors; older indexes without anchors continue from the existing cursor.
Cloud account/region boundaries remain enforced. Named credentials have a separate
private v1 store and are excluded from health exports.

## Failure behavior

Journal writes retain pending samples, retry up to three times, and report failures
to the app. A bounded 4096-sample memory buffer prevents unbounded memory growth;
overflow remains an explicit error rather than a claim of successful storage.
**Retry local storage** retries buffered work and pending chart saves. A crash or
quit cannot preserve samples that the OS has refused to write; the app must not
describe those samples as durable. Original FIT reception has its own durable
archive and upload ledger.

## SQLite assessment

Keep the original FIT/journal archive and add rebuildable day indexes first.
The current read model is partitioned by day/account, with at most one display
sample per minute per metric. This keeps migrations reversible and avoids moving
the user's existing health archive during a reliability update.

SQLite becomes appropriate when cross-day filters, multiple devices or sustained
concurrent writers outgrow this partitioned index. Evaluate it using cold/warm
31-day query latency, startup latency, index size and write amplification. A future
SQLite index should remain derived from the immutable archive, migrate in a new
file, validate counts/hashes and swap atomically; it should never replace or delete
the original FIT files as part of migration.

## Verification

`ReliabilityTests` covers offline cold queries, shared export parsing, missing vs
corrupt history, legacy chart envelopes, freshness, cursor preservation, bounded
chart sampling and buffered write recovery. `ActivityCloudTests` additionally
exercises account/network changes and on-demand downloads. Native builds and test
execution run in GitHub Actions, with synthetic fixtures only.
