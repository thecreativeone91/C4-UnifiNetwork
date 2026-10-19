-- Shared Control4 helpers for the UniFi drivers (MIT License).

local C4Utils = {}

function C4Utils.createLogger(prefix)
  prefix = prefix or ""
  local function info(message)
    print(prefix .. tostring(message))
  end
  local function debug(message)
    if Properties and Properties["Debug Mode"] == "On" then
      print(prefix .. tostring(message))
    end
  end
  return { info = info, debug = debug }
end

function C4Utils.updateProperty(name, value)
  value = tostring(value == nil and "" or value)
  if Properties and Properties[name] == value then return end
  pcall(function() C4:UpdateProperty(name, value) end)
end

function C4Utils.setTimer(ms, callback, repeating)
  return C4:SetTimer(ms, function(timer) callback(timer) end, repeating and true or false)
end

function C4Utils.cancelTimer(timer)
  if type(timer) == "userdata" or type(timer) == "table" then
    pcall(function() timer:Cancel() end)
  elseif type(timer) == "number" and timer ~= 0 then
    pcall(function() C4:KillTimer(timer) end)
  end
  return nil
end

function C4Utils.fireEvent(name)
  pcall(function() C4:FireEvent(name) end)
end

-- Variables are created once and then updated in place.
local createdVariables = {}

function C4Utils.ensureVariable(name, value, varType)
  if createdVariables[name] then return end
  createdVariables[name] = true
  pcall(function() C4:AddVariable(name, tostring(value), varType, true, false) end)
end

function C4Utils.setVariable(name, value)
  pcall(function() C4:SetVariable(name, tostring(value)) end)
end

function C4Utils.trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function C4Utils.normalizeMac(mac)
  mac = string.lower(C4Utils.trim(mac))
  if mac == "" then return nil end
  return mac
end

-- Text that is safe inside a Composer LIST property (commas split items).
function C4Utils.listSafe(s)
  s = tostring(s or "")
  s = s:gsub(",", " "):gsub("[%c]", " "):gsub("%s%s+", " ")
  return C4Utils.trim(s)
end

function C4Utils.formatWatts(w)
  local n = tonumber(w)
  if not n then return "" end
  return string.format("%.1f W", n)
end

-- Persisted values survive controller reboots and driver updates.
function C4Utils.persistGet(key, default)
  if type(PersistData) ~= "table" then return default end
  local v = PersistData[key]
  if v == nil then return default end
  return v
end

function C4Utils.persistSet(key, value)
  if type(PersistData) ~= "table" then PersistData = {} end
  PersistData[key] = value
end

-- ExecuteCommand dispatch shared by all three drivers. handlers is keyed by
-- command name; Composer actions arrive as LUA_ACTION with the name in ACTION.
function C4Utils.dispatch(handlers, strCommand, tParams, log)
  tParams = tParams or {}
  if strCommand == "LUA_ACTION" and tParams.ACTION then
    strCommand = tParams.ACTION
  end
  local fn = handlers[strCommand]
  if type(fn) ~= "function" then
    if log then log.debug("Unhandled command: " .. tostring(strCommand)) end
    return
  end
  local ok, err = pcall(fn, tParams)
  if not ok and log then
    log.info("Error in " .. tostring(strCommand) .. ": " .. tostring(err))
  end
end

return C4Utils
