-- UniFi Network API client.
--
-- Two API surfaces are used:
--
--   Official Network API (Integration API, "X-API-KEY" header)
--     /proxy/network/integration/v1/...   (UniFi OS consoles / UniFi OS Server)
--     Used for: application info, site lookup, device ids, PoE port
--     POWER_CYCLE.
--
--   Classic controller API
--     /proxy/network/api/s/<site>/...     (UniFi OS consoles)
--     /api/s/<site>/...                   (self-hosted)
--     Used for: port and outlet tables, and the port_overrides /
--     outlet_overrides writes that switch PoE and PDU outlets on and off,
--     which the official API does not offer yet.
--
-- The classic API is authenticated with a local account session (cookie +
-- CSRF token) when a username is set, otherwise with the same API key.

local Http = require("http")

local Client = {}
Client.__index = Client

local UNIFI_OS = "UniFi OS Console"

function Client.new(options)
  local self = setmetatable({}, Client)
  self.http = assert(options.http, "http transport required")
  self.json = assert(options.json, "json required")
  self.log = options.log or { info = print, debug = function() end }
  self.config = {}
  self.session = nil        -- { cookie = "...", csrf = "..." }
  self.loginWaiters = nil   -- callbacks waiting on an in-flight login
  self.siteId = nil         -- official API site UUID
  return self
end

function Client:configure(config)
  local old = self.config
  self.config = config or {}
  local changed = old.host ~= self.config.host or old.port ~= self.config.port
    or old.controllerType ~= self.config.controllerType
    or old.username ~= self.config.username or old.password ~= self.config.password
    or old.site ~= self.config.site or old.apiKey ~= self.config.apiKey
  if changed then
    self.session = nil
    self.siteId = nil
  end
end

function Client:isUnifiOs()
  return self.config.controllerType ~= "Self-Hosted Network Application"
end

-- API keys exist only on UniFi OS (consoles and UniFi OS Server); the
-- legacy self-hosted Network application accepts local accounts only.
function Client:hasApiKey()
  return (self.config.apiKey or "") ~= "" and self:isUnifiOs()
end

function Client:hasAccount()
  return (self.config.username or "") ~= ""
end

function Client:isConfigured()
  return (self.config.host or "") ~= "" and (self:hasApiKey() or self:hasAccount())
end

function Client:siteName()
  local s = self.config.site or ""
  if s == "" then s = "default" end
  return s
end

function Client:baseUrl()
  local port = tonumber(self.config.port) or 443
  local host = self.config.host or ""
  if host:find(":") and not host:find("^%[") then host = "[" .. host .. "]" end
  if port == 443 then return "https://" .. host end
  return "https://" .. host .. ":" .. tostring(port)
end

function Client:classicUrl(path)
  local prefix = self:isUnifiOs() and "/proxy/network" or ""
  return self:baseUrl() .. prefix .. "/api/s/" .. self:siteName() .. path
end

function Client:officialUrl(path)
  return self:baseUrl() .. "/proxy/network/integration/v1" .. path
end

-------------------------------------------------------------------------------
-- Local account session (classic API)
-------------------------------------------------------------------------------

local function findCookie(setCookie, name)
  if not setCookie then return nil end
  local v = setCookie:match("%f[%w_]" .. name .. "=([^;%s,]+)")
  return v
end

function Client:login(callback)
  if self.loginWaiters then
    table.insert(self.loginWaiters, callback)
    return
  end
  self.loginWaiters = { callback }

  local unifiOs = self:isUnifiOs()
  local url = self:baseUrl() .. (unifiOs and "/api/auth/login" or "/api/login")
  local body = self.json.encode({
    username = self.config.username or "",
    password = self.config.password or "",
    rememberMe = unifiOs and true or nil,
    remember = (not unifiOs) and true or nil,
  })

  self.log.debug("Logging in to UniFi as " .. tostring(self.config.username))
  self.http:request("POST", url, body, {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
  }, function(code, _, headers, err)
    local waiters = self.loginWaiters or {}
    self.loginWaiters = nil

    local result
    if err then
      result = "cannot reach controller: " .. err
    elseif code == 401 or code == 403 or code == 400 then
      result = "login rejected (HTTP " .. code .. "); check username/password and use a local account without MFA"
    elseif code == 429 then
      result = "login rate-limited by the console (HTTP 429); wait a few minutes"
    elseif code < 200 or code >= 300 then
      result = "login failed (HTTP " .. tostring(code) .. ")"
    end

    if not result then
      local setCookie = Http.header(headers, "Set-Cookie")
      local cookie
      local csrf = Http.header(headers, "X-Updated-CSRF-Token") or Http.header(headers, "X-CSRF-Token")
      if unifiOs then
        local token = findCookie(setCookie, "TOKEN")
        if token then cookie = "TOKEN=" .. token end
      else
        local sess = findCookie(setCookie, "unifises")
        local csrfCookie = findCookie(setCookie, "csrf_token")
        if sess then
          cookie = "unifises=" .. sess
          if csrfCookie then cookie = cookie .. "; csrf_token=" .. csrfCookie end
        end
        csrf = csrf or csrfCookie
      end
      if not cookie then
        result = "login succeeded but no session cookie was returned"
      else
        self.session = { cookie = cookie, csrf = csrf }
        self.log.debug("UniFi session established")
      end
    end

    for _, cb in ipairs(waiters) do
      pcall(cb, result)
    end
  end)
