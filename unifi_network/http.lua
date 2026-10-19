-- Async HTTPS transport on the Control4 url API (C4:url(), OS 3.0+).
--
-- UniFi consoles ship with a self-signed certificate, so certificate checks
-- are off unless the "Verify SSL Certificate" property says otherwise.

local Http = {}
Http.__index = Http

function Http.new(options)
  local self = setmetatable({}, Http)
  options = options or {}
  self.logDebug = options.logDebug or function(_) end
  self.timeoutSeconds = options.timeoutSeconds or 15
  self.verifySsl = false
  return self
end

function Http:setVerifySsl(verify)
  self.verifySsl = verify and true or false
end

-- Case-insensitive header lookup. Header values may arrive as a string or,
-- for repeated headers such as Set-Cookie, as a table of strings.
function Http.header(headers, name)
  if type(headers) ~= "table" then return nil end
  local wanted = string.lower(name)
  for k, v in pairs(headers) do
    if string.lower(tostring(k)) == wanted then
      if type(v) == "table" then return table.concat(v, "\n") end
      return tostring(v)
    end
  end
  return nil
end

-- callback(code, body, headers, err)
--   code    HTTP status (0 when no response arrived)
--   err     transport error text, or nil
function Http:request(method, url, body, headers, callback)
  callback = callback or function() end
  local done = false
  local function finish(code, data, hdrs, err)
    if done then return end
    done = true
    callback(code, data, hdrs, err)
  end

  self.logDebug(method .. " " .. url)

  local ok, err = pcall(function()
    local t = C4:url()
    t:SetOptions({
      fail_on_error = false,
      timeout = self.timeoutSeconds,
      connect_timeout = 5,
      ssl_verify_host = self.verifySsl,
      ssl_verify_peer = self.verifySsl,
    })
    t:OnDone(function(_, responses, errCode, errMsg)
      local last = type(responses) == "table" and responses[#responses] or nil
      local code = last and tonumber(last.code) or 0
      if (tonumber(errCode) or 0) ~= 0 and code == 0 then
        finish(0, nil, nil, tostring(errMsg or ("error " .. tostring(errCode))))
        return
      end
      finish(code, last and last.body or "", last and last.headers or {}, nil)
    end)

    headers = headers or {}
    if method == "GET" then
      t:Get(url, headers)
    elseif method == "POST" then
      t:Post(url, body or "", headers)
    elseif method == "PUT" then
      t:Put(url, body or "", headers)
    else
      t:Custom(url, method, body or "", headers)
    end
  end)

  if not ok then
    finish(0, nil, nil, "request failed: " .. tostring(err))
  end
end

return Http
