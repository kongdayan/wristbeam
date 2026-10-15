# WristBeam developer interface · v1

WristBeam exposes **read-only cached health data**, through a local MCP server and REST API. Enable it in **Settings → Developer**. This is an opt-in interface; installing or opening the app does not start a listener or send webhooks. macOS sleep or quitting the app stops access. No daemon or cloud relay is installed.

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

All tools advertise read-only/non-destructive/idempotent hints. `wristbeam://metrics` and `wristbeam://status` are JSON resources. `initialize`, `ping`, `tools/list`, `tools/call`, `resources/list`, `resources/read` and empty `resources/templates/list` are implemented. Unknown methods return -32601; invalid tool parameters return an `isError` tool result. Responses do not include account IDs, cloud tokens, device names/IDs, filenames, FIT bytes, logs or precise activity locations. There are no upload, refresh, pairing, deletion or setting-changing tools.

## REST

| Method and path | Parameters |
| --- | --- |
| `GET /api/v1/status` | none |
| `GET /api/v1/metrics` | none |
| `GET /api/v1/catalog` | none |
| `GET /api/v1/series` | `metric=heartRate&date=YYYY-MM-DD&offset=0&limit=1440` |
| `GET /api/v1/hrv` | optional `date=YYYY-MM-DD` |

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
