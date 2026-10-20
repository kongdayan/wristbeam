# Connect IQ on Mac

The Connect IQ page separates store listings, local packages, installed watch faces and device-confirmed controls.

## Store and local library

Sign in and select a registered watch. Search by name or keyword, browse download history or popular faces, or paste an official store URL/application UUID to open a specific listing. Keyword results use relevance ordering, the selected watch's device/part-number filters, and paginated cards. New queries and account/device changes invalidate older requests; duplicate results are removed. Icons and screenshots use Garmin's public regional media endpoints without account credentials. A listing's latest version and download history do not prove installation or current use.

Keyword search follows the supplied Store APK's `sr9.b` / `vs9` request: `GET appstore/api/v2/asm/apps/keywords`, with `keywords`, `sortType=mostRelevant`, `filterType=ALL`, `appType=watchface`, locale, country, selected unit, page index and page size, plus the part-number header. Endpoint/parameter evidence is static APK analysis; regression tests use synthetic responses and do not establish live search results on every regional service.

**Download to Mac** saves into `~/Downloads/WristBeam/ConnectIQ/<app-UUID>/`:

- the unchanged server program payload (`<name>.iqpkg`);
- `metadata.json`, with public store information and a SHA-256 checksum;
- the icon and screenshots in their original image formats.

`.iqpkg` is WristBeam's label for an opaque response, not a Garmin-defined container or an assertion that renaming it to `.prg` makes it sideloadable. An existing queue file can differ from the latest store version. Metadata therefore does not claim a verified package version. Filenames and IDs are validated; program/metadata/image writes are atomic. Failed image downloads retain the program and record their individual states.

Garmin exposes program files through its device installation queue. Download confirmation explains that creating this task can also cause installation on a later Garmin sync. Cancelling the local download does not cancel an already accepted task. Downloading does not purchase an application, acknowledge/delete the queue entry, or automatically switch the current face.

## Read installed faces

**Read watch faces** first queries Smart extension 3, `GetInstalledAppsRequest(WATCH_FACE=3)`. It reads the actual names, store IDs, file sizes and available storage from the connected watch. Disabled/favorite flags are not current-selection indicators. Store details can be unavailable for a sideloaded or removed application.

WristBeam separately queries realtime settings (Smart extension 42, composition 36361) for firmware that offers a switchable grid. Empty replies do not erase the installed list. Grid writes use freshly validated device-returned indexes and require acknowledgement plus selection readback.

## Install and open

Installation is a separate explicit action. Before a transfer, WristBeam verifies the saved package checksum, account/device selection and compatibility. It reads the matching cloud task and re-downloads its payload for a checksum comparison, obtaining the authentic task identifier without creating another task. The identifier stays in memory.

The official installer sends the complete payload as datatype `0xff`, identifier `11 00 00`. GFDI create/upload/data messages provide file allocation, resume offsets, cumulative CRCs and acknowledgements. Explicit installation continues even when the UUID already exists: an inventory entry does not prove that its version or bytes match the selected package, and must not suppress an update or reinstall. Transfer completion is not sufficient evidence of installation: the target UUID must appear in a subsequent device inventory. This confirms acknowledged transfer and inventory presence, not a byte-for-byte readback or package-version comparison. The operation does not delete another watch face.

**Open on watch** uses the separate Connect IQ SDK Bluetooth channel. The SDK application UUID differs from the public store UUID. WristBeam obtains it from the entry section of a checksum-verified local program, binding the outer store UUID to the selected inventory entry. Unknown formats and ambiguous entries are rejected. Download the package first when no local identity is available.

After checking the selected entry against the same watch's installed inventory, WristBeam sends command 6 with the runtime UUID, matching the official Android `openApplication` flow. The separate installation-status action uses read-only command 5. Device status 0 means a prompt was displayed; status 3 means the app is already running. Neither an outgoing packet nor a displayed prompt is labelled as a verified screen change. Firmware can reject a watch face or require confirmation on the watch.

The read-only MCP/API does not gain write operations. Local runtime diagnostics expose public installed-app fields and operation status, not queue identifiers or credentials.

## Configure an installed face

The installed-face row has a **Settings** action. It uses the installed internal version and the selected watch's part number, rather than the latest store version. The watch must be connected and idle, and the selected cloud device must match its inventory.

The Android application renders Garmin's hosted editor. WristBeam follows that same sequence:

1. Read the current properties using Smart extension 4 and the **store UUID**. A successful Get response is only a status; actual values arrive in an independent device-initiated Send request. Both must arrive, and WristBeam acknowledges the push.
2. Decode the bounded Monkey C properties container and POST its complete JSON as `userSettings` to the regional `/{locale}/appSettings2/android/{app}/versions/{installed-version}/devices/{part}/edit` endpoint.
3. Display the official HTML in an ephemeral WebKit session. The native Save action calls `handleFormSubmit()`; validation failures remain in the editor. `handleBack()` handles nested groups before the native discard prompt. The hosted form supplies the declared controls, grouped pages and growable lists.
4. POST the complete returned JSON to the matching `/appSettings2/{app}/versions/{installed-version}/devices/{part}/binary` endpoint. Neither editor nor serializer receives the account Bearer token.
5. Re-read the watch's properties to detect concurrent changes, send the serialized settings through extension 4, require the device's save acknowledgement, then read back and compare typed values. Only that final comparison produces a verified-save status.

The editor preserves unknown and hidden properties. Defaults from the program package are not a substitute for a successful current-settings read. Settings and any developer-specific keys remain in memory; they are not added to the downloaded library, diagnostics or repository. As in the Android application, the current properties are sent to Garmin's regional editor and serializer.

