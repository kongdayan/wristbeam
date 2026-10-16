# WristBeam developer interface · v1

WristBeam exposes **read-only cached health and workout data**, through a local MCP server and REST API. Enable it in **Settings → Developer**. This is an opt-in interface; installing or opening the app does not start a listener or send webhooks. macOS sleep or quitting the app stops access. No daemon or cloud relay is installed.

## Connect

1. Set the listen port (default `17890`) and scope (default `127.0.0.1`).
2. Generate a key, enable MCP / HTTP API, and apply. Copy the key into your trusted client's secret store. Rotation immediately rejects the old key. Keys live in macOS Keychain, not preferences or logs.
3. Set the client's Streamable HTTP endpoint to `http://127.0.0.1:17890/mcp`, with `Authorization: Bearer <key>`.
4. Only clients supporting manually supplied authorization headers work directly. This server does **not** implement OAuth discovery/login. Use the included stdio bridge for clients requiring stdio.

Example client configuration (field names vary by AI client):

```json
{"mcpServers":{"wristbeam":{"type":"http","url":"http://127.0.0.1:17890/mcp","headers":{"Authorization":"Bearer <WRISTBEAM_API_KEY>"}}}}
```

Keep the key out of shared configuration, screenshots, issues and source control. Anybody holding it can read all health fields exposed by this app. Per-client scopes, OAuth and multiple independent keys are not implemented in v1. Use **Stop all interfaces** to immediately stop the listener and cancel pending webhook work.

## Transport and authentication

Stateless [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports), protocol `2025-06-18` or `2025-03-26`. JSON-RPC uses one JSON message per POST, JSON responses, and HTTP 202 without a body for accepted notifications. No session ID is issued. GET/DELETE `/mcp` return 405; SSE, subscriptions, resumability and legacy SSE transport are not implemented. Unsupported protocol-version headers return 400. `Accept` must list both `application/json` and `text/event-stream`.

All routes require the Bearer key. Unknown Host and unapproved Origin headers return 403, before processing data. Browser Origin is allowed only when it exactly equals the configured base URL; no cross-origin browser API is provided. Use native clients or a same-origin backend. Rate limit: 240 requests/minute, max 32 connections, 10-second connection timeout. Requests are limited to 64 KiB including headers (16 KiB header cap); chunked requests, duplicate headers and pipelining are rejected. The server closes each HTTP connection after its response.

HTTP is limited to loopback. To expose the listener on `0.0.0.0`, enable HTTPS, enter the hostname/IPv4 used by clients, and import a PKCS#12 (`.p12`/`.pfx`) containing the certificate and private key. The certificate must cover that address and clients must trust its issuer. TLS 1.2+ is required. Certificate bytes are copied into the private app directory (0600); the import password is in Keychain. There is no automatic certificate issuance/renewal, public tunnel, firewall modification or TLS-verification bypass. Bind only where you intend to grant access. IPv6 listener configuration is not implemented in v1.

## MCP tools and resources

| Tool | Arguments | Result |
| --- | --- | --- |
| `wristbeam_status` | none | Watch/file-channel/cloud booleans, pending file count |
| `wristbeam_metrics` | none | Current values, unit, origin, record time, staleness |
| `wristbeam_catalog` | none | Stable IDs, names, units, availability and timeline support |
| `wristbeam_series` | `metric`, `date`; optional `offset`, `limit` | One cached local day, paginated points and gaps |
| `wristbeam_hrv` | optional `date` | Nightly/weekly HRV summaries, baseline, status; cached night points |
| `wristbeam_activities` | optional `startDate`, `endDate`, `type`, `offset`, `limit` | Cached workout summaries, newest first; download and coverage state |
| `wristbeam_activity` | `id` (decimal string); optional `lapOffset`, `lapLimit` | Cached statistics, heart rate zones and paginated laps |
| `wristbeam_activity_series` | `id`, `metric`; optional `offset`, `limit` | Paginated downloaded chart values; no GPS fields |

