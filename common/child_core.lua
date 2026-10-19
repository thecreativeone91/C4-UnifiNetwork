-- Shared logic for the UniFi PDU Outlet and UniFi PoE Port child drivers
-- (MIT License).
--
-- Each child binds to the UniFi Network master driver on connection 1,
-- picks one device and one outlet/port from lists the master fills in, and
-- forwards power commands to the master. It also offers:
--   connection 2  RELAY           (CLOSE = power on, OPEN = power off,
--                                  TOGGLE, TRIGGER = power cycle)
--   connection 3  CONTACT_SENSOR  (closed while powered)

JSON = require("json")
local C4Utils = require("c4_utils")

local ChildCore = {}

local LINK_BINDING_ID = 1
local RELAY_BINDING_ID = 2
local CONTACT_BINDING_ID = 3
local NONE = "(none)"
local WATCHDOG_MS = 30000
local SILENCE_LIMIT_S = 90

function ChildCore.run(cfg)
  local kind = cfg.kind                     -- "outlet" | "poe"
  local itemWord = cfg.itemWord             -- "Outlet" | "Port"
  local itemProperty = cfg.itemProperty     -- "Outlet" | "PoE Port"
  local nameProperty = cfg.nameProperty     -- "Outlet Name" | "Port Name"

  local log = C4Utils.createLogger(cfg.logPrefix)
  local updateProperty = C4Utils.updateProperty

  local state = {
    catalog = nil,         -- decoded UNIFI_CATALOG
    st = nil,              -- decoded UNIFI_STATE
    mac = nil,
    index = nil,
    lastOn = nil,
    lastOnline = nil,
    lastMessage = 0,
    suppress = 0,          -- >0 while we update our own list properties
    watchdog = nil,
  }

  local function myId() return C4:GetDeviceID() end

  local function masterId()
    local ok, id = pcall(function() return C4:GetBoundProviderDevice(myId(), LINK_BINDING_ID) end)
    id = ok and tonumber(id) or nil
    if id == 0 then id = nil end
    return id
  end

  local function setOwnProperty(name, value)
    state.suppress = state.suppress + 1
    updateProperty(name, value)
    state.suppress = state.suppress - 1
  end

  local function setList(name, values, current)
    state.suppress = state.suppress + 1
    pcall(function() C4:UpdatePropertyList(name, table.concat(values, ","), current) end)
    pcall(function() C4:UpdateProperty(name, current) end)
    state.suppress = state.suppress - 1
  end

  local function saveSelection()
    C4Utils.persistSet("mac", state.mac)
    C4Utils.persistSet("index", state.index)
  end

  local function deviceLabel(dev)
    local model = C4Utils.listSafe(dev.model)
    return C4Utils.listSafe(dev.name) .. (model ~= "" and (" (" .. model .. ")") or "") .. " [" .. dev.mac .. "]"
  end

  local function itemLabel(item)
    return tostring(item.index) .. " - " .. C4Utils.listSafe(item.name) .. (item.uplink and " (uplink)" or "")
  end

  local function findCatalogDevice(mac)
    if not state.catalog or not mac then return nil end
    for _, dev in ipairs(JSON.get(state.catalog, "devices") or {}) do
      if dev.mac == mac then return dev end
    end
    return nil
  end

  -----------------------------------------------------------------------------
  -- Talking to the master
  -----------------------------------------------------------------------------

  local function setStatus(text) updateProperty("Status", text) end

  local function register()
    local id = masterId()
    if not id then
      setStatus("Not connected: bind this driver to the UniFi Network driver")
      return
    end
    pcall(function()
      C4:SendToDevice(id, "UNIFI_REGISTER", {
        DEVICE_ID = tostring(myId()),
        KIND = kind,
        MAC = state.mac or "",
        INDEX = state.index and tostring(state.index) or "",
      })
    end)
  end

  local function fail(message)
    log.info("Command failed: " .. tostring(message))
    updateProperty("Last Error", message)
    C4Utils.fireEvent("Command Failed")
  end

  local function sendCommand(action)
    if not state.mac or not state.index then
      fail("No device and " .. string.lower(itemWord) .. " selected")
      return
    end
    local id = masterId()
    if not id then
      fail("Not bound to the UniFi Network driver")
      return
    end
    local params = {
      DEVICE_ID = tostring(myId()),
      KIND = kind,
      MAC = state.mac,
      INDEX = tostring(state.index),
      ACTION = action,
      OFF_SECONDS = tostring(tonumber(Properties["Power Cycle Off Time (seconds)"]) or 5),
    }
    if kind == "poe" then
      params.MODE = C4Utils.persistGet("lastMode:" .. state.mac .. ":" .. state.index, "")
      params.CYCLE_METHOD = (Properties["Power Cycle Method"] == "Off Then On") and "offon" or "switch"
    end
    log.info("Sending " .. action)
    if action == "CYCLE" then C4Utils.fireEvent("Power Cycle Started") end
    pcall(function() C4:SendToDevice(id, "UNIFI_COMMAND", params) end)
  end

  local function currentlyOn()
    return state.st and state.st.found and state.st.on == true
  end

  local function powerOn() sendCommand("ON") end
  local function powerOff() sendCommand("OFF") end
  local function toggle() sendCommand(currentlyOn() and "OFF" or "ON") end
  local function cycle() sendCommand("CYCLE") end

  -----------------------------------------------------------------------------
  -- Lists
  -----------------------------------------------------------------------------

  local function refreshItemList()
    local values = { NONE }
    local current = NONE
    local dev = findCatalogDevice(state.mac)
    if dev then
      for _, item in ipairs(dev.items or {}) do
        local label = itemLabel(item)
        values[#values + 1] = label
        if tonumber(item.index) == state.index then current = label end
      end
    elseif state.index then
      current = tostring(state.index) .. " - (waiting for device)"
      values[#values + 1] = current
    end
    setList(itemProperty, values, current)
  end

  local function refreshDeviceList()
    local values = { NONE }
    local current = NONE
    for _, dev in ipairs(state.catalog and (JSON.get(state.catalog, "devices") or {}) or {}) do
      local label = deviceLabel(dev)
      values[#values + 1] = label
      if dev.mac == state.mac then current = label end
    end
    if state.mac and current == NONE then
      current = "Not found [" .. state.mac .. "]"
      values[#values + 1] = current
    end
    setList("UniFi Device", values, current)
    refreshItemList()
  end

  -----------------------------------------------------------------------------
  -- State from the master
  -----------------------------------------------------------------------------

  local function notifyBindings(on)
    pcall(function() C4:SendToProxy(RELAY_BINDING_ID, on and "CLOSED" or "OPENED", {}, "NOTIFY") end)
    pcall(function() C4:SendToProxy(CONTACT_BINDING_ID, on and "CLOSED" or "OPENED", {}, "NOTIFY") end)
  end

  local function yesNo(v) return v and "Yes" or "No" end

  local function applyState(st)
    state.st = st

    if not st.connected then
      setStatus("UniFi Network: " .. tostring(st.status or "not connected"))
    elseif not st.found then
      setStatus(st.reason or "Not found")
    elseif not st.online then
      setStatus("Device offline")
    elseif st.cycling then
      setStatus("Power cycling")
    elseif st.pending then
      setStatus("Applying change")
    else
      setStatus("OK")
    end

    if not st.found then
      updateProperty("Device Status", st.connected and "Not found" or "Unknown")
      return
    end

    updateProperty("Device Status", st.online and "Online" or "Offline")
    updateProperty(nameProperty, st.name or "")
    updateProperty("Power State", st.on and "On" or "Off")
    updateProperty("Power Draw", C4Utils.formatWatts(st.watts))
    if kind == "poe" then
      updateProperty("PoE Mode", st.poeMode or "")
      updateProperty("PoE Delivering Power", yesNo(st.delivering))
      local link = "Down"
      if st.up then link = "Up" .. (st.speed and st.speed > 0 and (" (" .. st.speed .. " Mbps)") or "") end
      updateProperty("Link", link)
      updateProperty("Uplink Port", yesNo(st.uplink))
      if st.on and st.poeMode and st.poeMode ~= "off" then
        C4Utils.persistSet("lastMode:" .. state.mac .. ":" .. state.index, st.poeMode)
      end
    else
      updateProperty("Voltage", st.volts and string.format("%.1f V", st.volts) or "")
      updateProperty("Current", st.amps and string.format("%.2f A", st.amps) or "")
    end

    C4Utils.setVariable("POWER_STATE", st.on and "1" or "0")
    C4Utils.setVariable("POWER_WATTS", st.watts and string.format("%.1f", st.watts) or "0")
    C4Utils.setVariable("DEVICE_ONLINE", st.online and "1" or "0")

    if state.lastOn ~= st.on then
      local first = state.lastOn == nil
      state.lastOn = st.on
      notifyBindings(st.on)
      if not first then
        C4Utils.fireEvent(st.on and "Power Turned On" or "Power Turned Off")
      end
    end
    if state.lastOnline ~= st.online then
      local first = state.lastOnline == nil
      state.lastOnline = st.online
      if not first then
        C4Utils.fireEvent(st.online and "Device Online" or "Device Offline")
      end
    end
  end

  local function resetItemState()
    state.st = nil
    state.lastOn = nil
    state.lastOnline = nil
    for _, name in ipairs({ nameProperty, "Power State", "Power Draw", "Device Status" }) do
      updateProperty(name, "")
    end
  end

  -----------------------------------------------------------------------------
  -- Control4 entry points
  -----------------------------------------------------------------------------

  local HANDLERS = {}

  HANDLERS.UNIFI_HELLO = function() register() end

  HANDLERS.UNIFI_CATALOG = function(params)
    if params.KIND ~= kind then return end
    local catalog = JSON.tryDecode(params.JSON or "")
    if type(catalog) ~= "table" then return end
    state.lastMessage = os.time()
    state.catalog = catalog
    refreshDeviceList()
  end

  HANDLERS.UNIFI_STATE = function(params)
    local st = JSON.tryDecode(params.JSON or "")
    if type(st) ~= "table" then return end
    state.lastMessage = os.time()
    -- Plain booleans/numbers only; drop json.null.
    for k, v in pairs(st) do if v == JSON.null then st[k] = nil end end
    applyState(st)
  end

  HANDLERS.UNIFI_RESULT = function(params)
    if params.OK == "1" then
      updateProperty("Last Error", "")
      if params.ACTION == "CYCLE" then C4Utils.fireEvent("Power Cycle Complete") end
    else
      fail(params.MESSAGE or "unknown error")
    end
  end

  HANDLERS["Power On"] = powerOn
  HANDLERS["Power Off"] = powerOff
  HANDLERS["Toggle Power"] = toggle
  HANDLERS["Power Cycle"] = cycle
  HANDLERS["Refresh"] = function() register() end

  function ExecuteCommand(strCommand, tParams)
    C4Utils.dispatch(HANDLERS, strCommand, tParams, log)
  end

  function ReceivedFromProxy(idBinding, strCommand, tParams)
    if idBinding ~= RELAY_BINDING_ID then return end
    log.debug("Relay command: " .. tostring(strCommand))
    if strCommand == "CLOSE" then powerOn()
    elseif strCommand == "OPEN" then powerOff()
    elseif strCommand == "TOGGLE" then toggle()
    elseif strCommand == "TRIGGER" then cycle()
    end
  end

  function OnPropertyChanged(name)
    if state.suppress > 0 then return end
    local value = Properties[name] or ""
    if name == "UniFi Device" then
      local mac = C4Utils.normalizeMac(value:match("%[([%x:]+)%]$"))
      if value == NONE then mac = nil end
      if mac ~= state.mac then
        state.mac = mac
        state.index = nil
        saveSelection()
        resetItemState()
        refreshItemList()
        register()
      end
    elseif name == itemProperty then
      local index = tonumber(value:match("^(%d+)"))
      if index ~= state.index then
        state.index = index
        saveSelection()
        resetItemState()
        register()
      end
    end
  end

  function OnBindingChanged(idBinding, _, bIsBound)
    if idBinding == LINK_BINDING_ID then
      if bIsBound then
        C4Utils.setTimer(500, function() register() end)
      else
        state.catalog = nil
        setStatus("Not connected: bind this driver to the UniFi Network driver")
      end
    elseif bIsBound and (idBinding == RELAY_BINDING_ID or idBinding == CONTACT_BINDING_ID) and state.lastOn ~= nil then
      C4Utils.setTimer(500, function() notifyBindings(state.lastOn) end)
    end
  end

  function OnDriverInit()
    log.info("Driver initialized")
  end

  function OnDriverLateInit()
    updateProperty("Driver Version", cfg.version)
    state.mac = C4Utils.normalizeMac(C4Utils.persistGet("mac", nil))
    state.index = tonumber(C4Utils.persistGet("index", nil))
    C4Utils.ensureVariable("POWER_STATE", "0", "BOOL")
    C4Utils.ensureVariable("POWER_WATTS", "0", "STRING")
    C4Utils.ensureVariable("DEVICE_ONLINE", "0", "BOOL")
    refreshDeviceList()
    register()
    state.watchdog = C4Utils.setTimer(WATCHDOG_MS, function()
      if os.time() - state.lastMessage > SILENCE_LIMIT_S then register() end
    end, true)
  end

  function OnDriverDestroyed()
    state.watchdog = C4Utils.cancelTimer(state.watchdog)
    local id = masterId()
    if id then
      pcall(function() C4:SendToDevice(id, "UNIFI_UNREGISTER", { DEVICE_ID = tostring(myId()) }) end)
    end
  end

  return state
end

return ChildCore
