--[[
  TP-Link Kasa Cloud Switch — Control4 DriverWorks Driver
  Author: Jagdeep Matharu
  Version: 1.0

  Supports:
    IOT.SMARTPLUGSWITCH (HS/KP/KS230-series) — set via Device Type = "IOT"
    SMART.KASASWITCH    (KS205/KS225-series)  — set via Device Type = "SMART"

  Auth errors trigger automatic re-login and a single retry.
]]

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local API_URL   = "https://use1-wap.tplinkcloud.com"
local PROXY_ID  = 5001
local POLL_TIMER     = 1
local DISCOVER_TIMER = 2
local FILL_TIMER     = 3   -- short retry window to auto-fill Local IP after (re)config

local ACCOUNT_FILE   = "kasa_account"  -- driver filename of the Kasa Account agent
local ACCOUNT_NAME   = "TP-Link Kasa Account"
local TOKEN_VAR_ID   = 3001   -- token variable owned by the account agent
local DEVLIST_VAR_ID = 3002   -- device-list JSON variable owned by the account agent
local KLAP_HASH_VAR_ID = 3003 -- KLAP auth hash (hex) owned by the account agent

local AUTH_ERRORS = { [-1003] = true, [-1010] = true, [-20651] = true }

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local g_token        = ""
local g_deviceId     = ""
local g_appServerUrl = ""      -- per-device regional endpoint (from getDeviceList); "" = use API_URL
local g_deviceType   = "IOT"   -- "IOT" or "SMART"
local g_isDimmer     = false
local g_pollInterval = 60
local g_debug        = false

local g_accountId    = 0       -- device ID of the bound Kasa Account driver
local g_pending      = {}      -- requests queued while waiting for a token
local g_deviceList   = {}      -- cached device list from the account driver

local g_currentLevel = 0
local g_currentOn    = false

-- Local KLAP control (SMART / KS205 / KS225 devices that are dead on the cloud)
local g_localIp      = ""       -- device LAN IP; "" = use cloud passthrough
local g_klapAuthHash = ""       -- raw 32-byte SHA256(SHA1(user)..SHA1(pass)) from account var 3003
local g_klap         = nil      -- active KLAP session { key, sig, iv, seq, cookie }
local g_terminalUuid = "C4KASAKLAP0001"

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------

local function log(msg)
  print("[KasaDriver] " .. tostring(msg))
  C4:ErrorLog("[KasaDriver] " .. tostring(msg))
end

local function dbg(msg)
  if g_debug then
    log(msg)
  end
end

local function err(msg)
  log(msg)
end

-- ---------------------------------------------------------------------------
-- JSON encoder / decoder (pure Lua — no external dependencies)
-- ---------------------------------------------------------------------------

