--[[
  TP-Link Kasa Account — Control4 DriverWorks Driver

  Holds the Kasa Cloud credentials ONCE for the whole project and performs
  the login. The resulting token is published in a driver variable (ID 3001)
  that every Kasa light driver reads via C4:GetDeviceVariable().

  Light drivers auto-bind to this driver through the KASA_ACCOUNT connection
  and request a fresh login (RELOGIN command) when their token expires.
]]

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local AUTH_URL     = "https://wap.tplinkcloud.com"
local TERM_UUID    = "c4-kasa-account-v1"
local TOKEN_VAR_ID = 3001          -- shared token variable; light drivers read this ID
local DEVLIST_VAR_ID = 3002        -- shared device-list JSON; light drivers read this ID
local KLAP_HASH_VAR_ID = 3003      -- shared KLAP auth hash (hex) for local control of SMART devices
local REFRESH_TIMER = 1

local DIMMER_MODELS = { "HS220", "KS225", "KS230", "KP405" }

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local g_username  = ""
local g_password  = ""
local g_token     = ""
local g_refreshHrs = 12
local g_debug     = false

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------

local function log(msg)
  print("[KasaAccount] " .. tostring(msg))
  C4:ErrorLog("[KasaAccount] " .. tostring(msg))
end

local function dbg(msg) if g_debug then log(msg) end end
local function err(msg) log(msg) end

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
    if val ~= val then return "null" end
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