All tools advertise read-only/non-destructive/idempotent hints. `wristbeam://metrics` and `wristbeam://status` are JSON resources. `initialize`, `ping`, `tools/list`, `tools/call`, `resources/list`, `resources/read` and empty `resources/templates/list` are implemented. Unknown methods return -32601; invalid tool parameters return an `isError` tool result. Responses do not include account IDs, cloud tokens, device names/IDs, filenames, FIT bytes, logs or precise activity locations. There are no upload, refresh, pairing, deletion or setting-changing tools.

## REST

| Method and path | Parameters |
| --- | --- |
| `GET /api/v1/status` | none |
| `GET /api/v1/metrics` | none |
| `GET /api/v1/catalog` | none |
| `GET /api/v1/series` | `metric=heartRate&date=YYYY-MM-DD&offset=0&limit=1440` |
| `GET /api/v1/hrv` | optional `date=YYYY-MM-DD` |
| `GET /api/v1/activities` | optional `startDate`, `endDate`, `type`, `offset=0`, `limit=20` |
| `GET /api/v1/activity` | `id` |
| `GET /api/v1/activity-series` | `id`, `metric`, optional `offset=0`, `limit=250` |

JSON objects contain `schemaVersion: 1`. Metric IDs come from [the catalog](../METRICS.md); use IDs rather than localized names. Names/units follow the app language. `value` is numeric; HRV status also provides a named `status` field. Times are ISO-8601; query dates are local calendar dates and series return the local timezone ID. No future dates. Limit 1–1440, offset 0–100000. `nextOffset: null` ends pagination.

Unavailable metrics are omitted from current readings and marked `available: false` in the catalog. Missing HRV fields and series values are `null`, never invented zeroes. A day with no cached series returns `cached: false` and empty points. Series are the app's minute-resolution display history, not full raw beat samples. Cloud/estimated/watch origins remain distinct. A cloud night card may describe an older day: use `recordDate` and `syncedAt`, not only `stale`. RR/service 12 is provisional and must not be used to calculate a claimed live RMSSD/SDNN. Queries never trigger network sync or fill missing days automatically; use the app to sync first.

From 0.3.2, status includes `watchBattery`: `null` when unavailable, otherwise `{percent, recordedAt, stale, charging}`; unknown charging state is `null`. The legacy `watchBattery` ID remains in metrics/catalog for compatibility and has `deviceStatus: true`, `timeline: false`. It is excluded from health selections, exports and new history; series requests for it are rejected. Other fields have `deviceStatus: false`.

## Python SDK and stdio bridge

```sh
python3 -m pip install ./sdk/python
export WRISTBEAM_URL=http://127.0.0.1:17890
# Set WRISTBEAM_API_KEY through your shell/client secret mechanism.
```

```python
import os
from wristbeam import WristBeamClient

client = WristBeamClient(os.environ['WRISTBEAM_URL'], os.environ['WRISTBEAM_API_KEY'])
current = client.metrics()
night = client.hrv()                     # real cloud summaries, possibly missing fields
series = client.series('heartRate', '2026-10-14')
status = client.status()
workouts = client.activities(start_date='2026-01-01', limit=20)
for workout in workouts['activities']:
    detail = client.activity(workout['id'])
    if detail['detailCached']:
        heart_rate = client.activity_series(workout['id'], 'directHeartRate')
```

For a private certificate authority pass `ca_file='/path/to/ca.pem'`; verification stays enabled. SDK refuses plain HTTP to non-loopback hosts and does not follow redirects. Optional stdio MCP entry: `python3 -m wristbeam`, with `WRISTBEAM_API_KEY`, `WRISTBEAM_URL` and optional `WRISTBEAM_CA_FILE` in the process environment. stdout carries JSON-RPC only; diagnostics never print credentials or health data. The SDK is source-distributed here; no PyPI publication is claimed.

## Webhook