end

-------------------------------------------------------------------------------
-- Requests
-------------------------------------------------------------------------------

function Client:classicHeaders(hasBody)
  local h = { ["Accept"] = "application/json" }
  if hasBody then h["Content-Type"] = "application/json" end
  if self:hasAccount() then
    if self.session then
      h["Cookie"] = self.session.cookie
      if self.session.csrf then h["X-CSRF-Token"] = self.session.csrf end
    end
  else
    h["X-API-KEY"] = self.config.apiKey
  end
  return h
end

local function describeHttp(code, err)
  if err then return "cannot reach controller: " .. err end
  return "HTTP " .. tostring(code)
end

-- callback(data, err, code). data is the classic envelope's data array.
function Client:classic(method, path, bodyTable, callback, isRetry)
  if not self:isConfigured() then
    callback(nil, "controller address and credentials are not set", 0)
    return
  end

  if self:hasAccount() and not self.session then
    self:login(function(loginErr)
      if loginErr then
        callback(nil, loginErr, 0)
      else
        self:classic(method, path, bodyTable, callback, true)
      end
    end)
    return
  end

  local body = bodyTable and self.json.encode(bodyTable) or nil
  self.http:request(method, self:classicUrl(path), body, self:classicHeaders(body ~= nil),
    function(code, data, headers, err)
      if self.session then
        local updated = Http.header(headers, "X-Updated-CSRF-Token")
        if updated and updated ~= "" then self.session.csrf = updated end
      end

      if (code == 401 or code == 403) and self:hasAccount() and not isRetry then
        self.log.debug("Session expired, logging in again")
        self.session = nil
        self:classic(method, path, bodyTable, callback, true)
        return
      end

      if err or code == 0 then
        callback(nil, describeHttp(code, err), code)
        return
      end
      if code == 401 or code == 403 then
        if self:hasAccount() then
          callback(nil, "access denied (HTTP " .. code .. "); the account needs Network admin rights", code)
        else
          callback(nil, "the console rejected the API key on the classic API (HTTP " .. code ..
            "); add a local Username and Password", code)
        end
        return
      end

      local decoded = self.json.tryDecode(data or "")
      local meta = type(decoded) == "table" and self.json.get(decoded, "meta") or nil
      if type(meta) == "table" and meta.rc and meta.rc ~= "ok" then
        callback(nil, "controller error: " .. tostring(self.json.get(meta, "msg") or meta.rc), code)
        return
      end
      if code < 200 or code >= 300 then
        callback(nil, describeHttp(code, nil), code)
        return
      end
      if type(decoded) ~= "table" then
        callback(nil, "invalid JSON from controller", code)
        return
      end
      callback(self.json.get(decoded, "data") or decoded, nil, code)
    end)
end

-- callback(result, err, code). Official API, API key only.
function Client:official(method, path, bodyTable, callback)
  if not self:hasApiKey() then
    callback(nil, "no API key", 0)
    return
  end
  local body = bodyTable and self.json.encode(bodyTable) or nil
  local headers = {
    ["Accept"] = "application/json",
    ["X-API-KEY"] = self.config.apiKey,
  }
  if body then headers["Content-Type"] = "application/json" end

  self.http:request(method, self:officialUrl(path), body, headers, function(code, data, _, err)
    if err or code == 0 then
      callback(nil, describeHttp(code, err), code)
      return
    end
    local decoded = self.json.tryDecode(data or "")
    if code == 401 or code == 403 then
      callback(nil, "API key rejected (HTTP " .. code .. ")", code)
      return
    end
    if code < 200 or code >= 300 then
      local msg = type(decoded) == "table" and self.json.get(decoded, "message") or nil
      callback(nil, "HTTP " .. code .. (msg and (": " .. tostring(msg)) or ""), code)
      return
    end
    callback(decoded or {}, nil, code)
  end)