local parse_value

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
  if     c == '"'                 then return parse_string(s, i)
  elseif c == '{'                 then return parse_object(s, i)
  elseif c == '['                 then return parse_array(s, i)
  elseif s:sub(i,i+3) == 'true'   then return true,  i + 4
  elseif s:sub(i,i+4) == 'false'  then return false, i + 5
  elseif s:sub(i,i+3) == 'null'   then return nil,   i + 4
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
-- Base64 decode (Kasa Base64-encodes SMART.KASASWITCH aliases)
-- ---------------------------------------------------------------------------

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function b64decode(data)
  if not data or data == "" then return data end
  data = tostring(data):gsub('[^' .. B64 .. '=]', '')
  local bits = {}
  for c in data:gmatch('.') do
    if c == '=' then break end
    local idx = B64:find(c, 1, true) - 1
    for i = 5, 0, -1 do bits[#bits + 1] = math.floor(idx / 2 ^ i) % 2 end
  end
  local out = {}
  for i = 1, #bits - 7, 8 do
    local n = 0
    for j = 0, 7 do n = n * 2 + bits[i + j] end
    out[#out + 1] = string.char(n)
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- HTTP helper
-- ---------------------------------------------------------------------------

local function HttpPost(url, body, callback)
  local headers = { ["Content-Type"] = "application/json" }
  dbg("POST " .. url)
  C4:urlPost(url, body, headers, false, function(strError, strData, nCode, tHeaders)
    dbg("HTTP callback — code=" .. tostring(nCode) .. " err=" .. tostring(strError))
    if type(strError) == "string" and strError ~= "" then
      err("HTTP Error: " .. strError)
      callback(nil, strError)
      return
    end
    if type(nCode) == "number" and (nCode < 200 or nCode >= 300) then
      err("HTTP status error: " .. tostring(nCode))
      callback(nil, "http_" .. tostring(nCode))
      return
    end
    local resp = type(strData) == "string" and strData or tostring(strData)
    local t = fromJson(resp)
    if not t then
      err("JSON parse error")
      callback(nil, "json_parse_error")
      return
    end
    callback(t, nil)
  end)
end

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local function LoadConfig()
  g_username   = Properties["Kasa Username"] or ""
  g_password   = Properties["Kasa Password"] or ""
  g_refreshHrs = tonumber(Properties["Token Refresh (hrs)"]) or 12
  g_debug      = (Properties["Debug"] == "On")
end

-- ---------------------------------------------------------------------------
-- KLAP auth hash — shared with light drivers for LOCAL control of SMART
-- (KS205/KS225) devices, which cannot be reached via the cloud passthrough.
-- KlapV2: auth_hash = SHA256( SHA1(username) .. SHA1(password) ).
-- We publish only the hash (hex) so light drivers never touch the plaintext password.
-- ---------------------------------------------------------------------------

local function PublishKlapHash()
  if g_username == "" or g_password == "" then
    C4:SetVariable(KLAP_HASH_VAR_ID, "")
    return
  end
  local ok, hex = pcall(function()
    local u = C4:Hash("SHA1", g_username, { data_encoding = "NONE", return_encoding = "NONE" })
    local p = C4:Hash("SHA1", g_password, { data_encoding = "NONE", return_encoding = "NONE" })
    return C4:Hash("SHA256", u .. p, { data_encoding = "NONE", return_encoding = "HEX" })
  end)
  if ok and type(hex) == "string" and hex ~= "" then
    C4:SetVariable(KLAP_HASH_VAR_ID, hex)
    dbg("Published KLAP auth hash (len=" .. #hex .. ")")
  else
    err("Failed to compute KLAP auth hash: " .. tostring(hex))
  end
end

-- ---------------------------------------------------------------------------
-- Login — publishes token into the shared variable
-- ---------------------------------------------------------------------------

local function DoLogin()
  if g_username == "" or g_password == "" then
    err("Kasa Username/Password not set")
    C4:UpdateProperty("Status", "Error: credentials not set")
    return
  end
  local payload = toJson({
    method = "login",
    params = {
      appType       = "Kasa_Android",
      cloudPassword = g_password,
      cloudUserName = g_username,
      terminalUUID  = TERM_UUID,
    }
  })
  HttpPost(AUTH_URL, payload, function(resp, httpErr)
    if not resp then
      err("Login HTTP failed: " .. tostring(httpErr))
      C4:UpdateProperty("Status", "Error: login failed")
      return
    end
    if resp.error_code ~= 0 then
      err("Login API error code " .. tostring(resp.error_code))
      C4:UpdateProperty("Status", "Error: login rejected (code " .. tostring(resp.error_code) .. ")")
      return
    end
    g_token = resp.result.token
    C4:SetVariable(TOKEN_VAR_ID, g_token)   -- notifies all bound light drivers
    C4:UpdateProperty("Token", g_token)
    C4:UpdateProperty("Status", "Logged in — token active")
    log("Login OK — token published to variable " .. TOKEN_VAR_ID)
    FetchDeviceList()
  end)
end

-- ---------------------------------------------------------------------------
-- Device list — cached into a shared variable for light-driver dropdowns
-- ---------------------------------------------------------------------------

local function IsDimmerModel(model)
  for _, m in ipairs(DIMMER_MODELS) do
    if model:find(m, 1, true) then return true end
  end
  return false
end

function FetchDeviceList()
  if g_token == "" then return end
  HttpPost(AUTH_URL .. "?token=" .. g_token, toJson({ method = "getDeviceList" }), function(resp, httpErr)
    if not resp or resp.error_code ~= 0 then
      err("getDeviceList failed: " .. tostring(httpErr or (resp and resp.error_code)))
      return
    end
    local list = resp.result and resp.result.deviceList or {}
    local out = {}
    for _, d in ipairs(list) do
      local dtype = "IOT"
      local alias = d.alias or ""
      if type(d.deviceType) == "string" and d.deviceType:sub(1, 5) == "SMART" then
        dtype = "SMART"
        alias = b64decode(alias) or alias
      end
      alias = alias:gsub(",", " ")   -- commas break the comma-delimited dropdown list
      dbg("device '" .. tostring(alias) .. "' model=" .. tostring(d.deviceModel) ..
          " status=" .. tostring(d.status) .. " region=" .. tostring(d.deviceRegion) ..
          " sameRegion=" .. tostring(d.isSameRegion) .. " appServerUrl=" .. tostring(d.appServerUrl))
      -- KS205/KS225 (KLAP firmware) drop off the legacy cloud and report status=0;
      -- the passthrough API cannot reach them. Flag it once so the installer knows.
      if dtype == "SMART" and tonumber(d.status) == 0 then
        err("'" .. tostring(alias) .. "' (" .. tostring(d.deviceModel) ..
            ") is offline in the legacy Kasa cloud (status=0) — likely KLAP firmware, " ..
            "NOT controllable via cloud passthrough. Needs local (python-kasa) or Matter control.")
      end
      out[#out + 1] = {
        a = alias,
        i = d.deviceId,
        t = dtype,
        d = IsDimmerModel(d.deviceModel or "") and 1 or 0,
        m = d.deviceModel or "",
        u = d.appServerUrl or "",   -- per-device regional endpoint for passthrough
      }
    end
    C4:SetVariable(DEVLIST_VAR_ID, toJson(out))  -- notifies bound light drivers
    C4:UpdateProperty("Devices Cached", tostring(#out))
    log("Device list cached — " .. #out .. " devices")
  end)
end

-- ---------------------------------------------------------------------------
-- Refresh timer
-- ---------------------------------------------------------------------------

local function StartRefreshTimer()
  C4:KillTimer(REFRESH_TIMER)
  local ms = g_refreshHrs * 60 * 60 * 1000
  C4:SetTimer(ms, function()
    dbg("Scheduled token refresh")
    DoLogin()
    StartRefreshTimer()
  end, false, REFRESH_TIMER)
  dbg("Refresh timer set for " .. g_refreshHrs .. "h")
end

-- ---------------------------------------------------------------------------
-- DriverWorks callbacks
-- ---------------------------------------------------------------------------

function OnDriverInit()
  -- Variables MUST be added in OnDriverInit. Fixed IDs so light drivers can
  -- read them via C4:GetDeviceVariable(accountId, id) without discovery.
  C4:AddVariable(TOKEN_VAR_ID, "", "STRING", true, false)      -- 3001 token
  C4:AddVariable(DEVLIST_VAR_ID, "", "STRING", true, false)    -- 3002 device list JSON
  C4:AddVariable(KLAP_HASH_VAR_ID, "", "STRING", true, false)  -- 3003 KLAP auth hash (hex)
end

function OnDriverLateInit()
  LoadConfig()
  PublishKlapHash()   -- local-control hash for SMART devices (independent of cloud login)
  DoLogin()
  StartRefreshTimer()
end

function OnDriverDestroyed()
  C4:KillTimer(REFRESH_TIMER)
end

function OnPropertyChanged(strProperty)
  LoadConfig()
  if strProperty == "Kasa Username" or strProperty == "Kasa Password" then
    C4:UpdateProperty("Token", "")
    C4:SetVariable(TOKEN_VAR_ID, "")
    PublishKlapHash()   -- creds changed → refresh local-control hash too
    DoLogin()
  elseif strProperty == "Token Refresh (hrs)" then
    StartRefreshTimer()
  end
end

-- Light drivers call C4:SendToDevice(accountId, "RELOGIN", {}) when their
-- token has expired. Also handles Composer action buttons (LUA_ACTION).
function ExecuteCommand(strCommand, tParams)
  dbg("ExecuteCommand: " .. tostring(strCommand))
  if strCommand == "RELOGIN" then
    log("Relogin requested by a light driver")
    DoLogin()
  elseif strCommand == "REFRESH_DEVICES" then
    FetchDeviceList()
  elseif strCommand == "LUA_ACTION" then
    local action = tParams and tParams["ACTION"] or ""
    if action == "Login Now" then
      DoLogin()
    elseif action == "Refresh Device List" then
      FetchDeviceList()
    end
  end
end