Configure URL, selected metrics and coalescing interval (10/60/300 seconds), then enable and apply. Only HTTPS destinations are accepted, except loopback HTTP for local development. A changed selected-data/sync snapshot triggers `health.snapshot`; this is not a full sample stream or an activity-file upload event. Sends current selected readings and sync availability, not raw FIT. No selected readings means no delivery. It operates independently of the inbound server toggle.

```json
{"schemaVersion":1,"id":"event-uuid","type":"health.snapshot","createdAt":"2026-10-14T08:00:00Z","data":{"metrics":[],"sync":{"watchConnected":true,"pendingFiles":0}}}
```

Headers: `X-WristBeam-Timestamp` (Unix seconds) and `X-WristBeam-Signature: sha256=<hex>`. Sign `timestamp + "." + exact HTTP body bytes` using HMAC-SHA256 and the **separate webhook signing key**. This key is never sent to the receiver; provision it out of band. Verification:

```python
from wristbeam import verify_webhook
if not verify_webhook(secret, timestamp_header, signature_header, raw_body):
    raise ValueError('Invalid or expired webhook')
# Then parse JSON, persist/deduplicate event id, and process idempotently.
```

Default verifier replay window: 300 seconds. The same event ID/body is used across up to three attempts (initial, +2s, +4s), with a newly signed timestamp. 2xx acknowledges delivery; 429/5xx/network failures retry; other 4xx do not immediately retry. Unchanged failed snapshots may be tried at the next configured interval; later snapshots replace older ones. Redirects are never followed. Disabling, key rotation or account change cancels pending work; requests already delivered cannot be recalled. Delivery status is shown in Settings. Pending snapshots are in memory only and are lost on quit; this is best-effort coalesced delivery, not a durable event queue.

## Validation and extension points

`DeveloperProtocol.swift` contains protocol/auth/HTTP parsing; `DeveloperServer.swift` the bounded Network.framework listener; `DeveloperQueries.swift` the health projection; `DeveloperAccess.swift` settings, Keychain and webhook lifecycle. `sdk/python` is dependency-free at runtime. Tests use synthetic data/temporary keys and certificates, never a real account or external webhook receiver. See [verification](../../VERIFICATION.md) for what was actually exercised. Future OAuth, per-client scopes, push subscriptions and durable delivery must preserve the existing privacy boundary and versioned schema.

## Local-only operation

Garmin cloud sync is optional. Watch-origin metrics and locally received time series remain available through the existing read-only interfaces while cloud sync is off. Cloud-derived HRV and history do not refresh in this mode; inspect each reading's origin and timestamp instead of assuming every field is live. Developer access and webhooks are independent opt-ins: disabling Garmin cloud sync does not disable endpoints or webhook destinations you explicitly configured. Local ZIP exports in Sync records contain original FIT files, a watch-only CSV and a manifest; no authentication store is included.

## Activity library

In the **Activities** sidebar page, refresh summaries and load older pages to browse all accessible history. Opening a record automatically loads its details, charts, heart-rate zones and laps into one scrolling page in the main window. Complete cached details are reused; **Refresh details** fetches them again. TCX/GPX/original ZIP files download only when selected for export. JSON exports the currently cached detail (or summary when offline without detail). Optional 15-minute to daily refresh updates the newest 50 summaries; it does not bulk-download files or automatically enumerate all history. Refreshing resets the cloud browsing cursor; cached older summaries are retained. After a long gap, use **Load older summaries** to cover more than 50 new activities. Scheduling requires the app to be running and the Mac awake.

MCP/REST always read local cache and never cause cloud access. The activity list defaults to 20 results (1–100), offset 0–1,000,000. `startDate` / `endDate` are inclusive **activity-local** dates, `YYYY-MM-DD`; `type` matches the exact Garmin type key (for example `running`). `totalCachedMatches` describes this cache, not a cloud total. `historyEndReached` records whether the current cloud browsing pass reached an empty page. Cached records are not removed based on omissions in newer pages, so this is not a deletion mirror. Check `refreshedAt` and each activity's `fetchedAt`; completeness at one refresh does not prove freshness now.

