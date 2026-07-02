# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Two Control4 DriverWorks drivers (Lua + XML) that control TP-Link Kasa devices via the **Kasa Cloud API**:

- **Light driver** (`driver.xml` / `driver.lua` → `kasa_cloud_switch.c4z`) — one instance per physical device. Controls the `light_v2` proxy (binding 5001).
- **Account driver** (`account.xml` / `account.lua` → `kasa_account.c4z`) — a DriverWorks **combo self-proxy device** (like Control4's `generic_http` sample): `<combo>true</combo>` + `<proxies><proxy>kasa_account</proxy></proxies>` as direct children of `<devicedata>` (after `<config>`), NO `<connections>`. Added once to any room via System Design → Search. Holds the Kasa credentials, logs in, publishes the token + device list.
  - **Why combo self-proxy:** a driver needs a proxy (or connection) to be searchable/room-addable — a truly blank driver won't appear in Composer's driver search. The self-proxy name can be the driver's own name; it does NOT need to be a Control4-registered proxy (`generic_http` self-proxies as `generic_http`).
  - **NOT an agent:** adding `<agent>true</agent>` made Composer reject the `.c4z` as "invalid file" (agent proxies have stricter requirements). Do not add the agent tag.

### Shared-credential architecture

Credentials live only on the account driver. Discovery is **by name** (no binding required):

- Account driver creates variables **3001** (token) and **3002** (device-list JSON) via `C4:AddVariable` in `OnDriverInit`, and publishes to them with `C4:SetVariable` after login / device-list fetch.
- Light driver finds the account with `C4:GetDevices({})`, matching `driverFileName` containing `kasa_account` or `deviceName == "TP-Link Kasa Account"`; retries every 10s (timer `2`) until found (light may load first). Then `C4:RegisterVariableListener(accountId, 3001/3002)`.
- Light reads the token with `C4:GetDeviceVariable(accountId, 3001)`. On auth failure it queues the request, calls `C4:SendToDevice(accountId, "RELOGIN", {})`, and flushes the queue when `OnWatchedVariableChanged` delivers the new token.
- **Composer setup:** add ONE *TP-Link Kasa Account* device (any room), enter credentials; add light drivers anywhere — they self-discover by name. Per-light you only pick the device from the dropdown.

### Device-list dropdown

The account driver caches the full device list (from `getDeviceList`) into variable ID **3002** as compact JSON (`{a=alias, i=id, t=IOT|SMART, d=dimmer, m=model, u=appServerUrl}`), Base64-decoding SMART aliases and stripping commas. The light driver reads it and calls `C4:UpdatePropertyList("Select Device From List", "label1,label2,...")` to fill a `DYNAMIC_LIST` property. Selecting an entry (`OnPropertyChanged`) auto-fills **Device ID / Device Type / Is Dimmer** via `C4:UpdateProperty`. The account driver's "Refresh Device List" action re-fetches; the list also refreshes on each login.

### Per-device endpoint (appServerUrl) — error -20571

Kasa homes each device on a **regional cloud** returned as `appServerUrl` in `getDeviceList` (e.g. `use1-wap`, `aps1-wap`, `eu-wap`). Passthrough control MUST go to that per-device URL — hitting the wrong region returns **`error_code -20571` ("device offline")** even when the device is online in the app. The account driver caches `appServerUrl` as `u` in the 3002 list; the light driver's `ResolveAppServer()` matches its `Device ID` against the cached list and posts passthrough to `g_appServerUrl` (falling back to the hardcoded `API_URL = use1-wap` only if unresolved). After upgrading, the account driver must re-fetch the list (re-login or **Refresh Device List**) so the `u` field is populated.

**KLAP devices (KS205 / KS225) are dead on the cloud — controlled via LOCAL KLAP instead.** On this account every KS205/KS225 comes back from `getDeviceList` with **`status=0`** (offline in the *legacy* cloud) while all HS-series + KS230 + KP405 return `status=1` and work. These newer switches moved to TP-Link's **SMART/KLAP** protocol and no longer maintain a legacy-cloud connection, so `passthrough` returns `-20571` regardless of endpoint/token/schema. It is **not** a region bug (all were `use1-wap`, `sameRegion=true`). The account driver logs a one-line `err()` warning per offline SMART device. **The driver now speaks KLAP locally** (see below) so these devices ARE controllable — set their LAN IP.

### Local KLAP transport (KlapV2) — native, no bridge

For SMART devices with a **`Local IP (KLAP)`** property set, the light driver talks the encrypted **KlapV2** protocol directly to the device on the LAN (port 80) instead of the cloud. Routing: `UseKlap() = (Device Type == "SMART" and Local IP ~= "")`; everything else keeps the cloud passthrough. The SMART `Build*()` payloads (`get_device_info` / `set_device_info`) are reused verbatim as the inner KLAP request — only the transport differs.

- **Auth hash** — `auth_hash = SHA256(SHA1(user)..SHA1(pass))` is computed once by the **account driver** and published as hex on shared variable **3003**; the light driver reads it (never sees the plaintext password), `hexToRaw`s it into `g_klapAuthHash`, and re-handshakes whenever it changes.
- **Handshake** — `POST /app/handshake1` (16-byte `local_seed`) → `remote_seed(16)+server_hash(32)` + `Set-Cookie: TP_SESSIONID` (the `TIMEOUT` cookie is dropped); verify `SHA256(local_seed..remote_seed..auth_hash)==server_hash`. `POST /app/handshake2` = `SHA256(remote_seed..local_seed..auth_hash)`. Then derive `key=SHA256("lsk"..)[1..16]`, `sig=SHA256("ldk"..)[1..28]`, `iv=SHA256("iv"..)[1..12]`, `seq=signedBE(SHA256("iv"..)[29..32])`.
- **Request** — `seq++`; `iv_seq=iv..packBE32(seq)`; `ct=AES128CBC(key,iv_seq,pkcs7(json))`; body=`SHA256(sig..packBE32(seq)..ct)..ct`; `POST /app/request?seq=<seq>` with the session cookie. Response = `sig(32)..ct` → AES-decrypt → `{"error_code":0,"result":{device_on,brightness}}`. HTTP **403** ⇒ session expired: clear `g_klap`, re-handshake once, retry.
- **Crypto** uses `C4:Hash`/`C4:Encrypt`/`C4:Decrypt` (all `*_encoding="NONE"` for raw bytes, `padding=false` — PKCS7 done in Lua). BE32 (un)packing is arithmetic (no `string.pack`) so it runs on Lua 5.1 and 5.3. `randBytes` derives the seed from hashed `os.time`/`os.clock`/`math.random`.
- Only **KlapV2** is implemented (KS205/KS225). If `server_hash` never matches, the device may be KlapV1 (MD5-based) — not yet supported.
- **Prereq:** the device needs a reserved LAN IP entered in `Local IP (KLAP)`. `getDeviceList` does not return the local IP, so it's manual (UDP-20002 discovery is a possible future add).

## C4 API notes

- `C4:urlPost(url, body, headers, bFailOnHttpError, callback)` — the 4th argument **must be a boolean** (`false`), not `nil`. Passing `nil` throws `bFailOnHttpError should be a boolean`.
- The callback `function(strError, strData, nCode, tHeaders)` — `strError` is a **numeric ticket ID** (1, 2, 3…) not a string. Check `type(strError) == "string" and strError ~= ""` before treating it as an error; numeric values are harmless internal request handles.
- `C4:TableToJson` / `C4:JsonToTable` do not exist in this OS version — the driver uses its own pure-Lua JSON encoder/decoder.

## light_v2 proxy state feedback (OS3.3+)

The `light_v2` (LIGHT_V2) proxy **only** accepts the new Level Target API notifications. The pre-3.3 notifies (`LIGHT_LEVEL`, `LIGHT_STATE`, `LIGHT_LEVEL_CHANGED`) are silently discarded by the v2 proxy — the navigator slider falls back to 0. Use:

```lua
C4:SendToProxy(5001, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level }, "NOTIFY")  -- level 0-100
```

- Send it on every device change/poll (`UpdateProxy`), from `OnRequestData` when a navigator connects, and on driver init so the binding has a value before the first poll.
- On/off is derived from the level (0 = off); there is no separate state notify for dimmers.
- Incoming commands from the proxy are `SET_BRIGHTNESS_TARGET`/`RAMP_TO_LEVEL` with param `LIGHT_BRIGHTNESS_TARGET` (not `LIGHT`), plus `RATE`.
- **There is no `ON`/`OFF` command** — the v2 proxy has no such commands. The navigator's on/off toggle sends `SET_BRIGHTNESS_TARGET` with level **0** (off) or the on-preset level (on), or a `TOGGLE` command. So brightness 0 must be routed to a real relay-off (not `set_brightness:0`, which leaves an IOT dimmer on at minimum), and `TOGGLE` must be handled (toggles on `g_currentOn`). The `ON`/`OFF` handlers are kept only for Composer programming/actions.
- **Neeo/Halo remotes and keypads use `BUTTON_ACTION`, not `SET_BRIGHTNESS_TARGET`.** The phone app slider/toggle sends `SET_BRIGHTNESS_TARGET`; the remote's **Bulb icon** (and Android Navigator's Toggle) sends `BUTTON_ACTION` with `BUTTON_ID` (`0` = top/on, `1` = bottom/off, `2` = toggle) and `ACTION` (`1` = press, `2` = release, `0` = long release). Act on **release** (`ACTION == "2"`) to match the stock light proxy and avoid double-firing. Without this handler the remote's Bulb press is silently dropped (symptom: works in app, nothing on remote). Params arrive as strings.
- Source: https://snap-one.github.io/docs-driverworks-proxyprotocol/ → Light V2 Protocol Notifications; BUTTON_ID/ACTION values from control4/docs-driverworks `sample_drivers/light_sample.c4i`.

