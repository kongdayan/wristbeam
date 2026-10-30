# Connect IQ control review — 2026-10-29

## Scope and evidence

Read-only review of existing JADX output for Connect IQ Android 2.50 (1036), base APK SHA-256 `044f56960881e8247beb582b2dbc2ca7f9d16ed60cf3c44132ee3a5e59a00030`, and Garmin Connect China 5.29.0.1, APK SHA-256 `375816b02dec1845813edad2b2222d0412b834a515c6d179ae4073b2412dc1e1`. Both hashes were checked locally. REA Android inspection was unavailable because its JADX provider was not configured; findings below come from ordinary source reads, not new REA evidence. Existing decompilation has incomplete methods, so negative searches are bounded to the inspected paths.

## Installed-face UI in Connect IQ Store

`connectIQ/analysis/base/sources/defpackage/iq5.java:190–193,302–309` builds Update/Settings/Install actions from installed state. `z20.java:17–19,70–89` defines Share/Uninstall/Enter promo code menu actions. No current-face selector was found on this ordinary installed-app details path. The Apply string in `jc.java:1335–1336` applies a promo code. This does not establish behavior of all Store versions, iOS or other firmware.

## Actual selection path in Garmin Connect

Sources relative to `garmin/analysis/jadx/sources/`:

- `ow1/c.java:293–304`: tapping a watch-face-grid item passes the device-provided row and index through WATCH_FACE_GRID.
- `wt2/d.java:41–48`: invokes the realtime-settings handler.
- `nu2/i1.java:304–332`: builds SettingsChangeRequest with compositionId, rowId and watchFaceGridValueChange.index.
- `com/garmin/proto/generated/GDIRealtimeSettingsProto.java:50640`: grid value-change field 16. WATCH_FACE_SETTINGS composition ID is 36361 (line 67792).
- `ru2/c.java:91–135`: chooses REQUEST_RESPONSE or NOTIFICATION transport for composition reads.
- `pu2/d.java:120–175`: direct-response handling; `pu2/b.java:106–136`: notification mode sends then waits for an event.
- `nu2/i1.java:649–685`: accepts incoming Smart realtime-settings CompositionResponse, SettingsResponse and SettingsChangeResponse through onProtobufRequest.
- `jr2/d.java:590–605`: the notification transport sends message 5043.

The grid uses device-returned indexes, not arbitrary installed store UUIDs. Whether this device exposes a grid and whether its entries include third-party CIQ faces remain runtime questions.

## Launch commands are different

The tested SDK command 6 is openApplication; its status 1 means no prompt was shown. It is not a selection acknowledgement. The GFDI LaunchApp candidate is also not sufficient evidence: the inspected real call in `com/garmin/android/apps/connectmobile/connectiq/ConnectIQAppDetailsActivity.java:277–290` uses MEDIA_SYNC_CONFIGURATION for a music app. No normal-mode watch-face selection call was found in the inspected call sites.

## Gap in WristBeam

At review time, `GFDISession.readWatchFaceGrid` only consumed direct query results, and `receiveProtobufNotification` had no RTS dispatch. This established an implementation gap, not device incompatibility.

The follow-up implementation first sends the official StartUpDataRequest once per connection, then accepts RTS 5043 notifications alongside direct 5044 responses. RTS locale tags use the official underscore form (zh_CN/en_US), independently of the hosted editor's hyphenated tags. The startup probe does not assert a consent country. Empty startup data falls back to the grid read; communication responses are still accepted through either mode. It serializes operations, matches response kind and composition ID, assembles bounded interleaved fragments, acknowledges notifications without inventing a 5044 application reply, and ignores cached duplicate notification IDs. An empty direct reply leaves the query pending under its original 25-second deadline. Retired query IDs consume late direct responses without advancing a newer operation. Disconnect resets correlation and fragment state. Notification write acknowledgements still require a fresh selection readback before success.

RTS notifications do not echo the initiating query ID. Composition responses and settings values can be checked against the expected composition; a status-only change response cannot independently identify the target. Serialized preflight and readback remain necessary. No write uses guessed indexes or a store UUID as a grid index.

296 core tests pass, including empty-reply/notification ordering, wrong phase/composition, fragmented and duplicate events, late direct replies, timeout, and successful and unsuccessful selection readback. Live validation remains separate from these synthetic protocol tests.