Cancellation, device/account changes and disconnects invalidate the editor operation. Navigation is confined to the same application's official settings route, with a bounded resource allowlist; there is no general JavaScript-to-native bridge. Save failures retain the editor and describe the result as unverified, since a lost acknowledgement can occur after a device write.

## Evidence

| Operation | Supplied Android evidence |
|---|---|
| Store auth/history/catalog | Store `rl7/mg2/pu4`, `j80/cz/zka`: existing DI Bearer plus `APPSTORE_MOBILE` |
| Public images | Store `hla/o72`: regional `/appstore/api/icons/{UUID}`; screenshot endpoint verified with public GET |
| Installation task | Store `an5`: `apps/{appId}/install` with device, part number and internal version |
| Package delivery | Store `is6/i33/aua/fta/gta`: matching `install_app` task; regional Connect API relative URLs |
| Whole-file program upload | Store `wc2`, `udb`, `ud6`, `iy9`, `sha`, `wa3`: unmodified file, datatype/subtype, create/upload/data payloads and CRC |
| Installed inventory | `GDIConnectIQInstalledAppsExtension=3`, `p13`, ConnectIQRequestManager |
| SDK opening | Connect `df2/h`, `ef2/a,b,r,s,v`, `ConnectIQ/IQMessageReceiver` |
| SDK identity | Garmin's [Android SDK documentation](https://developer.garmin.com/connect-iq/articles/core-topics/Mobile_SDK_for_Android.html) distinguishes application IDs from store IDs; the original [ciqdb entry parser](https://github.com/pzl/ciqdb/blob/master/entries.go) describes the PRG entry UUID layout, corroborated by the live version query below |
| Realtime grid | Connect `ow1/c`, `wt2/d`, `nu2/i1`; generated realtime-settings descriptors |
| Settings editor and submission | Store `v70`, `nb2`, `qe`, `rm`: WebView POST, `handleFormSubmit()` and `handleBack()` |
| Settings serialization | Store `x60`, `a10`, `f70`, `ho8`, `vb8`: version/device-specific binary endpoint with the no-auth HTTP client |
| Settings device transfer | Smart extension 4 generated descriptors; Store `f70/c70`: store UUID, Get status plus independent Send push, Set status |
| Properties binary | Store `d55`, `ahc`, `sh2`, `u27`: string/object sections and breadth-first container encoding |

Protocol declarations establish message structure; successful physical-device behavior is recorded separately below. Credentials, device identifiers, personal responses and original program packages are not part of the repository.

## Local trial evidence — 2026-10-20

The user requested a local trial with no commits, pushes or release, overriding the normal Actions-only build workflow. The debug bundle is `dist/WristBeam.app`; `/Applications/WristBeam.app` is preserved.

Observed with the China account and Instinct 2 Solar:

- History, popular listings, details, icons and screenshots rendered in the real app.
- Tactical Elite VX (China) downloaded successfully: 48,624 program bytes, one icon, five screenshots and metadata. The saved checksum matches the queued device package.
- The installed inventory returned four watch faces and about 842 KB available storage. Tactical Elite VX was absent before installation.
- The explicit installation action transferred the complete 48,624-byte package over Bluetooth. The watch subsequently returned five installed faces, including Tactical Elite (internal version 32), with about 793 KB available. A separate manual inventory refresh confirmed the same result.
- The user confirmed that the watch screen displayed Tactical Elite after installation. This establishes the observed install-and-display result for this device; it does not establish a general current-face query or selection behavior for other firmware.
- Querying the store UUID over the SDK incorrectly returned not installed. The program's entry UUID returned installed version 32, matching the watch inventory. This confirmed the identity distinction on the physical device.
- After restarting the final local bundle, reading the watch restored the verified package identity without opening its detail page first. **Open on watch** using that runtime identity returned SDK status 3 (already running), matching the user's screen confirmation. This verifies the open command and correlation, but a transition from another active face is a separate test.
- Realtime composition 36361 returned an empty protobuf response. This does not identify the current face or establish that other device controls are unavailable.

Build, packaged localization, code signature, source/catalog checks and standalone protocol/package-identity smoke checks passed for the tested bundle. The XCTest target cannot compile with this Mac's Command Line Tools because `XCTest` is absent; its suite has not passed locally. International accounts and other firmware have not been tested.

### Settings implementation validation

The settings-enabled local debug bundle builds and passes signature verification, repository checks and localization checks (1,378 keys). Standalone protocol smoke checks cover nested Monkey C values, malformed inputs, the public 584-byte default-properties fixture, extension-4 identity correlation and push acknowledgement. The official Tactical Elite editor returned HTML successfully with its expected redirect/session flow. Its serializer returned HTTP 200 and a 464-byte binary from 29 public default fields; the implemented codec decoded all 29 keys and passed a semantic round trip. The three external editor resources were reachable, Bootstrap's integrity hash matched, and embedded icon fonts are allowed. These checks do not establish a successful device settings write. Physical-device read/edit/save verification is still pending while the watch connection is unavailable; no settings have been written during this validation.

### Local layout refinement

The catalog now uses adaptive rounded cards, larger artwork, grouped search/device controls and subtle hover/press feedback that respects reduced motion. Installed-face actions are separated from their metadata. Detail download/install actions remain outside the scrolling content; both the detail viewport and settings WebView have rounded clipping.

Catalog tabs reuse loaded results. Detail presentation follows explicit user actions, so a late response cannot reopen a dismissed sheet. Invalid lookup feedback appears next to the search field and clears when the input changes.

The updated local bundle passed build, signature, repository and packaged localization checks (1,382 keys). Real-app checks covered history/recommendation switching, Tactical Elite details, scrolling with fixed actions, Escape dismissal, and invalid-query/clear feedback. No download, install or watch-settings write was performed for this visual validation.