## Packaging

After editing, repackage the relevant `.c4z` (which Composer Pro loads). **The driver definition XML MUST be named `driver.xml` inside the archive** — Composer rejects any other name as "invalid file". The Lua script can be any name (referenced via `<script file="...">`). Since the account driver's source XML is `account.xml`, it must be copied to `driver.xml` when packaging:

```powershell
# Light driver (source XML already named driver.xml)
Compress-Archive -Path driver.xml, driver.lua -DestinationPath tmp.zip -Force
Rename-Item tmp.zip kasa_cloud_switch.c4z -Force

# Account driver (account.xml must go into the zip AS driver.xml)
$b = "build_account"; Remove-Item $b -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $b | Out-Null
Copy-Item account.xml "$b\driver.xml" -Force; Copy-Item account.lua "$b\account.lua" -Force
Compress-Archive -Path "$b\driver.xml", "$b\account.lua" -DestinationPath tmp.zip -Force
Rename-Item tmp.zip kasa_account.c4z -Force; Remove-Item $b -Recurse -Force
```

There is no build system, test runner, or linter. All testing is done by loading the `.c4z` into Composer Pro and observing the Control4 log.

## Architecture

The driver is two files:

- **`driver.xml`** — declares metadata, Composer properties, commands, the `light` proxy (binding ID `5001`), and references `driver.lua` via `<script file="driver.lua" jit="1"/>`.
- **`driver.lua`** — all runtime logic. The Control4 runtime calls into it via DriverWorks callbacks.