end

-- Collects every page of an official list endpoint into one array.
function Client:officialList(path, callback, acc, offset)
  acc = acc or {}
  offset = offset or 0
  local sep = path:find("?", 1, true) and "&" or "?"
  self:official("GET", path .. sep .. "offset=" .. offset .. "&limit=200", nil, function(result, err, code)
    if err then callback(nil, err, code) return end
    local items = self.json.get(result, "data") or {}
    for _, item in ipairs(items) do acc[#acc + 1] = item end
    local total = tonumber(self.json.get(result, "totalCount")) or #acc
    local count = #items
    if count > 0 and #acc < total and offset + count < 10000 then
      self:officialList(path, callback, acc, offset + count)
    else
      callback(acc, nil, code)
    end
  end)
end

-------------------------------------------------------------------------------
-- Official API calls
-------------------------------------------------------------------------------

function Client:getInfo(callback)
  self:official("GET", "/info", nil, callback)
end

-- Resolves the configured site (internal name such as "default", display
-- name, or UUID) to the official site UUID.
function Client:resolveSiteId(callback)
  if self.siteId then callback(self.siteId, nil) return end
  self:officialList("/sites", function(sites, err)
    if err then callback(nil, err) return end
    local wanted = string.lower(self:siteName())
    local fallback
    for _, site in ipairs(sites) do
      local id = self.json.get(site, "id")
      local ref = string.lower(tostring(self.json.get(site, "internalReference") or ""))
      local name = string.lower(tostring(self.json.get(site, "name") or ""))
      if ref == wanted or string.lower(tostring(id)) == wanted then
        self.siteId = id
        callback(id, nil)
        return
      end
      if name == wanted then fallback = id end
    end
    if fallback then
      self.siteId = fallback
      callback(fallback, nil)
      return
    end
    if #sites == 1 then
      self.siteId = self.json.get(sites[1], "id")
      callback(self.siteId, nil)
      return
    end
    callback(nil, "site '" .. self:siteName() .. "' not found")
  end)
end

-- callback(map, err) where map is lower-case MAC -> official device id.
function Client:getOfficialDeviceIds(callback)
  self:resolveSiteId(function(siteId, err)
    if err then callback(nil, err) return end
    self:officialList("/sites/" .. siteId .. "/devices", function(devices, listErr)
      if listErr then callback(nil, listErr) return end
      local map = {}
      for _, d in ipairs(devices) do
        local mac = self.json.get(d, "macAddress")
        local id = self.json.get(d, "id")
        if mac and id then map[string.lower(mac)] = id end
      end
      callback(map, nil)
    end)
  end)
end

function Client:powerCyclePortOfficial(deviceId, portIdx, callback)
  self:resolveSiteId(function(siteId, err)
    if err then callback(false, err) return end
    local path = "/sites/" .. siteId .. "/devices/" .. deviceId .. "/interfaces/ports/" .. tostring(portIdx) .. "/actions"
    self:official("POST", path, { action = "POWER_CYCLE" }, function(_, postErr)
      callback(postErr == nil, postErr)
    end)
  end)
end

-------------------------------------------------------------------------------
-- Classic API calls
-------------------------------------------------------------------------------

-- All adopted devices, or only those whose MAC is in macs.
function Client:getDevices(macs, callback)
  if macs and #macs > 0 then
    local list = self.json.array({})
    for i, m in ipairs(macs) do list[i] = m end
    self:classic("POST", "/stat/device", { macs = list }, callback)
  else
    self:classic("GET", "/stat/device", nil, callback)
  end
end

function Client:updateDevice(legacyId, payload, callback)
  self:classic("PUT", "/rest/device/" .. tostring(legacyId), payload, function(_, err)
    callback(err == nil, err)
  end)
end

function Client:powerCyclePortClassic(mac, portIdx, callback)
  self:classic("POST", "/cmd/devmgr", { cmd = "power-cycle", mac = mac, port_idx = portIdx }, function(_, err)
    callback(err == nil, err)
  end)
end

return Client
