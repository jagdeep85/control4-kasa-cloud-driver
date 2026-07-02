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

local ACCOUNT_FILE   = "kasa_account"  -- driver filename of the Kasa Account agent
local ACCOUNT_NAME   = "TP-Link Kasa Account"
local TOKEN_VAR_ID   = 3001   -- token variable owned by the account agent
local DEVLIST_VAR_ID = 3002   -- device-list JSON variable owned by the account agent

local AUTH_ERRORS = { [-1003] = true, [-1010] = true, [-20651] = true }

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local g_token        = ""
local g_deviceId     = ""
local g_deviceType   = "IOT"   -- "IOT" or "SMART"
local g_isDimmer     = false
local g_pollInterval = 60
local g_debug        = false

local g_accountId    = 0       -- device ID of the bound Kasa Account driver
local g_pending      = {}      -- requests queued while waiting for a token
local g_deviceList   = {}      -- cached device list from the account driver

local g_currentLevel = 0
local g_currentOn    = false

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
-- Config loader
-- ---------------------------------------------------------------------------

local function LoadConfig()
  g_deviceId     = Properties["Device ID"]         or ""
  g_deviceType   = Properties["Device Type"]       or "IOT"
  g_isDimmer     = (Properties["Is Dimmer"]        == "Yes")
  g_pollInterval = tonumber(Properties["Poll Interval (sec)"]) or 60
  g_debug        = (Properties["Debug"]            == "On")
  log("Config loaded — device=" .. g_deviceId .. " type=" .. g_deviceType)
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
  local url = API_URL .. "?token=" .. g_token

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
      err("Passthrough API error " .. tostring(resp.error_code))
      C4:UpdateProperty("Status", "Error: API code " .. tostring(resp.error_code))
      return
    end
    if callback then
      local inner = fromJson(resp.result.responseData)
      callback(inner)
    end
  end)
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
  SendPassthrough(BuildOnOff(true), function()
    UpdateProxy(true, g_isDimmer and g_currentLevel or 100)
  end)
end

local function TurnOff()
  dbg("TurnOff")
  SendPassthrough(BuildOnOff(false), function()
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
  SendPassthrough(BuildBrightness(level), function()
    UpdateProxy(true, level)
  end)
end

-- ---------------------------------------------------------------------------
-- Status poll
-- ---------------------------------------------------------------------------

local function PollStatus()
  dbg("Polling status")
  SendPassthrough(BuildGetStatus(), function(inner)
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
end

function OnPropertyChanged(strProperty)
  if strProperty == "Select Device From List" then
    local sel = Properties["Select Device From List"] or ""
    if sel ~= "" and ApplySelectedDevice(sel) then
      LoadConfig()   -- picks up the Device ID / Type / Is Dimmer we just set
      PollStatus()
    end
    return
  end

  LoadConfig()
  if strProperty == "Poll Interval (sec)" then
    StartPollTimer()
  elseif strProperty == "Device ID" or strProperty == "Device Type" or strProperty == "Is Dimmer" then
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