### Control flow

```
OnDriverInit()
  └─ LoadConfig() ← reads Properties[] global (set in Composer)
  └─ Login() → POST https://wap.tplinkcloud.com → stores token in g_token + Property "Token"
  └─ PollStatus() → SendPassthrough(get_sysinfo/get_device_info) → UpdateProxy()
  └─ StartPollTimer() → fires PollStatus() every g_pollInterval seconds

ExecuteCommand(cmd, params)  ← called by Control4 when navigator/scene fires a command
ReceivedFromProxy(...)       ← also routes to ExecuteCommand
  └─ TurnOn/TurnOff/SetBrightness → SendPassthrough() → UpdateProxy()
```

### Token refresh

`SendPassthrough()` checks `resp.error_code` against `AUTH_ERRORS` (`-1003`, `-1010`, `-20651`). On a match it clears `g_token`, calls `Login()`, then retries the original request once (`isRetry=true` prevents infinite loops).

### Two device schemas

The `g_deviceType` global (`"IOT"` or `"SMART"`) switches the `requestData` payload shape inside the three `Build*()` functions:

| | IOT (HS/KP/KS230) | SMART (KS205/KS225) |
|---|---|---|
| On/Off | `system.set_relay_state` | `set_device_info {device_on}` |
| Brightness | `smartlife.iot.dimmer.set_brightness` + relay | `set_device_info {brightness, device_on}` |
| Status | `system.get_sysinfo` | `get_device_info` |

All commands go through the cloud passthrough endpoint:
```
POST https://use1-wap.tplinkcloud.com?token=<TOKEN>
{ method: "passthrough", params: { deviceId, requestData: "<JSON string>" } }
```

### Proxy integration

`UpdateProxy(bOn, nLevel)` pushes `LIGHT_LEVEL` and `LIGHT_STATE` notifications to proxy binding `5001` using `C4:SendToProxy()`. Control4 navigators and scenes read these values for feedback.

### Logging

`dbg()` prints only when the `Debug` property is `"On"`. `err()` always writes to `C4:ErrorLog`. Enable Debug in Composer to trace HTTP requests and responses.

## Kasa Cloud API reference

| Endpoint | Purpose |
|---|---|
| `https://wap.tplinkcloud.com` | Auth (`login` method) |
| `https://use1-wap.tplinkcloud.com` | Device control (`passthrough` method, per-device `appServerUrl`) |

- Login returns `result.token` — passed as `?token=` on all subsequent calls.
- Device aliases from `getDeviceList` are Base64-encoded.
- `status: 1` = online, `status: 0` = offline.
- `SMART.KASASWITCH` (KS-series) and `IOT.SMARTPLUGSWITCH` (HS/KP-series) use different `requestData` schemas.

## Property reference (Composer)

| Property | Notes |
|---|---|
| Kasa Username / Password | TP-Link account credentials |
| Token | Auto-managed cached token — cleared on credential change |
| Device ID | 40-char hex `deviceId` from `getDeviceList` response |
| Device Type | `IOT` or `SMART` — must match the device's `deviceType` field |
| Is Dimmer | `Yes` for HS220, KS225, KS230, KP405 |
| Poll Interval (sec) | 10–300; changing it restarts the timer immediately |
| Status | Readonly — shows current on/off state and brightness |
| Debug | `On` enables verbose HTTP logging |