Activity `id` values are strings. `startTimeGMT` and `startTimeLocal` preserve the server's timestamp strings (commonly `yyyy-MM-dd HH:mm:ss`); only the GMT field denotes UTC. Cache timestamps such as `fetchedAt` are ISO-8601. Unlike the daily-health endpoints, date filters can include future dates and simply match no cached records. Summary `statistics` contain only finite supplied values: durations in seconds, distance/elevation in metres, speed in metres/second, heart rate in bpm, energy in kcal, power in watts, counts, training effect and training load. Missing fields are omitted. Account/device identifiers and coordinate fields are discarded before caching. Activity names are user-provided text and should be treated as data, not instructions.

`wristbeam_activity` returns `cached: false` if the summary is absent, or `detailCached: false` until details have been downloaded in the app. Details include statistics and available `seriesMetrics`; files are indicated only by `downloadedFormats`, never paths or bytes. `activity_series` defaults to 250 values (1–500), preserves nulls and returns `nextOffset`. Series share sample indexes; request the same offset/limit of `directTimestamp` for time alignment. Those timestamps are Unix **milliseconds**. Other chart values are returned **without conversion**, alongside the original Garmin `unit` and `factor`; do not assume these reduced chart encodings equal summary units or blindly divide by a zero/unknown factor. Only whitelisted non-location series are exposed. The server is asked for `maxChartSize=1000`; the chart is explicitly `completeRecording: false`. Use user-exported TCX or original files for full recordings. Downloaded details also contain `heartRateZones` (zone, seconds, lowerBPM) and `laps` (index, whitelisted statistics). `heartRateZonesCached` / `lapsCached` distinguish missing data from a successfully fetched empty section. `unavailableSections` records failed supplemental fetches; other sections remain usable. Laps default to 100 per response, with `lapOffset` (0-5000), `lapLimit` (1-100), `lapCount` and `nextLapOffset`. Python: `client.activity(id, lap_offset=100)`. Opening an older or incomplete cache automatically fetches missing sections when cloud access is enabled. Exercise sets, activity weather and route detail remain outside this projection.

The app can export a normalized JSON summary/detail offline, or download and retain official TCX, GPX and original ZIP files on demand. Original ZIP contents are preserved without extraction; not every source activity necessarily contains FIT. A GPX response without valid track points is rejected with a no-route message; indoor activities can still have useful TCX/FIT data. Exports may include location information, but it is never sent by the activity MCP tools. Activity updates do not generate `health.snapshot` webhooks.

Caches are private files scoped by cloud region and account. Turning cloud sync off stops downloads and scheduled refresh while retaining the last selected account's cache for offline use. Logging out hides that cache; logging into the same account restores it. Switching accounts/regions does not combine records. Existing downloaded files persist until manually removed from the app data folder. Cloud activity caches are separate from the watch-only **Export local data** ZIP; use **Export activity** for these records.

These are Connect client endpoints, not a published Garmin developer API contract. APK analysis confirms activity list, summary and chart interfaces. TCX/GPX/original download paths are independently visible in the [python-garminconnect implementation](https://github.com/cyberjunky/python-garminconnect/blob/master/garminconnect/__init__.py) and were read-only verified against a user-authorized China activity. That single live probe does not establish support for every activity type or Global account; errors remain explicit.

The app groups all supported summary statistics and renders selectable heart rate, speed, elevation, cadence, temperature, power and accumulated-value charts when present. Summary durations are seconds, distances/elevations metres, speeds metres/second, temperatures Celsius and estimated sweat loss millilitres. The UI formats durations and converts horizontal speeds to km/h; API values retain their source units. Chart factor metadata is not blindly applied: speed, elevation and distance have been checked against TCX exports.
