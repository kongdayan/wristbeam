# Watch weather

In **Device → Connection → Watch weather**, select a source, find and select a city or press **Use current location**, then enable weather sync. Location permission is requested only by that button. The selected location persists locally; location is not continually tracked. Weather updates every 15 minutes while the watch protocol is connected. **Update and send** resends the current cache, fetching it when older than 15 minutes.

## Sources and privacy

- **Open-Meteo**: separately opt-in, no Garmin account. Selected coordinates are sent only to `https://api.open-meteo.com/v1/forecast`. Current conditions, hourly and five-day forecasts; no alerts. Requests carry no Garmin tokens, device identifiers or health readings. [Data by Open-Meteo](https://open-meteo.com/), [API documentation](https://open-meteo.com/en/docs), [terms](https://open-meteo.com/en/terms). The free endpoint is for non-commercial use; data attribution is required under CC BY 4.0. Commercial distributions need a suitable service agreement/provider. Attribution also appears in the weather settings.
- **Device cloud account**: China/international Garmin weather service, using the corresponding existing account. Turning Garmin cloud access off cancels and prevents these requests. Weather entitlement can differ from health sync; a weather failure does not itself log out the healthy Connect session. Current-account probe during implementation returned 401; this is not claimed as a verified working weather entitlement. Optional section failures remain unavailable, not fabricated zeros or all-clear alerts.
- No automatic source fallback. Weather is off by default. City lookup/reverse geocoding uses Apple's Core Location geocoder only following a user action. A local-only Garmin configuration may independently opt into Open-Meteo; fully offline operation cannot retrieve new weather.
- Snapshots are held in memory, cleared on source/location/account changes. Only source, enabled flag and selected location persist. Coordinates and weather response bodies are excluded from application runtime diagnostics, MCP and webhooks. Private watch-request capture still stores no payload or location.

## Watch protocol

An independent implementation based on the supplied APK's weather and FIT descriptors. Enabled/configured service advertises capabilities 26/27; changing the switch updates negotiation. Known 5014 requests are acknowledged with data-available, current/forecast groups and a 300-second timeout. Format 0 is supported; other formats are rejected. The format constant is corroborated by a community synthetic fixture, not yet by this user's watch traffic.

FIT global message 128 represents conditions (locals 6 current, 9 hourly, 10 daily); 129 represents alerts (local 5). GFDI 5011 carries definition records and 5012 data records. There is no FIT file header/trailer. Each frame requires both outer GFDI success and FIT status 0 before advancing. Missing measurements use FIT invalid values. UTF-8 strings, arrays, coordinates and numeric ranges are bounded. Disconnect, source changes and disabling weather cancel remaining work; old completions cannot resume it. Existing file receiving and health subscriptions remain independent.

Requests can read the fresh cache; enabling/manual refresh also attempts delivery without waiting for a 5014 request. Watch ACK proves protocol acceptance, not successful display on a particular face. Third-party Connect IQ faces using their own HTTP weather service require a separate communications implementation.

## Validation

Build and test exclusively in GitHub Actions. Synthetic coverage includes current/hourly/daily/alert parsing, unit/icon/date conversion, missing values, exact FIT byte fixtures, capability negotiation, serial ACKs, errors, bounded retry, disable/disconnect cancellation, old-log compatibility and credential-free Open-Meteo transport. Live weather-page and target-face display must be checked separately after installing the GitHub release.

`--refresh-weather` asks the running app to refresh/resend using its existing settings; it does not enable weather, change a location, grant permission or connect Bluetooth.
