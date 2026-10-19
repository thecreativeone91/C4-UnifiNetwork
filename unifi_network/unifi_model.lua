-- Turns classic /stat/device records into the small model the child drivers
-- use, and builds the override arrays written back to the controller.
--
-- port_overrides and outlet_overrides are treated by the controller as the
-- complete desired state for the device: an entry left out of the array
-- reverts that port or outlet to its defaults (port profile, VLAN, name...).
-- Every write is therefore a read-modify-write of the whole array, starting
-- from a fresh copy of the device record.

local Model = {}

local json -- set by Model.init

function Model.init(jsonModule)
  json = jsonModule
end

-- poe_caps bit flags
local CAP_8023AF = 1
local CAP_8023AT = 2
local CAP_PASV24 = 4
local CAP_PASSTHROUGHABLE = 8
local CAP_PASSTHROUGH = 16
local CAP_8023BT = 32

local function hasCap(caps, flag)
  return caps % (flag * 2) >= flag
end

local function g(t, k) return json.get(t, k) end

local function truthy(v)
  return v == true or v == 1 or v == "1" or v == "true"
end

-- The PoE mode used to turn a port back on when the driver has no
-- remembered mode for it.
function Model.defaultPoeOnMode(caps)
  caps = tonumber(caps)
  if not caps or caps == 0 then return "auto" end
  if hasCap(caps, CAP_8023AF) or hasCap(caps, CAP_8023AT) or hasCap(caps, CAP_8023BT) then return "auto" end
  if hasCap(caps, CAP_PASSTHROUGH) or hasCap(caps, CAP_PASSTHROUGHABLE) then return "passthrough" end
  if hasCap(caps, CAP_PASV24) then return "pasv24" end
  return "auto"
end

local VALID_ON_MODES = { auto = true, pasv24 = true, passthrough = true }
function Model.isValidOnMode(mode) return VALID_ON_MODES[mode] == true end

local function deviceName(d)
  local name = g(d, "name")
  if not name or name == "" then name = g(d, "model") or g(d, "mac") or "UniFi device" end
  return tostring(name)
end

-- Normalizes one classic device record. Returns nil for devices that have
-- neither PDU outlets nor PoE ports.
function Model.parseDevice(d)
  local mac = g(d, "mac")
  if not mac then return nil end
  mac = string.lower(mac)

  local dev = {
    mac = mac,
    id = g(d, "_id"),
    name = deviceName(d),
    model = tostring(g(d, "model") or ""),
    online = tonumber(g(d, "state")) == 1,
    outlets = {},
    ports = {},
  }

  local outletTable = g(d, "outlet_table")
  if type(outletTable) == "table" then
    for _, o in ipairs(outletTable) do
      local idx = tonumber(g(o, "index"))
      if idx then
        dev.outlets[#dev.outlets + 1] = {
          index = idx,
          name = tostring(g(o, "name") or ("Outlet " .. idx)),
          on = truthy(g(o, "relay_state")),
          watts = tonumber(g(o, "outlet_power")),
          volts = tonumber(g(o, "outlet_voltage")),
          amps = tonumber(g(o, "outlet_current")),
          cycleEnabled = g(o, "cycle_enabled"),
        }
      end
    end
    table.sort(dev.outlets, function(a, b) return a.index < b.index end)
  end

  local portTable = g(d, "port_table")
  if type(portTable) == "table" then
    for _, p in ipairs(portTable) do
      local idx = tonumber(g(p, "port_idx"))
      if idx and truthy(g(p, "port_poe")) then
        local mode = tostring(g(p, "poe_mode") or "off")
        dev.ports[#dev.ports + 1] = {
          index = idx,
          name = tostring(g(p, "name") or ("Port " .. idx)),
          poeMode = mode,
          on = mode ~= "off",
          delivering = truthy(g(p, "poe_enable")) and (tonumber(g(p, "poe_power")) or 0) > 0,
          watts = tonumber(g(p, "poe_power")),
          caps = tonumber(g(p, "poe_caps")),
          up = truthy(g(p, "up")),
          speed = tonumber(g(p, "speed")),
          uplink = truthy(g(p, "is_uplink")),
        }
      end
    end
    table.sort(dev.ports, function(a, b) return a.index < b.index end)
  end

  if #dev.outlets == 0 and #dev.ports == 0 then return nil end
  return dev
end

function Model.findItem(dev, kind, index)
  if not dev then return nil end
  local list = (kind == "outlet") and dev.outlets or dev.ports
  for _, item in ipairs(list) do
    if item.index == index then return item end
  end
  return nil
end

-------------------------------------------------------------------------------
-- Override builders (operate on the raw, freshly fetched device record)
-------------------------------------------------------------------------------

local function copyArray(arr)
  local out = json.array({})
  if type(arr) ~= "table" then return out end
  for i, v in ipairs(arr) do out[i] = v end
  return out
end

-- Returns the full outlet_overrides array with outlet `index` set to `on`,
-- or nil, err.
function Model.buildOutletOverrides(raw, index, on)
  local overrides = copyArray(g(raw, "outlet_overrides"))

  if #overrides == 0 then
    -- Never-touched device: seed from the live outlet table so the other
    -- outlets keep their current state.
    for _, o in ipairs(g(raw, "outlet_table") or {}) do
      local idx = tonumber(g(o, "index"))
      if idx then
        local entry = json.object({ index = idx, relay_state = truthy(g(o, "relay_state")) })
        if g(o, "name") ~= nil then entry.name = g(o, "name") end
        if g(o, "cycle_enabled") ~= nil then entry.cycle_enabled = g(o, "cycle_enabled") end
        overrides[#overrides + 1] = entry
      end
    end
    if #overrides == 0 then
      return nil, "device reports no outlets"
    end
  end

  local found = false
  for _, entry in ipairs(overrides) do
    if tonumber(g(entry, "index")) == index then
      entry.relay_state = on and true or false
      found = true
    end
  end
  if not found then
    local exists = false
    for _, o in ipairs(g(raw, "outlet_table") or {}) do
      if tonumber(g(o, "index")) == index then exists = true end
    end
    if not exists then return nil, "outlet " .. index .. " not found on device" end
    overrides[#overrides + 1] = json.object({ index = index, relay_state = on and true or false })
  end
  return overrides
end

function Model.findRawPort(raw, index)
  for _, p in ipairs(g(raw, "port_table") or {}) do
    if tonumber(g(p, "port_idx")) == index then return p end
  end
  return nil
end

-- Returns the full port_overrides array with port `index` set to poe `mode`,
-- or nil, err. Existing override entries are kept field-for-field.
function Model.buildPortOverrides(raw, index, mode)
  local port = Model.findRawPort(raw, index)
  if not port then return nil, "port " .. index .. " not found on device" end
  if not truthy(g(port, "port_poe")) then return nil, "port " .. index .. " has no PoE" end

  local overrides = copyArray(g(raw, "port_overrides"))
  local found = false
  for _, entry in ipairs(overrides) do
    if tonumber(g(entry, "port_idx")) == index then
      entry.poe_mode = mode
      found = true
    end
  end
  if not found then
    local entry = json.object({ port_idx = index, poe_mode = mode })
    if g(port, "name") ~= nil then entry.name = g(port, "name") end
    if g(port, "portconf_id") ~= nil then entry.portconf_id = g(port, "portconf_id") end
    overrides[#overrides + 1] = entry
  end
  return overrides
end

return Model
