-- UniFi Network (Open Source) - master driver
--
-- Connects to a UniFi Network console and serves the UniFi PDU Outlet and
-- UniFi PoE Port child drivers bound to its "UniFi Network" connection.
--
-- Children talk to this driver with C4:SendToDevice:
--   UNIFI_REGISTER    {DEVICE_ID, KIND, MAC, INDEX}     child selection
--   UNIFI_UNREGISTER  {DEVICE_ID}
--   UNIFI_COMMAND     {DEVICE_ID, KIND, MAC, INDEX, ACTION=ON|OFF|CYCLE,
--                      MODE, CYCLE_METHOD=switch|offon, OFF_SECONDS}
-- and this driver answers with:
--   UNIFI_CATALOG     {KIND, JSON}   devices + outlets/ports for the lists
--   UNIFI_STATE       {JSON}         state of the child's selected item
--   UNIFI_RESULT      {ACTION, OK, MESSAGE}

JSON = require("json")
local C4Utils = require("c4_utils")
local Http = require("http")
local Client = require("unifi_client")
local Model = require("unifi_model")

DRIVER_VERSION = "1.0.1"

local LINK_BINDING_ID = 1
local FULL_SCAN_INTERVAL_S = 300
local PENDING_HOLD_S = 45
local SWITCH_CYCLE_HOLD_MS = 10000
local DEFAULT_POLL_S = 10

local log = C4Utils.createLogger("UniFi Network: ")
local updateProperty = C4Utils.updateProperty

Model.init(JSON)

local http = Http.new({ logDebug = log.debug })
local client = Client.new({ http = http, json = JSON, log = log })

local state = {
  devices = {},        -- mac -> parsed device (Model.parseDevice)
  children = {},       -- child device id -> { kind, mac, index, lastCatalog, lastState }
  officialIds = {},    -- mac -> official API device id
  pending = {},        -- item key -> { on, expires }
  cycling = {},        -- item key -> true while a power cycle runs
  queue = {},
  jobRunning = false,
  polling = false,
  pollQueued = false,
  pollTimer = nil,
  kickTimer = nil,
  lastFullScan = 0,
  connected = nil,
  statusText = "Starting",
}

local function now() return os.time() end

local function itemKey(kind, mac, index)
  return tostring(kind) .. "|" .. tostring(mac) .. "|" .. tostring(index)
end

local function setStatus(text)
  state.statusText = text
  updateProperty("Status", text)
end

local function setConnected(ok, err)
  local was = state.connected
  state.connected = ok
  if ok then
    local pdus, switches = 0, 0
    for _, dev in pairs(state.devices) do
      if #dev.outlets > 0 then pdus = pdus + 1 end
      if #dev.ports > 0 then switches = switches + 1 end
    end
    updateProperty("PDU Devices Found", pdus)
    updateProperty("PoE Switches Found", switches)
    setStatus("Connected")
    if was ~= true then
      log.info("Connected to UniFi Network")
      C4Utils.fireEvent("Connected")
    end
  else
    setStatus("Error: " .. tostring(err))
    if was ~= false then
      log.info("UniFi Network error: " .. tostring(err))
      C4Utils.fireEvent("Connection Lost")
    end
  end
end

-------------------------------------------------------------------------------
-- Children
-------------------------------------------------------------------------------

local function sendToChild(id, cmd, params)
  pcall(function() C4:SendToDevice(tonumber(id), cmd, params) end)
end

local function updateLinkedCount()
  local n = 0
  for _ in pairs(state.children) do n = n + 1 end
  updateProperty("Linked Drivers", n)
end

