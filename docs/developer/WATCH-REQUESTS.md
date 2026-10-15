# Watch request diagnostics

In **Device → Connection → Watch request diagnostics**, start a ten-minute capture, then open weather on the watch or switch watch faces. You can start before connecting to include the handshake. Stop and export to inspect the local JSON file. Starting a new capture replaces the previous log; export/copy it first to keep multiple sessions.

The installed executable also accepts:

```sh
/Applications/WristBeam.app/Contents/MacOS/GarminPulse --capture-watch-requests
/Applications/WristBeam.app/Contents/MacOS/GarminPulse --stop-watch-capture
/Applications/WristBeam.app/Contents/MacOS/GarminPulse --status
```

Commands require the app to be running. They do not start Bluetooth, grant permissions, reconnect, or enable cloud access. The status output includes `watchRequestCaptureActive`, `watchRequestCaptureEvents`, and `watchRequestCaptureStorageError`.

The capture file is `~/Library/Application Support/GarminPulse/Diagnostics/watch-requests.json` (the application retains its original data-directory name). It is saved with mode 0600 in a private directory, updated at most once per second during capture, and never sent through cloud sync, the developer API, MCP or webhooks. Export reveals this file in Finder. Restarting retains the last log but does not resume capture.

## Schema version 2

- `startedAt`, `stoppedAt`: ISO-8601 timestamps. If the app restarts after an interrupted capture, the in-memory stop time denotes recovery, not a verified disconnection time.
- `totalEvents`: retained-category events seen during this capture; the latest 300 are stored in `events`. The UI displays the latest 30.
- `omittedRoutineMessages`: routine messages omitted from the individual event list. New captures retain their type counts in `routineCategories`, so these messages are no longer invisible.
- `routineCategories[]`: aggregate of each `(direction, number, replyTo)` combination with `count` and `lastSeen`. Contains only these five fields, no payload or payload length. The array is capped at 128 categories; further unseen categories increment `unclassifiedRoutineMessages`, while existing category counters continue updating. Categories have stable protocol keys and the UI displays direction, type, count and last observed time.
- Version 1 files remain readable. Their previous omitted total cannot be reconstructed; the UI explicitly reports the historical, unclassified remainder. New observations add categories without assigning types to historical messages. Saving produces version 2. Restore rejects excessive/duplicate categories and inconsistent totals.
- `events[].direction`: `watchToMac` for a decoded incoming frame; `macQueued` when the app queues an outgoing frame. Queueing does not establish delivery or watch acknowledgement.
- `number`, `payloadBytes`: GFDI message number and payload length.
- `replyTo`, `status`: only the target message ID and status of a GFDI acknowledgement. Status 0 means ACK; 2 means unknown/not supported.
- `weatherFormat`, `forecastHours`, `weatherPayloadValid`: only for weather request 5014. The known ten-byte layout carries format at offset 0 and requested hours at offset 9. Coordinates at offsets 1–8 are discarded. Different payload lengths are reported without guessing their fields.
- `id`, `time`: local event sequence and timestamp. No watch identifier is retained.

Known labels cover weather request 5014, weather-alert message 5015, FIT definition/data 5011/5012, notification messages 5033–5036, music messages 5041/5042/5049, generic protobuf request 5043, capability negotiation 5050 and time request 5052. Unknown message numbers remain visible with metadata only. A weather-alert label does not imply that the watch requested a specific alert; its payload is not decoded. Protobuf service content is not parsed in this version.

The routine category labels come from the APK GFDI message-name mapping (`ir2/c.java`) and the implemented session handlers:

| Number | Meaning |
| --- | --- |
| 5000 | Protocol acknowledgement; `replyTo` distinguishes its target |
| 5001 | Generic message query |
| 5002 / 5003 | File download / upload request |
| 5004 / 5054 | Standard / compressed file data |
| 5005 / 5006 | Create / delete file |
| 5007 / 5008 | Directory filter / set file flags |
| 5009 | File-ready notification |
| 5022 | Cancel file transfer |
| 5023 / 5024 | Battery status / device information |
| 5027 | Queued-download notification |
| 5044 / 5045 | Protobuf response / cancel protobuf transfer |

**Incoming does not mean watch-initiated.** A file block, battery status or acknowledgement can be the watch answering a Mac request. In particular, 5044 may carry identity, battery or other protobuf services; the diagnostic does not decode it or claim which service was used. A 5000 acknowledgement is displayed as a reply to its target, not a new request. An ACK for a non-routine message remains in the individual event list. Categorization does not enable any file-creation/deletion action or new protocol response.

This is a passive application-level diagnostic, not an over-the-air Bluetooth sniffer. It observes CRC-valid GFDI frames delivered to WristBeam, after stream reassembly. It does not capture another phone's connection, raw GATT/realtime streams or all on-watch actions. It cannot identify which watch face initiated a request. No raw payload, coordinate, URL, notification text, account token, device identity, FIT content or health reading is written.

Capture itself does not advertise weather capabilities or change responses. Weather configuration is separate from diagnostics. A watch may not issue requests when the companion has not negotiated the capability. An empty capture does not prove that a watch face has no weather dependency. Opening weather or switching faces may also use cached data without making a request.

## Validation

GitHub Actions runs regressions for weather-field redaction, unknown/authentication payload omission, malformed lengths, bounded retention under file-transfer traffic, fragmented frame decoding and CRC rejection, unchanged unsupported responses when weather is disabled, opt-in persistence, timeout, restart and file permissions. Category regressions cover version 1 restoration, direction and ACK-target separation, totals, adversarial message IDs, payload privacy and rejection of oversized/duplicate/inconsistent category files. Real watch observations must be reported separately from these synthetic tests. Never commit a personal capture to the repository.