local function json_encode(val)
  local t = type(val)
  if val == nil then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    if val ~= val then return "null" end  -- NaN
    if val == math.floor(val) and math.abs(val) < 1e15 then
      return string.format("%.0f", val)
    end
    return tostring(val)
  elseif t == "string" then
    return '"' .. val:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t') .. '"'
  elseif t == "table" then
    local maxn, count = 0, 0
    for k in pairs(val) do
      count = count + 1
      if type(k) == "number" and k == math.floor(k) and k > 0 and k > maxn then maxn = k end
    end
    if maxn == count then
      local parts = {}
      for i = 1, maxn do parts[i] = json_encode(val[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(val) do
        if type(k) == "string" then
          parts[#parts+1] = '"' .. k:gsub('\\','\\\\'):gsub('"','\\"') .. '":' .. json_encode(v)
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

local function skip_ws(s, i)
  while i <= #s do
    local b = s:byte(i)
    if b ~= 32 and b ~= 9 and b ~= 10 and b ~= 13 then break end
    i = i + 1
  end
  return i
end

local parse_value  -- forward declaration

local function parse_string(s, i)
  local result, j = {}, i + 1
  while j <= #s do
    local c = s:sub(j,j)
    if c == '"' then
      return table.concat(result), j + 1
    elseif c == '\\' then
      j = j + 1; c = s:sub(j,j)
      local esc = {['"']='"',['\\']='\\',['/']='',['\n']='\n',n='\n',r='\r',t='\t',b='\b',f='\f'}
      result[#result+1] = esc[c] or c
    else
      result[#result+1] = c
    end
    j = j + 1
  end
  return table.concat(result), j
end

local function parse_object(s, i)
  local obj = {}
  i = skip_ws(s, i + 1)
  if s:sub(i,i) == '}' then return obj, i + 1 end
  while i <= #s do
    i = skip_ws(s, i)
    local key; key, i = parse_string(s, i)
    i = skip_ws(s, i)
    if s:sub(i,i) ~= ':' then break end
    i = skip_ws(s, i + 1)
    local v; v, i = parse_value(s, i)
    obj[key] = v
    i = skip_ws(s, i)
    if s:sub(i,i) == '}' then return obj, i + 1 end
    if s:sub(i,i) ~= ',' then break end
    i = i + 1
  end
  return obj, i
end

local function parse_array(s, i)
  local arr = {}
  i = skip_ws(s, i + 1)
  if s:sub(i,i) == ']' then return arr, i + 1 end
  while i <= #s do
    local v; v, i = parse_value(s, i)
    arr[#arr+1] = v
    i = skip_ws(s, i)
    if s:sub(i,i) == ']' then return arr, i + 1 end
    if s:sub(i,i) ~= ',' then break end
    i = skip_ws(s, i + 1)
  end
  return arr, i
end

parse_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i,i)
  if     c == '"'                         then return parse_string(s, i)
  elseif c == '{'                         then return parse_object(s, i)
  elseif c == '['                         then return parse_array(s, i)
  elseif s:sub(i,i+3) == 'true'          then return true,  i + 4
  elseif s:sub(i,i+4) == 'false'         then return false, i + 5
  elseif s:sub(i,i+3) == 'null'          then return nil,   i + 4
  else
    local num = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', i)
    if num then return tonumber(num), i + #num end
  end
  return nil, i
end

local function json_decode(s)
  if not s or s == '' then return nil end
  local ok, v = pcall(function() return (parse_value(s, 1)) end)
  return ok and v or nil
end

local function toJson(t)   return json_encode(t) end
local function fromJson(s) return json_decode(s)  end

-- ---------------------------------------------------------------------------
-- KLAP local transport (KlapV2) — for SMART devices unreachable via the cloud
-- ---------------------------------------------------------------------------
-- KS205/KS225 dropped off the legacy Kasa cloud (status=0 / error -20571). They
-- speak the encrypted KLAP protocol on the LAN. We implement KlapV2 natively:
--   auth_hash = SHA256(SHA1(user)..SHA1(pass))   (supplied by the account driver)
--   handshake1/2 authenticate and derive an AES-128-CBC session; /app/request
--   carries the same SMART {method,params} payloads the cloud path already builds.

-- Raw-byte crypto wrappers over the C4 crypto API (all NONE = raw in/out).
local function sha256(raw) return C4:Hash("SHA256", raw, { data_encoding = "NONE", return_encoding = "NONE" }) end

local function aesEnc(key, iv, data)
  return C4:Encrypt("AES-128-CBC", key, iv, data,
    { key_encoding = "NONE", iv_encoding = "NONE", data_encoding = "NONE", return_encoding = "NONE", padding = false })
end
local function aesDec(key, iv, data)
  return C4:Decrypt("AES-128-CBC", key, iv, data,
    { key_encoding = "NONE", iv_encoding = "NONE", data_encoding = "NONE", return_encoding = "NONE", padding = false })
end

-- Big-endian 32-bit (un)packing without string.pack — works on Lua 5.1 and 5.3.
local function packU32(n)
  n = n % 4294967296
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536)    % 256,
    math.floor(n / 256)      % 256,
    n % 256)
end
local function unpackI32BE(s)
  local b1, b2, b3, b4 = s:byte(1, 4)
  local n = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
  if n >= 2147483648 then n = n - 4294967296 end   -- signed
  return n
end

local function pkcs7pad(s)
  local n = 16 - (#s % 16)
  return s .. string.rep(string.char(n), n)
end
local function pkcs7unpad(s)
  if #s == 0 then return s end
  local n = s:byte(#s)
  if not n or n < 1 or n > 16 or n > #s then return s end
  return s:sub(1, #s - n)
end

local g_randSeeded = false
local function randBytes(n)
  if not g_randSeeded then
    math.randomseed(os.time() + math.floor((os.clock() or 0) * 1000000))
    g_randSeeded = true
  end
  local out, ent = "", tostring(os.time()) .. ":" .. tostring(os.clock()) .. ":" .. tostring(math.random())
  while #out < n do
    ent = sha256(ent .. tostring(math.random()))
    out = out .. ent
  end
  return out:sub(1, n)
end

local function hexToRaw(hex)
  if type(hex) ~= "string" or hex == "" then return "" end
  return (hex:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

-- Raw binary POST to the device; extracts the TP_SESSIONID cookie from the response.
local function KlapHttp(path, body, cookie, callback)  -- callback(strData, nCode, sessionCookie, errMsg)
  local url = "http://" .. g_localIp .. path
  local headers = { ["Content-Type"] = "application/octet-stream" }
  if cookie and cookie ~= "" then headers["Cookie"] = cookie end
  dbg("KLAP POST " .. url .. " (" .. #body .. "B)")
  C4:urlPost(url, body, headers, false, function(strError, strData, nCode, tHeaders)
    if type(strError) == "string" and strError ~= "" then
      callback(nil, nil, nil, strError); return
    end
    local sessionCookie
    if type(tHeaders) == "table" then
      local sc = tHeaders["Set-Cookie"] or tHeaders["set-cookie"]
      if type(sc) == "table" then sc = sc[1] end
      if type(sc) == "string" then
        local sid = sc:match("TP_SESSIONID=([^;]+)")
        if sid then sessionCookie = "TP_SESSIONID=" .. sid end
      end
    end
    callback(strData, nCode, sessionCookie, nil)
  end)
end

-- handshake1 + handshake2 → derive AES session. callback(ok, errMsg)
local function KlapHandshake(callback)
  if g_localIp == "" then callback(false, "no local IP set"); return end
  if g_klapAuthHash == "" then callback(false, "no KLAP auth hash (account driver not ready)"); return end

  local localSeed = randBytes(16)
  KlapHttp("/app/handshake1", localSeed, nil, function(data, code, cookie, err1)
    if err1 then callback(false, "handshake1: " .. tostring(err1)); return end
    if code ~= 200 or type(data) ~= "string" or #data < 48 then
      callback(false, "handshake1 code=" .. tostring(code) .. " len=" .. tostring(data and #data)); return
    end
    if not cookie then callback(false, "handshake1 missing TP_SESSIONID cookie"); return end
    local remoteSeed = data:sub(1, 16)
    local serverHash = data:sub(17, 48)
    if sha256(localSeed .. remoteSeed .. g_klapAuthHash) ~= serverHash then
      callback(false, "handshake1 auth mismatch — wrong credentials or non-KlapV2 device"); return
    end
    local payload2 = sha256(remoteSeed .. localSeed .. g_klapAuthHash)
    KlapHttp("/app/handshake2", payload2, cookie, function(_, code2, _, err2)
      if err2 then callback(false, "handshake2: " .. tostring(err2)); return end
      if code2 ~= 200 then callback(false, "handshake2 code=" .. tostring(code2)); return end
      local ah = g_klapAuthHash
      local ivfull = sha256("iv" .. localSeed .. remoteSeed .. ah)
      g_klap = {
        key    = sha256("lsk" .. localSeed .. remoteSeed .. ah):sub(1, 16),
        sig    = sha256("ldk" .. localSeed .. remoteSeed .. ah):sub(1, 28),
        iv     = ivfull:sub(1, 12),
        seq    = unpackI32BE(ivfull:sub(29, 32)),
        cookie = cookie,
      }
      dbg("KLAP session established (seq=" .. g_klap.seq .. ")")
      callback(true, nil)
    end)
  end)
end

-- Encrypted request over an established session. callback(respTable, errMsg).
-- On HTTP 403 (session expired) it re-handshakes once and retries.
local function KlapRequest(jsonStr, callback, isRetry)
  local function doReq()
    local s = g_klap
    s.seq = s.seq + 1
    local seq   = s.seq
    local ivSeq = s.iv .. packU32(seq)
    local ct    = aesEnc(s.key, ivSeq, pkcs7pad(jsonStr))
    if type(ct) ~= "string" then callback(nil, "AES encrypt failed"); return end
    local body = sha256(s.sig .. packU32(seq) .. ct) .. ct
    KlapHttp("/app/request?seq=" .. tostring(seq), body, s.cookie, function(data, code, _, err3)
      if err3 then callback(nil, "request: " .. tostring(err3)); return end
      if code == 403 then
        g_klap = nil
        if isRetry then callback(nil, "403 after re-handshake"); return end
        dbg("KLAP 403 — re-handshaking")
        KlapHandshake(function(ok, hErr)
          if not ok then callback(nil, "re-handshake: " .. tostring(hErr)); return end
          KlapRequest(jsonStr, callback, true)
        end)
        return
      end
      if code ~= 200 or type(data) ~= "string" or #data <= 32 then
        callback(nil, "request code=" .. tostring(code) .. " len=" .. tostring(data and #data)); return
      end
      local pt = aesDec(s.key, ivSeq, data:sub(33))
      if type(pt) ~= "string" then callback(nil, "AES decrypt failed"); return end
      pt = pkcs7unpad(pt)
      dbg("KLAP response: " .. pt)
      callback(fromJson(pt), nil)
    end)
  end

  if not g_klap then
    KlapHandshake(function(ok, hErr)
      if not ok then callback(nil, "handshake: " .. tostring(hErr)); return end
      doReq()
    end)
  else
    doReq()
  end
end

-- ---------------------------------------------------------------------------
-- Config loader
-- ---------------------------------------------------------------------------

-- Find this device's per-device appServerUrl in the account's cached list.
-- Kasa homes devices on different regional clouds; using the wrong endpoint
-- returns error -20571 ("device offline") even when the device is online.
local function ResolveAppServer()
  if g_deviceId == "" then return end
  for _, d in ipairs(g_deviceList) do
    if tostring(d.i) == g_deviceId then
      if type(d.u) == "string" and d.u ~= "" then
        if d.u ~= g_appServerUrl then
          g_appServerUrl = d.u
          dbg("Resolved app server for device: " .. g_appServerUrl)
        end
      else
        dbg("Device in list but no appServerUrl — UPDATE the account driver (v7+) and run " ..
            "'Refresh Device List'. Falling back to " .. API_URL)
      end
      return
    end
  end
  dbg("Device " .. g_deviceId .. " not in cached list yet — appServerUrl unresolved")
end

-- Auto-fill Local IP (KLAP) for SMART devices from the account's UDP discovery
-- (field `p`). Only when the property is blank — a manually entered IP always wins.
local function AutoFillLocalIp()
  if g_deviceType ~= "SMART" or g_deviceId == "" then return end
  if (Properties["Local IP (KLAP)"] or "") ~= "" then return end
  for _, d in ipairs(g_deviceList) do
    if tostring(d.i) == g_deviceId and type(d.p) == "string" and d.p ~= "" then
      C4:UpdateProperty("Local IP (KLAP)", d.p)   -- fires OnPropertyChanged → LoadConfig → poll
      log("Auto-filled Local IP (KLAP) = " .. d.p .. " from discovery")
      return
    end
  end
end

-- Self-heal: re-read the shared list and retry the auto-fill. Called from the poll
-- so a SMART device with a blank IP eventually picks up its discovered IP even if the
-- variable-change notification was missed (e.g. discovery finished after this loaded).
local function RefreshDiscoveredIp()
  if g_deviceType ~= "SMART" or g_accountId == 0 then return end
  if (Properties["Local IP (KLAP)"] or "") ~= "" then return end
  local js = C4:GetDeviceVariable(g_accountId, DEVLIST_VAR_ID)
  if type(js) ~= "string" or js == "" then return end
  local parsed = fromJson(js)
  if type(parsed) == "table" then
    g_deviceList = parsed
    AutoFillLocalIp()
  end
end

-- After a SMART device is (re)configured with a blank IP, retry the discovery
-- auto-fill on a short window so it lands promptly even when discovery completes
-- just after this driver loaded — instead of waiting for the next 60s poll.
local function StartFillRetry()
  C4:KillTimer(FILL_TIMER)
  if g_deviceType ~= "SMART" then return end
  if (Properties["Local IP (KLAP)"] or "") ~= "" then return end
  local tries = 0
  C4:SetTimer(3000, function()
    tries = tries + 1
    RefreshDiscoveredIp()
    if (Properties["Local IP (KLAP)"] or "") ~= "" or tries >= 10 then
      C4:KillTimer(FILL_TIMER)
    end
  end, true, FILL_TIMER)   -- every 3s, up to ~30s, self-stops once filled
end

local function LoadConfig()
  g_deviceId     = Properties["Device ID"]         or ""
  g_deviceType   = Properties["Device Type"]       or "IOT"
  g_isDimmer     = (Properties["Is Dimmer"]        == "Yes")
  g_pollInterval = tonumber(Properties["Poll Interval (sec)"]) or 60
  g_debug        = (Properties["Debug"]            == "On")
  local newIp    = (Properties["Local IP (KLAP)"] or ""):gsub("%s+", "")
  if newIp ~= g_localIp then g_klap = nil end   -- IP changed → drop stale session
  g_localIp      = newIp
  ResolveAppServer()
  log("Config loaded — device=" .. g_deviceId .. " type=" .. g_deviceType ..
      (g_localIp ~= "" and (" localIp=" .. g_localIp) or ""))
end

-- ---------------------------------------------------------------------------
-- HTTP helper
-- ---------------------------------------------------------------------------

local function HttpPost(url, body, callback)
  local headers = { ["Content-Type"] = "application/json" }
  dbg("POST " .. url)
  dbg("BODY " .. tostring(body))
  C4:urlPost(url, body, headers, false, function(strError, strData, nCode, tHeaders)
    dbg("HTTP callback — code=" .. tostring(nCode) .. " err=" .. tostring(strError) .. " datatype=" .. type(strData))
    -- strError may be a numeric ticket ID (not a real error); treat as error only when it's a non-empty string
    if type(strError) == "string" and strError ~= "" then
      err("HTTP Error: " .. strError)
      callback(nil, strError)
      return
    end
    -- if nCode is not in 2xx range it's an HTTP-level failure
    if type(nCode) == "number" and (nCode < 200 or nCode >= 300) then
      err("HTTP status error: " .. tostring(nCode))
      callback(nil, "http_" .. tostring(nCode))
      return
    end
    local body = type(strData) == "string" and strData or tostring(strData)
    dbg("Response: " .. body)
    local t = fromJson(body)
    if not t then
      err("JSON parse error on: " .. body)
      callback(nil, "json_parse_error")
      return
    end
    callback(t, nil)
  end)
end

-- ---------------------------------------------------------------------------
-- Token — sourced from the bound Kasa Account driver's shared variable
-- ---------------------------------------------------------------------------

-- Pull the latest token from the account driver's variable (cheap, local call).
local function RefreshTokenFromAccount()
  if g_accountId ~= 0 then
    local t = C4:GetDeviceVariable(g_accountId, TOKEN_VAR_ID)
    if type(t) == "string" and t ~= "" then g_token = t end
  end
end

-- Ask the account driver to re-login. The new token arrives via
-- OnWatchedVariableChanged, which flushes any queued requests.
local function RequestRelogin()
  if g_accountId ~= 0 then
    dbg("Requesting relogin from account driver " .. g_accountId)
    C4:SendToDevice(g_accountId, "RELOGIN", {})
  else
    err("No Kasa Account driver bound — cannot obtain token")
    C4:UpdateProperty("Status", "Error: no Account driver bound")
  end
end

-- Build the "Select Device From List" dropdown from the account's cached list.
local function PopulateDeviceList()
  if g_accountId == 0 then return end
  local js = C4:GetDeviceVariable(g_accountId, DEVLIST_VAR_ID)
  if type(js) ~= "string" or js == "" then return end
  local parsed = fromJson(js)
  if type(parsed) ~= "table" then return end
  g_deviceList = parsed

  local aliases = {}
  for _, d in ipairs(g_deviceList) do
    aliases[#aliases + 1] = tostring(d.a) .. " (" .. tostring(d.m) .. ")"
  end
  if #aliases > 0 then
    C4:UpdatePropertyList("Select Device From List", table.concat(aliases, ","))
    dbg("Populated device dropdown — " .. #aliases .. " devices")
  end
  ResolveAppServer()   -- list just refreshed — pick up this device's endpoint
  AutoFillLocalIp()    -- and its discovered LAN IP (SMART/KLAP), if any
end

-- Apply the device the installer picked in the dropdown to the real properties.
local function ApplySelectedDevice(strLabel)
  for _, d in ipairs(g_deviceList) do
    if (tostring(d.a) .. " (" .. tostring(d.m) .. ")") == strLabel then
      C4:UpdateProperty("Device ID", tostring(d.i))
      C4:UpdateProperty("Device Type", tostring(d.t))
      C4:UpdateProperty("Is Dimmer", (d.d == 1) and "Yes" or "No")
      log("Selected device '" .. tostring(d.a) .. "' → ID " .. tostring(d.i) .. " (" .. tostring(d.t) .. ")")
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Passthrough API call with auto-retry on auth failure
-- ---------------------------------------------------------------------------

local function SendPassthrough(requestData, callback, isRetry)
  if g_deviceId == "" then
    err("Device ID not set")
    return
  end
  RefreshTokenFromAccount()
  if g_token == "" then
    dbg("No token yet — queuing request and requesting relogin")
    g_pending[#g_pending + 1] = { rd = requestData, cb = callback }
    RequestRelogin()
    return
  end

  local payload = toJson({
    method = "passthrough",
    params = {
      deviceId    = g_deviceId,
      requestData = toJson(requestData),
    }
  })
  local base = (g_appServerUrl ~= "" and g_appServerUrl) or API_URL
  local url = base .. "?token=" .. g_token

  HttpPost(url, payload, function(resp, httpErr)
    if not resp then
      err("Passthrough HTTP failed: " .. tostring(httpErr))
      return
    end
    if AUTH_ERRORS[resp.error_code] and not isRetry then
      dbg("Token expired — requesting account relogin")
      g_token = ""
      g_pending[#g_pending + 1] = { rd = requestData, cb = callback }
      RequestRelogin()
      return
    end
    if resp.error_code ~= 0 then
      if resp.error_code == -20571 then
        local hint = ""
        if g_deviceType == "SMART" then
          hint = " — KS205/KS225 use the KLAP protocol and drop off the legacy Kasa cloud" ..
                 " (status=0); they are NOT cloud-controllable. Use local (python-kasa) or Matter control."
        end
        err("Passthrough API error -20571 (device offline / unreachable via cloud)" .. hint ..
            " — endpoint=" .. base .. " deviceId=" .. g_deviceId)
        C4:UpdateProperty("Status", "Error: device offline (-20571)")
      else
        err("Passthrough API error " .. tostring(resp.error_code))
        C4:UpdateProperty("Status", "Error: API code " .. tostring(resp.error_code))
      end
      return
    end
    if callback then
      local inner = fromJson(resp.result.responseData)
      callback(inner)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Transport router — SMART devices with a LAN IP go local (KLAP); else cloud
-- ---------------------------------------------------------------------------

local function UseKlap()
  return g_deviceType == "SMART" and g_localIp ~= ""
end

-- Wrap the SMART Build* output ({method,params}) as a KLAP request and send it.
local function SendLocal(requestData, callback)
  local inner = {
    method             = requestData.method,
    request_time_milis = 0,
    terminal_uuid      = g_terminalUuid,
  }
  if requestData.params ~= nil then inner.params = requestData.params end
  KlapRequest(toJson(inner), function(resp, kErr)
    if not resp then
      err("KLAP request failed: " .. tostring(kErr))
      C4:UpdateProperty("Status", "Error: local KLAP (" .. tostring(kErr) .. ")")
      return
    end
    if resp.error_code ~= nil and resp.error_code ~= 0 then
      err("KLAP API error " .. tostring(resp.error_code))
      C4:UpdateProperty("Status", "Error: KLAP code " .. tostring(resp.error_code))
      return
    end
    if callback then callback(resp) end   -- full {error_code,result}; poll reads result.*
  end)
end

local function Send(requestData, callback)
  if UseKlap() then
    SendLocal(requestData, callback)
  else
    SendPassthrough(requestData, callback)
  end
end

-- ---------------------------------------------------------------------------
-- Device commands
-- ---------------------------------------------------------------------------

local function BuildOnOff(state)
  if g_deviceType == "SMART" then
    return { method = "set_device_info", params = { device_on = state } }
  else
    return { system = { set_relay_state = { state = state and 1 or 0 } } }
  end
end

local function BuildBrightness(level)
  if g_deviceType == "SMART" then
    return { method = "set_device_info", params = { brightness = level, device_on = true } }
  else
    return {
      ["smartlife.iot.dimmer"] = { set_brightness = { brightness = level } },
      system = { set_relay_state = { state = 1 } },
    }
  end
end

local function BuildGetStatus()
  if g_deviceType == "SMART" then
    return { method = "get_device_info", params = {} }
  else
    return { system = { get_sysinfo = {} } }
  end
end

-- ---------------------------------------------------------------------------
-- Proxy state update
-- ---------------------------------------------------------------------------

local function UpdateProxy(bOn, nLevel)
  g_currentOn    = bOn
  if nLevel and nLevel > 0 then
    g_currentLevel = nLevel
  end

  -- light_v2 proxy tracks brightness (0 = off); on/off is derived from the level.
  -- Dimmers MUST use LIGHT_BRIGHTNESS_CHANGED (LEVEL_CHANGE is deprecated pre-OS3.3).
  local reportLevel = bOn and g_currentLevel or 0
  dbg("UpdateProxy — bOn=" .. tostring(bOn) .. " report=" .. tostring(reportLevel))
  C4:SendToProxy(PROXY_ID, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = reportLevel }, "NOTIFY")

  local statusStr = bOn and ("On — " .. tostring(g_currentLevel) .. "%") or "Off"
  C4:UpdateProperty("Status", statusStr)
end

-- ---------------------------------------------------------------------------
-- TurnOn / TurnOff / SetBrightness
-- ---------------------------------------------------------------------------

local function TurnOn()
  dbg("TurnOn")
  Send(BuildOnOff(true), function()
    UpdateProxy(true, g_isDimmer and g_currentLevel or 100)
  end)
end

local function TurnOff()
  dbg("TurnOff")
  Send(BuildOnOff(false), function()
    UpdateProxy(false, g_currentLevel)
  end)
end

local function SetBrightness(level)
  level = math.max(0, math.min(100, math.floor(level)))
  -- A target of 0 means "off" — turn the relay off rather than set brightness 0
  -- (setting brightness 0 with the relay on leaves the light on at minimum).
  if level <= 0 then
    dbg("SetBrightness 0 → TurnOff")
    TurnOff()
    return
  end
  if not g_isDimmer then
    -- Non-dimmer: any positive target just means "on".
    TurnOn()
    return
  end
  dbg("SetBrightness " .. level)
  Send(BuildBrightness(level), function()
    UpdateProxy(true, level)
  end)
end

-- ---------------------------------------------------------------------------
-- Status poll
-- ---------------------------------------------------------------------------

local function PollStatus()
  RefreshDiscoveredIp()   -- SMART + blank IP → try to pick up its discovered LAN IP
  dbg("Polling status")
  Send(BuildGetStatus(), function(inner)
    if not inner then return end

    local bOn, nLevel
    if g_deviceType == "SMART" then
      local r = inner.result or inner
      bOn    = r.device_on == true
      nLevel = tonumber(r.brightness) or (bOn and 100 or 0)
      if r.brightness ~= nil and not g_isDimmer then
        g_isDimmer = true
        C4:UpdateProperty("Is Dimmer", "Yes")
        log("Auto-detected dimmer capability from sysinfo")
      end
    else
      local info = inner.system and inner.system.get_sysinfo or {}
      bOn    = (info.relay_state == 1)
      nLevel = tonumber(info.brightness) or (bOn and 100 or 0)
      -- auto-detect dimmer capability from sysinfo
      if info.brightness ~= nil and not g_isDimmer then
        g_isDimmer = true
        C4:UpdateProperty("Is Dimmer", "Yes")
        log("Auto-detected dimmer capability from sysinfo")
      end
    end
    UpdateProxy(bOn, nLevel)
  end)
end

-- ---------------------------------------------------------------------------
-- Poll timer
-- ---------------------------------------------------------------------------

local function StartPollTimer()
  C4:KillTimer(POLL_TIMER)
  C4:SetTimer(g_pollInterval * 1000, function()
    PollStatus()
    StartPollTimer()   -- reschedule
  end, false, POLL_TIMER)
  dbg("Poll timer set for " .. g_pollInterval .. "s")
end

-- ---------------------------------------------------------------------------
-- DriverWorks callbacks
-- ---------------------------------------------------------------------------

-- Find the Kasa Account agent by name/driver-file (agents aren't bound).
local function DiscoverAccount()
  local all = C4:GetDevices({})
  if type(all) == "table" then
    for id, info in pairs(all) do
      if type(info) == "table" then
        local fn = tostring(info.driverFileName or "")
        local dn = tostring(info.deviceName or "")
        if fn:find(ACCOUNT_FILE, 1, true) or dn == ACCOUNT_NAME then
          g_accountId = tonumber(id) or id
          break
        end
      end
    end
  end
  if g_accountId ~= 0 then
    C4:KillTimer(DISCOVER_TIMER)
    -- Fires OnWatchedVariableChanged immediately with the current values.
    C4:RegisterVariableListener(g_accountId, TOKEN_VAR_ID)
    C4:RegisterVariableListener(g_accountId, DEVLIST_VAR_ID)
    C4:RegisterVariableListener(g_accountId, KLAP_HASH_VAR_ID)
    -- Read KLAP hash directly too, in case the listener's initial fire is missed.
    local kh = C4:GetDeviceVariable(g_accountId, KLAP_HASH_VAR_ID)
    if type(kh) == "string" and kh ~= "" then g_klapAuthHash = hexToRaw(kh) end
    PopulateDeviceList()
    log("Found Kasa Account agent id=" .. g_accountId)
    return true
  end
  C4:UpdateProperty("Status", "Waiting for Kasa Account agent")
  return false
end

-- Retry discovery until the agent is found (light may load before the agent).
local function StartDiscovery()
  if DiscoverAccount() then return end
  C4:KillTimer(DISCOVER_TIMER)
  C4:SetTimer(10000, function() DiscoverAccount() end, true, DISCOVER_TIMER)  -- repeating
end

local function Initialize()
  LoadConfig()
  -- Establish proxy binding; real state comes from the first PollStatus()
  C4:SendToProxy(PROXY_ID, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 0 }, "NOTIFY")
  StartDiscovery()
  StartFillRetry()   -- pre-configured SMART device: fill its IP as soon as discovery lands
  -- Queues until the token arrives from the account agent, then flushes.
  PollStatus()
  StartPollTimer()
end

function OnDriverInit()
  log("OnDriverInit")
end

-- OnDriverLateInit fires after all bindings are established
function OnDriverLateInit()
  log("OnDriverLateInit — bindings ready")
  Initialize()
end

function OnDriverDestroyed()
  C4:KillTimer(POLL_TIMER)
  C4:KillTimer(DISCOVER_TIMER)
  C4:KillTimer(FILL_TIMER)
end

function OnPropertyChanged(strProperty)
  if strProperty == "Select Device From List" then
    local sel = Properties["Select Device From List"] or ""
    if sel ~= "" and ApplySelectedDevice(sel) then
      LoadConfig()   -- picks up the Device ID / Type / Is Dimmer we just set
      StartFillRetry()  -- SMART: grab the discovered IP promptly (may not be published yet)
      PollStatus()
    end
    return
  end

  LoadConfig()
  if strProperty == "Poll Interval (sec)" then
    StartPollTimer()
  elseif strProperty == "Device ID" or strProperty == "Device Type"
      or strProperty == "Is Dimmer" or strProperty == "Local IP (KLAP)" then
    StartFillRetry()
    PollStatus()
  end
end

-- Fired when the KASA_ACCOUNT binding is made/broken (control-type binding).
-- Account agent's shared token changed — cache it and flush queued requests.
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  if idDevice ~= g_accountId then return end
  if idVariable == TOKEN_VAR_ID then
    g_token = strValue or ""
    dbg("Token updated from account (len=" .. #g_token .. ")")
    if g_token ~= "" and #g_pending > 0 then
      local pend = g_pending
      g_pending = {}
      for _, p in ipairs(pend) do
        SendPassthrough(p.rd, p.cb, true)
      end
    end
  elseif idVariable == DEVLIST_VAR_ID then
    PopulateDeviceList()
  elseif idVariable == KLAP_HASH_VAR_ID then
    g_klapAuthHash = hexToRaw(strValue or "")
    g_klap = nil   -- credentials changed → force a fresh handshake
    dbg("KLAP auth hash updated (raw len=" .. #g_klapAuthHash .. ")")
  end
end


local function PrintStatus()
  local state  = g_currentOn and "ON" or "OFF"
  local level  = g_isDimmer and (" | Brightness: " .. tostring(g_currentLevel) .. "%") or ""
  local device = g_deviceId ~= "" and g_deviceId or "(no device set)"
  log("---- Status ----")
  log("Device: " .. device)
  log("State:  " .. state .. level)
  log("Type:   " .. g_deviceType .. (g_isDimmer and " (dimmer)" or " (switch)"))
  log("Token:  " .. (g_token ~= "" and "cached" or "none"))
  log("----------------")
end

local function DispatchCommand(cmd, tParams)
  if cmd == "ON" then
    TurnOn()
  elseif cmd == "OFF" then
    TurnOff()
  elseif cmd == "TOGGLE" then
    if g_currentOn then TurnOff() else TurnOn() end
  elseif cmd == "BUTTON_ACTION" then
    -- Neeo/Halo remotes and keypads drive light_v2 via BUTTON_ACTION, NOT ON/OFF/TOGGLE.
    -- (The phone app uses SET_BRIGHTNESS_TARGET, which is why it works and the remote didn't.)
    -- BUTTON_ID: 0 = top/on, 1 = bottom/off, 2 = toggle (bulb icon / Navigator Toggle).
    -- ACTION:    1 = press, 2 = release, 0 = long release. Act on release to match the
    -- stock light proxy and avoid double-firing on the press+release pair.
    local button = tostring(tParams and tParams["BUTTON_ID"] or "")
    local action = tostring(tParams and tParams["ACTION"] or "")
    dbg("BUTTON_ACTION button=" .. button .. " action=" .. action)
    if action == "2" then
      if button == "0" then
        TurnOn()
      elseif button == "1" then
        TurnOff()
      elseif button == "2" then
        if g_currentOn then TurnOff() else TurnOn() end
      end
    end
  elseif cmd == "SET_BRIGHTNESS_TARGET" then
    SetBrightness(tonumber(tParams and (tParams["LIGHT_BRIGHTNESS_TARGET"] or tParams["LIGHT"])) or 100)
  elseif cmd == "RAMP_TO_LEVEL" then
    SetBrightness(tonumber(tParams and (tParams["LIGHT_BRIGHTNESS_TARGET"] or tParams["LIGHT"])) or 100)
  elseif cmd == "GET_LIGHT_LEVEL" or cmd == "GET_STATE" or cmd == "GET_BRIGHTNESS_TARGET" then
    -- Navigator queries current state on load; reply so it doesn't time out and reset to 0
    local reportLevel = g_currentOn and g_currentLevel or 0
    dbg("Replying to " .. cmd .. " with level=" .. reportLevel)
    C4:SendToProxy(PROXY_ID, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = reportLevel }, "NOTIFY")
  elseif cmd == "REFRESH" then
    PollStatus()
  elseif cmd == "PRINT_STATUS" then
    PrintStatus()
  end
end

function ExecuteCommand(strCommand, tParams)
  dbg("ExecuteCommand: " .. tostring(strCommand))
  if tParams then
    for k, v in pairs(tParams) do
      dbg("  param [" .. tostring(k) .. "] = " .. tostring(v))
    end
  end

  -- Composer Pro action buttons fire as LUA_ACTION; the action <name> is in tParams["ACTION"]
  if strCommand == "LUA_ACTION" then
    local action = tParams and tParams["ACTION"] or ""
    dbg("Action: " .. tostring(action))
    DispatchCommand(action, tParams)
    return
  end

  DispatchCommand(strCommand, tParams)
end

function OnRequestData(idBinding, strGet, strSet)
  dbg("OnRequestData binding=" .. tostring(idBinding))
  if idBinding == PROXY_ID then
    local reportLevel = g_currentOn and g_currentLevel or 0
    C4:SendToProxy(PROXY_ID, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = reportLevel }, "NOTIFY")
  end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  dbg("ReceivedFromProxy binding=" .. tostring(idBinding) .. " cmd=" .. tostring(strCommand))
  if tParams then
    for k, v in pairs(tParams) do
      dbg("  param [" .. tostring(k) .. "] = " .. tostring(v))
    end
  end
  ExecuteCommand(strCommand, tParams)
end