local function sortedDevices()
  local list = {}
  for _, dev in pairs(state.devices) do list[#list + 1] = dev end
  table.sort(list, function(a, b)
    if string.lower(a.name) == string.lower(b.name) then return a.mac < b.mac end
    return string.lower(a.name) < string.lower(b.name)
  end)
  return list
end

local catalogCache = {}

local function buildCatalog(kind)
  local devices = JSON.array({})
  for _, dev in ipairs(sortedDevices()) do
    local source = (kind == "outlet") and dev.outlets or dev.ports
    if #source > 0 then
      local items = JSON.array({})
      for _, item in ipairs(source) do
        items[#items + 1] = { index = item.index, name = item.name, uplink = item.uplink or nil }
      end
      devices[#devices + 1] = { mac = dev.mac, name = dev.name, model = dev.model, items = items }
    end
  end
  return JSON.encode({ kind = kind, devices = devices })
end

local function childState(child)
  local st = {
    connected = state.connected == true,
    status = state.statusText,
    found = false,
  }
  if not child.mac or not child.index then
    st.reason = "Nothing selected"
    return st
  end
  local dev = state.devices[child.mac]
  if not dev then
    st.reason = (state.connected and "Device not found" or "Waiting for UniFi Network")
    return st
  end
  local item = Model.findItem(dev, child.kind, child.index)
  if not item then
    st.reason = (child.kind == "outlet" and "Outlet" or "Port") .. " not found on device"
    return st
  end

  local key = itemKey(child.kind, child.mac, child.index)
  local on = item.on
  local pending = state.pending[key]
  if pending then
    if pending.on == item.on or now() >= pending.expires then
      state.pending[key] = nil
    else
      on = pending.on
      st.pending = true
    end
  end

  st.found = true
  st.online = dev.online
  st.deviceName = dev.name
  st.model = dev.model
  st.name = item.name
  st.on = on
  st.watts = item.watts
  st.cycling = state.cycling[key] == true
  if child.kind == "outlet" then
    st.volts = item.volts
    st.amps = item.amps
  else
    st.poeMode = item.poeMode
    st.delivering = item.delivering
    st.up = item.up
    st.speed = item.speed
    st.uplink = item.uplink
    st.caps = item.caps
  end
  return st
end

local function pushToChild(id, force)
  local child = state.children[id]
  if not child then return end
  local catalog = catalogCache[child.kind] or buildCatalog(child.kind)
  if force or child.lastCatalog ~= catalog then
    child.lastCatalog = catalog
    sendToChild(id, "UNIFI_CATALOG", { KIND = child.kind, JSON = catalog })
  end
  local st = JSON.encode(childState(child))
  if force or child.lastState ~= st then
    child.lastState = st
    sendToChild(id, "UNIFI_STATE", { JSON = st })
  end
end

local function pushAll()
  catalogCache = { outlet = buildCatalog("outlet"), poe = buildCatalog("poe") }
  for id, _ in pairs(state.children) do pushToChild(id, false) end
end

local function selectedMacs()
  local seen, list = {}, {}
  for _, child in pairs(state.children) do
    if child.mac and not seen[child.mac] then
      seen[child.mac] = true
      list[#list + 1] = child.mac
    end
  end
  table.sort(list)
  return list
end

-------------------------------------------------------------------------------
-- Polling
-------------------------------------------------------------------------------

local function readConfig()
  local p = Properties or {}
  client:configure({
    controllerType = p["Controller Type"] or "UniFi OS Console",
    host = C4Utils.trim(p["Controller Address"]),
    port = tonumber(p["Controller Port"]) or 443,
    apiKey = C4Utils.trim(p["API Key"]),
    username = C4Utils.trim(p["Username"]),
    password = p["Password"] or "",
    site = C4Utils.trim(p["Site"]),
  })
  http:setVerifySsl(p["Verify SSL Certificate"] == "Yes")
end

local function refreshOfficial()
  if not client:hasApiKey() then
    local why = "Not used (no API key)"
    if not client:isUnifiOs() then why = "Not available on the self-hosted Network application" end
    updateProperty("Official API", why)
    return
  end
  client:getInfo(function(info, err)
    if err then
      updateProperty("Official API", "Error: " .. err)
      return
    end
    local version = JSON.get(info, "applicationVersion")
    if version then updateProperty("Network Application", "UniFi Network " .. tostring(version)) end
    client:getOfficialDeviceIds(function(map, mapErr)
      if mapErr then
        updateProperty("Official API", "Error: " .. mapErr)
        return
      end
      state.officialIds = map
      updateProperty("Site ID", client.siteId or "")
      updateProperty("Official API", "Connected")
    end)
  end)
end

local poll

local function finishPoll()
  state.polling = false
  if state.pollQueued then
    state.pollQueued = false
    poll(false)
  end
end

poll = function(forceFull)
  if not client:isConfigured() then
    setStatus("Not configured: set Controller Address and an API Key or Username/Password")
    return
  end
  if state.polling then
    state.pollQueued = true
    return
  end

  local full = forceFull or next(state.devices) == nil
    or (now() - state.lastFullScan) >= FULL_SCAN_INTERVAL_S
  local macs
  if not full then
    macs = selectedMacs()
    if #macs == 0 then return end
  end

  state.polling = true
  client:getDevices(macs, function(data, err)
    if err then
      setConnected(false, err)
      pushAll()
      finishPoll()
      return
    end

    if full then
      state.devices = {}
      state.lastFullScan = now()
    end
    local returned = {}
    for _, raw in ipairs(data or {}) do
      local mac = JSON.get(raw, "mac")
      if mac then
        mac = string.lower(mac)
        returned[mac] = true
        state.devices[mac] = Model.parseDevice(raw)
      end
    end
    if macs then
      for _, mac in ipairs(macs) do
        if not returned[mac] then state.devices[mac] = nil end
      end
    end

    setConnected(true)
    if full then refreshOfficial() end
    pushAll()
    finishPoll()
  end)
end

local function pollSoon(ms, full)
  state.kickTimer = C4Utils.cancelTimer(state.kickTimer)
  state.kickTimer = C4Utils.setTimer(ms or 1000, function()
    state.kickTimer = nil
    poll(full)
  end)
end

local function startPolling()
  state.pollTimer = C4Utils.cancelTimer(state.pollTimer)
  local seconds = tonumber(Properties and Properties["Poll Interval (seconds)"]) or DEFAULT_POLL_S
  if seconds < 5 then seconds = 5 end
  state.pollTimer = C4Utils.setTimer(seconds * 1000, function() poll(false) end, true)
end

-------------------------------------------------------------------------------
-- Command queue: one controller write at a time, so read-modify-write of
-- the override arrays never races another write to the same device.
-------------------------------------------------------------------------------

local runQueue

local function enqueue(job)
  table.insert(state.queue, job)
  runQueue()
end

local function report(job, ok, message)
  if job.childId then
    sendToChild(job.childId, "UNIFI_RESULT", {
      ACTION = job.action,
      OK = ok and "1" or "0",
      MESSAGE = message or "",
    })
  end
  if not ok then log.info(job.label .. " failed: " .. tostring(message)) end
end

local function protectUplinks()
  return not Properties or Properties["Protect Uplink Ports"] ~= "No"
end

local function fetchRaw(mac, callback)
  client:getDevices({ mac }, function(data, err)
    if err then callback(nil, err) return end
    for _, raw in ipairs(data or {}) do
      if string.lower(JSON.get(raw, "mac") or "") == mac then
        callback(raw, nil)
        return
      end
    end
    callback(nil, "device " .. mac .. " not found on the controller")
  end)
end

-- Turns one outlet or PoE port on or off. done(ok, err)
local function runSet(job, done)
  fetchRaw(job.mac, function(raw, err)
    if err then done(false, err) return end

    local payload
    if job.kind == "outlet" then
      local overrides, buildErr = Model.buildOutletOverrides(raw, job.index, job.on)
      if not overrides then done(false, buildErr) return end
      payload = { outlet_overrides = overrides }
    else
      local port = Model.findRawPort(raw, job.index)
      if port and not job.on and protectUplinks() and JSON.get(port, "is_uplink") == true then
        done(false, "port " .. job.index .. " is the switch uplink (Protect Uplink Ports is on)")
        return
      end
      local mode = "off"
      if job.on then
        mode = Model.isValidOnMode(job.mode) and job.mode
          or Model.defaultPoeOnMode(port and JSON.get(port, "poe_caps"))
      end
      local overrides, buildErr = Model.buildPortOverrides(raw, job.index, mode)
      if not overrides then done(false, buildErr) return end
      payload = { port_overrides = overrides }
    end

    local legacyId = JSON.get(raw, "_id")
    if not legacyId then done(false, "device record has no _id") return end

    client:updateDevice(legacyId, payload, function(ok, putErr)
      if not ok then done(false, putErr) return end
      state.devices[job.mac] = Model.parseDevice(raw) or state.devices[job.mac]
      state.pending[itemKey(job.kind, job.mac, job.index)] = { on = job.on, expires = now() + PENDING_HOLD_S }
      pushAll()
      pollSoon(3000, false)
      done(true)
    end)
  end)
end

-- Switch-side PoE power cycle: official API first, classic devmgr fallback.
local function runSwitchCycle(job, done)
  fetchRaw(job.mac, function(raw, err)
    if err then done(false, err) return end
    local port = Model.findRawPort(raw, job.index)
    if not port or JSON.get(port, "port_poe") ~= true then
      done(false, "port " .. job.index .. " has no PoE")
      return
    end
    if protectUplinks() and JSON.get(port, "is_uplink") == true then
      done(false, "port " .. job.index .. " is the switch uplink (Protect Uplink Ports is on)")
      return
    end
    if tostring(JSON.get(port, "poe_mode") or "off") == "off" then
      done(false, "PoE is off on port " .. job.index .. "; turn it on instead")
      return
    end

    local function classic()
      client:powerCyclePortClassic(job.mac, job.index, function(ok, cErr)
        done(ok, cErr)
      end)
    end

    local officialId = state.officialIds[job.mac]
    if client:hasApiKey() and officialId then
      client:powerCyclePortOfficial(officialId, job.index, function(ok, oErr)
        if ok then done(true) return end
        log.debug("Official POWER_CYCLE failed (" .. tostring(oErr) .. "), trying classic API")
        classic()
      end)
    else
      classic()
    end
  end)
end

runQueue = function()
  if state.jobRunning or #state.queue == 0 then return end
  state.jobRunning = true
  local job = table.remove(state.queue, 1)
  log.debug("Running " .. job.label)

  local runner = (job.op == "switch_cycle") and runSwitchCycle or runSet
  local ok, err = pcall(runner, job, function(success, message)
    state.jobRunning = false
    if job.onDone then
      job.onDone(success, message)
    else
      report(job, success, message)
    end
    runQueue()
  end)
  if not ok then
    state.jobRunning = false
    report(job, false, "internal error: " .. tostring(err))
    runQueue()
  end
end

local function startCycle(base, offSeconds)
  local key = itemKey(base.kind, base.mac, base.index)
  if state.cycling[key] then
    report(base, false, "a power cycle is already running")
    return
  end
  state.cycling[key] = true
  pushAll()

  local function finish(ok, message)
    state.cycling[key] = nil
    pushAll()
    report(base, ok, message)
  end

  enqueue({
    op = "set", kind = base.kind, mac = base.mac, index = base.index, on = false,
    label = base.label .. " (off)", action = base.action, childId = base.childId,
    onDone = function(ok, message)
      if not ok then finish(false, message) return end
      C4Utils.setTimer(offSeconds * 1000, function()
        enqueue({
          op = "set", kind = base.kind, mac = base.mac, index = base.index, on = true,
          mode = base.mode, label = base.label .. " (on)", action = base.action,
          childId = base.childId, onDone = finish,
        })
      end)
    end,
  })
end

local function handleChildCommand(params)
  local childId = tonumber(params.DEVICE_ID)
  local kind = params.KIND == "outlet" and "outlet" or "poe"
  local mac = C4Utils.normalizeMac(params.MAC)
  local index = tonumber(params.INDEX)
  local action = tostring(params.ACTION or "")

  local base = {
    kind = kind, mac = mac, index = index, action = action, childId = childId,
    mode = params.MODE,
    label = (kind == "outlet" and "Outlet " or "PoE port ") .. tostring(index) .. " on " .. tostring(mac)
      .. " " .. action,
  }

  if not mac or not index then
    report(base, false, "no device/" .. (kind == "outlet" and "outlet" or "port") .. " selected")
    return
  end
  if not client:isConfigured() then
    report(base, false, "UniFi Network driver is not configured")
    return
  end

  log.info(base.label)
  if action == "ON" or action == "OFF" then
    base.op = "set"
    base.on = (action == "ON")
    enqueue(base)
  elseif action == "CYCLE" then
    local offSeconds = tonumber(params.OFF_SECONDS) or 5
    if offSeconds < 1 then offSeconds = 1 end
    if kind == "poe" and params.CYCLE_METHOD ~= "offon" then
      local key = itemKey(kind, mac, index)
      base.op = "switch_cycle"
      base.onDone = function(ok, message)
        report(base, ok, message)
        if ok then
          state.cycling[key] = true
          pushAll()
          C4Utils.setTimer(SWITCH_CYCLE_HOLD_MS, function()
            state.cycling[key] = nil
            pushAll()
            pollSoon(500, false)
          end)
        end
      end
      enqueue(base)
    else
      startCycle(base, offSeconds)
    end
  else
    report(base, false, "unknown action " .. action)
  end
end

-------------------------------------------------------------------------------
-- Logging helpers
-------------------------------------------------------------------------------

local function logDeviceList()
  local devices = sortedDevices()
  if #devices == 0 then
    log.info("No PDU or PoE devices known yet")
    return
  end
  for _, dev in ipairs(devices) do
    log.info(string.format("%s (%s) %s %s", dev.name, dev.model, dev.mac, dev.online and "online" or "OFFLINE"))
    for _, o in ipairs(dev.outlets) do
      log.info(string.format("   outlet %d  %-24s %s %s", o.index, o.name, o.on and "ON " or "OFF",
        C4Utils.formatWatts(o.watts)))
    end
    for _, p in ipairs(dev.ports) do
      log.info(string.format("   port %2d   %-24s poe=%s%s %s", p.index, p.name, p.poeMode,
        p.uplink and " (uplink)" or "", C4Utils.formatWatts(p.watts)))
    end
  end
end

-------------------------------------------------------------------------------
-- Control4 entry points
-------------------------------------------------------------------------------

local CONNECTION_PROPERTIES = {
  ["Controller Type"] = true, ["Controller Address"] = true, ["Controller Port"] = true,
  ["API Key"] = true, ["Username"] = true, ["Password"] = true, ["Site"] = true,
  ["Verify SSL Certificate"] = true,
}

local function helloBoundChildren()
  local ok, devices = pcall(function()
    return C4:GetBoundConsumerDevices(C4:GetDeviceID(), LINK_BINDING_ID)
  end)
  if ok and type(devices) == "table" then
    for id, _ in pairs(devices) do sendToChild(id, "UNIFI_HELLO", {}) end
  end
end

local function initialize()
  updateProperty("Driver Version", DRIVER_VERSION)
  readConfig()
  updateLinkedCount()
  startPolling()
  pollSoon(1000, true)
  helloBoundChildren()
end

function OnDriverInit()
  log.info("Driver initialized")
end

function OnDriverLateInit()
  initialize()
end

function OnDriverDestroyed()
  state.pollTimer = C4Utils.cancelTimer(state.pollTimer)
  state.kickTimer = C4Utils.cancelTimer(state.kickTimer)
end

function OnPropertyChanged(name)
  log.debug("Property changed: " .. tostring(name))
  if CONNECTION_PROPERTIES[name] then
    readConfig()
    state.connected = nil
    state.officialIds = {}
    state.lastFullScan = 0
    pollSoon(1500, true)
  elseif name == "Poll Interval (seconds)" then
    startPolling()
  end
end

function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceId)
  if idBinding ~= LINK_BINDING_ID then return end
  local id = tonumber(otherDeviceId)
  if not id then return end
  if bIsBound then
    -- Ask the new child to register its kind and selection.
    sendToChild(id, "UNIFI_HELLO", {})
  else
    state.children[id] = nil
  end
  updateLinkedCount()
end

local HANDLERS = {}

HANDLERS.UNIFI_REGISTER = function(params)
  local id = tonumber(params.DEVICE_ID)
  if not id then return end
  local child = state.children[id] or {}
  local mac = C4Utils.normalizeMac(params.MAC)
  local index = tonumber(params.INDEX)
  local newSelection = mac ~= child.mac
  child.kind = params.KIND == "outlet" and "outlet" or "poe"
  child.mac = mac
  child.index = index
  child.lastCatalog, child.lastState = nil, nil
  state.children[id] = child
  updateLinkedCount()
  if not catalogCache[child.kind] then catalogCache[child.kind] = buildCatalog(child.kind) end
  pushToChild(id, true)
  if mac and newSelection and not state.devices[mac] then pollSoon(500, false) end
end

HANDLERS.UNIFI_UNREGISTER = function(params)
  local id = tonumber(params.DEVICE_ID)
  if id then state.children[id] = nil end
  updateLinkedCount()
end

HANDLERS.UNIFI_COMMAND = handleChildCommand

HANDLERS["Test Connection"] = function()
  readConfig()
  state.connected = nil
  poll(true)
end

HANDLERS["Refresh Devices"] = function()
  poll(true)
end

HANDLERS["Log Device List"] = function()
  logDeviceList()
end

function ExecuteCommand(strCommand, tParams)
  C4Utils.dispatch(HANDLERS, strCommand, tParams, log)
end

-- Exposed for the off-controller test harness.
UNIFI_TEST = { state = state, client = client, poll = poll }