The earlier live SDK test returned no-prompt status; it did not test the RTS selection path. An initial read-only notification-capture attempt could not reproduce a refresh because computer-use could not locate the main window; capture was stopped. After implementing notification reception, a live read obtained 11 installed faces, then a zero-byte direct RTS reply and no incoming 5043 request during the bounded wait. This did not provide switchable choices. The subsequent initialization/locale refinement is validated separately below.

## Editing properties is a separate operation

Store sources under `connectIQ/analysis/base/sources/defpackage/`:

- `p7.java:198`, `g70.java:29–41`, `t70.java:76–79`: handleFormSubmit, then Android-specific JSON-string unquoting. WKWebView already returns a String, so that extra unquoting is unnecessary on macOS.
- `a10.java:83–87`, `x60.java:9`: POST JSON to the regional appSettings2 binary endpoint with installed version and device part number.
- `c70.java:46–82`: SaveAppSettingsRequest uses the store app UUID and serialized binary, then checks SaveAppSettingsResponse.SUCCESS. No before/after reread is present in this inspected official save flow.
- `b70.java:60–64`, `d70.java:35–52`, `z60.java:30–38`: read completion follows an independent SendAppSettingsRequest; empty properties become JSON {}.

WristBeam additionally waits for Get acknowledgement and performs before/after rereads. Those are extra verification requirements, not evidence of the official sequence. A push-only response could expose a separate compatibility gap; no current save-failure trace has established that case.

## Conclusion

The earlier blanket claim that the watch cannot be switched remotely was too strong. What is established is that the former SDK-based button used the wrong semantics, and the RTS implementation is incomplete relative to Garmin Connect. Further device validation must distinguish selecting a different face from saving changes to the active face, capture incoming RTS notifications, and use only fresh device-provided controls for any write.

## Live validation after initialization and locale correction

The installed final local build read 11 installed faces. The startup response contained 37 bytes and reported communication mode 0 (REQUEST_RESPONSE). Subsequent WATCH_FACE_SETTINGS reads with underscore locale returned zero-byte direct data. No RTS notification supplied switchable choices during the bounded wait, and the UI recovered after timeout. A second read also supplied no choices. No selection write was sent; actual remote selection remains unverified and unavailable for this session. This does not establish incompatibility of every model, firmware or other device-specific control path.

A separate read-only check of Retro settings reported an unparseable properties container. Its cause has not been established; no save was attempted. Captures were disabled after validation.

## Properties parsing repair

A read-only device capture of the failing installed-face configuration contained a 136-byte string table and a declared 183-byte object area, followed by one zero byte. The original Swift decoder required the declared area to consume all remaining bytes and rejected this otherwise valid payload. Official `d55.h:2429–2433` slices only the declared area and ignores the trailer.

The decoder now bounds a separate reader to that area and ignores bytes after it. The same private capture decoded successfully to 17 properties and valid JSON. Synthetic wire tests cover zero padding, other trailer bytes, truncated scalars at the declared boundary, and oversized declarations; 297 core tests pass. The temporary raw-capture instrumentation was removed from the final build. No configuration values or original capture are included in this report or repository.

The installed repaired build successfully opened the previously failing native/tactical watch-face editor, displayed 15 form controls and enabled Save. Verification was read-only: no property changes or save were performed.

Retro's post-repair device check could not be completed because the native window became unavailable to computer-use. Its successful load is not claimed. The temporary private capture was moved to Trash after offline verification; raw capture is not enabled in the installed final build.
# Capability-check wait repair (2026-10-30)

RTS startup communication mode is now retained for the current connection. For
explicit direct mode (0), a completed empty response finishes the operation
immediately, preserving the installed inventory and releasing the settings
actions. Notification mode (1) and unknown mode retain the bounded notification
wait. A startup failure ends the capability check rather than starting another
25-second query; an invalidated device also finishes the busy state. Connection
reset clears the negotiated mode.

Local core validation: 299 tests passed, including direct-mode empty response,
retry, startup timeout, and existing notification matching/readback tests. The
previous installed build's runtime state eventually reported inventory loaded
with no switch options; the long wait did not establish switching support.


## User acceptance — 2026-10-30

After the capability-check repair was installed locally, the user confirmed that
watch-face settings could be modified on the physical watch. This validates the
settings flow, not selection of a different active watch face.
