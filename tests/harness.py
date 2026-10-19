"""Off-controller harness: runs the three drivers in Lua 5.1 (lupa) against a
stubbed Control4 API, a virtual clock and a fake UniFi console.

Each driver instance gets its own Lua state, as on a controller.
C4:SendToDevice is routed between them by a Python broker, and C4:url()
requests are answered by FakeUniFi.
"""
import copy
import json
import os
import re
import xml.etree.ElementTree as ET

from lupa import lua51

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

STUB = r"""
local py = ...
CLOCK_MS = 0
local timers = {}
local timerSeq = 0

os.time = function(t)
  if t then return 0 end
  return math.floor(CLOCK_MS / 1000) + 1800000000
end

local Timer = {}
Timer.__index = Timer
function Timer:Cancel() self.cancelled = true return nil end

function C4TEST_next_due()
  local best
  for _, t in ipairs(timers) do
    if not t.cancelled and (best == nil or t.due < best) then best = t.due end
  end
  return best
end

function C4TEST_fire_due(target)
  local fired = false
  while true do
    local best
    for _, t in ipairs(timers) do
      if not t.cancelled and t.due <= target and (best == nil or t.due < best.due or (t.due == best.due and t.seq < best.seq)) then
        best = t
      end
    end
    if not best then break end
    if best.rep then best.due = best.due + best.ms else best.cancelled = true end
    local ok, err = pcall(best.fn, best)
    if not ok then py.error("timer error: " .. tostring(err)) end
    fired = true
  end
  local live = {}
  for _, t in ipairs(timers) do if not t.cancelled then table.insert(live, t) end end
  timers = live
  return fired
end

C4 = {}
function C4:SetTimer(ms, fn, rep)
  timerSeq = timerSeq + 1
  local t = setmetatable({ due = CLOCK_MS + ms, ms = ms, fn = fn, rep = rep and true or false, seq = timerSeq }, Timer)
  table.insert(timers, t)
  return t
end
function C4:KillTimer(t) return 0 end
function C4:UpdateProperty(name, value) Properties[name] = tostring(value); py.property(name, tostring(value)) end
function C4:UpdatePropertyList(name, list, current) py.property_list(name, list) end
function C4:SendToProxy(binding, cmd, params, kind) py.to_proxy(binding, cmd, params) end
function C4:SendToDevice(id, cmd, params) py.to_device(id, cmd, params) end
function C4:GetDeviceID() return py.device_id() end
function C4:GetBoundConsumerDevices(dev, binding) return py.bound_consumers(dev, binding) end
function C4:GetBoundProviderDevice(dev, binding) return py.bound_provider(dev, binding) end
function C4:FireEvent(name) py.event(name) end
function C4:AddVariable(name, value, vtype) py.variable(name, value) return true end
function C4:SetVariable(name, value) py.variable(name, value) end
function C4:url()
  local t = {}
  function t:SetOptions(o) self.opts = o return self end
  function t:OnDone(cb) self.cb = cb return self end
  local function go(self, method, url, body, headers)
    py.http(method, url, body or "", headers or {}, function(code, rbody, rheaders, err)
      local responses = {}
      if code > 0 then responses[1] = { code = code, body = rbody, headers = rheaders } end
      self.cb(self, responses, err and 7 or 0, err)
    end, self.opts)
  end
  function t:Get(u, h) go(self, "GET", u, nil, h) return self end
  function t:Post(u, d, h) go(self, "POST", u, d, h) return self end
  function t:Put(u, d, h) go(self, "PUT", u, d, h) return self end
  function t:Custom(u, m, d, h) go(self, m, u, d, h) return self end
  return t
end
PersistData = {}
"""


def lua_to_py(v):
    if hasattr(v, "items") and callable(v.items):
        d = {}
        for k, val in v.items():
            d[k] = lua_to_py(val)
        if d and all(isinstance(k, (int, float)) for k in d):
            return [d[k] for k in sorted(d)]
        return d
    return v


# ---------------------------------------------------------------------------
# Fake UniFi console
# ---------------------------------------------------------------------------

def make_devices():
    pdu = {
        "_id": "pdu1", "mac": "aa:bb:cc:00:00:01", "name": "Rack PDU", "model": "USPPDUP", "state": 1,
        "outlet_table": [
            {"index": i, "name": f"Outlet {i}", "relay_state": True, "cycle_enabled": False,
             "outlet_power": "12.50", "outlet_voltage": "120.1", "outlet_current": "0.10", "outlet_caps": 3}
            for i in range(1, 5)
        ],
        "outlet_overrides": [],
    }
    ports = []
    for i in range(1, 9):
        p = {"port_idx": i, "name": f"Port {i}", "port_poe": i <= 6 or i == 8, "up": True, "speed": 1000,
             "poe_mode": "auto", "poe_enable": True, "poe_power": "4.20", "poe_caps": 7}
        if i == 2:
            p.update({"name": "Camera, Porch"})
        if i == 6:
            p.update({"poe_caps": 4, "poe_mode": "pasv24"})
        if i == 7:
            p.update({"poe_mode": None, "poe_caps": 0})
        if i == 8:
            p.update({"is_uplink": True})
        ports.append(p)
    switch = {
        "_id": "sw1", "mac": "aa:bb:cc:00:00:02", "name": "Core Switch", "model": "USW-24-PoE", "state": 1,
        "port_table": ports,
        "port_overrides": [
            {"port_idx": 2, "name": "Camera, Porch", "portconf_id": "abc", "poe_mode": "auto",
             "stp_port_mode": True, "custom": {}, "excluded_networkconf_ids": [], "speed_caps": None},
            {"port_idx": 6, "poe_mode": "pasv24"},
        ],
    }
    ap = {"_id": "ap1", "mac": "aa:bb:cc:00:00:03", "name": "Living AP", "model": "U6LR", "state": 1,
          "port_table": [{"port_idx": 1, "port_poe": False, "up": True}]}
    return [pdu, switch, ap]


class FakeUniFi:
    API_KEY = "KEY123"

    def __init__(self):
        self.devices = make_devices()
        self.classic_accepts_key = True
        self.username = "c4"
        self.password = "pw"
        self.token = "abc123"
        self.csrf = "csrf1"
        self.log = []          # (method, path, body, headers)
        self.puts = []         # (device_id, payload)
        self.actions = []      # official port actions
        self.devmgr = []
        self.official_fails = False
        self.self_hosted = False

    def device_by_id(self, _id):
        return next(d for d in self.devices if d["_id"] == _id)

    def device_by_mac(self, mac):
        return next(d for d in self.devices if d["mac"] == mac)

    def _apply_put(self, dev, payload):
        if "outlet_overrides" in payload:
            dev["outlet_overrides"] = payload["outlet_overrides"]
            by_idx = {o["index"]: o for o in payload["outlet_overrides"]}
            for o in dev["outlet_table"]:
                # full-state semantics: an outlet missing from the array reverts to default (on)
                o["relay_state"] = by_idx.get(o["index"], {}).get("relay_state", True)
        if "port_overrides" in payload:
            dev["port_overrides"] = payload["port_overrides"]
            by_idx = {p["port_idx"]: p for p in payload["port_overrides"]}
            for p in dev["port_table"]:
                if p.get("port_poe"):
                    p["poe_mode"] = by_idx.get(p["port_idx"], {}).get("poe_mode", "auto")
                    p["poe_enable"] = p["poe_mode"] != "off"
                    p["poe_power"] = "4.20" if p["poe_enable"] else "0.00"

    def handle(self, method, url, body, headers):
        m = re.match(r"https://([^/]+)(/.*)$", url)
        path = m.group(1) and m.group(2)
        payload = json.loads(body) if body else None
        self.log.append((method, path, payload, dict(headers)))
        h = {k.lower(): v for k, v in headers.items()}

        if self.self_hosted:
            return self._handle_self_hosted(method, path, payload, h)

        if path == "/api/auth/login":
            if payload and payload.get("username") == self.username and payload.get("password") == self.password:
                return 200, json.dumps({"username": "c4"}), {
                    "Set-Cookie": f"TOKEN={self.token}; path=/; samesite=strict; secure; httponly",
                    "X-CSRF-Token": self.csrf}
            return 401, json.dumps({"code": "AUTHENTICATION_FAILED_INVALID_CREDENTIALS"}), {}

        if path.startswith("/proxy/network/integration/v1"):
            if h.get("x-api-key") != self.API_KEY:
                return 401, json.dumps({"message": "Unauthorized"}), {}
            sub = path[len("/proxy/network/integration/v1"):].split("?")[0]
            if sub == "/info":
                return 200, json.dumps({"applicationVersion": "10.1.84"}), {}
            if sub == "/sites":
                return 200, json.dumps({"offset": 0, "limit": 200, "count": 1, "totalCount": 1, "data": [
                    {"id": "site-uuid", "internalReference": "default", "name": "Default"}]}), {}
            if sub == "/sites/site-uuid/devices":
                data = [{"id": "uuid-" + d["_id"], "macAddress": d["mac"].upper(), "name": d["name"]}
                        for d in self.devices]
                return 200, json.dumps({"offset": 0, "limit": 200, "count": len(data),
                                        "totalCount": len(data), "data": data}), {}
            m2 = re.match(r"/sites/site-uuid/devices/([^/]+)/interfaces/ports/(\d+)/actions$", sub)
            if m2 and method == "POST":
                if self.official_fails:
                    return 404, json.dumps({"message": "Not Found"}), {}
                self.actions.append((m2.group(1), int(m2.group(2)), payload))
                return 200, "{}", {}
            return 404, json.dumps({"message": "Not Found"}), {}

        if path.startswith("/proxy/network/api/s/default/"):
            sub = path[len("/proxy/network/api/s/default"):]
            if h.get("x-api-key") == self.API_KEY:
                if not self.classic_accepts_key:
                    return 401, json.dumps({"meta": {"rc": "error", "msg": "api.err.LoginRequired"}, "data": []}), {}
            elif h.get("cookie") == f"TOKEN={self.token}":
                if method != "GET" and h.get("x-csrf-token") != self.csrf:
                    return 403, "", {}
            else:
                return 401, json.dumps({"meta": {"rc": "error", "msg": "api.err.LoginRequired"}, "data": []}), {}

            if sub == "/stat/device":
                devs = self.devices
                if method == "POST" and payload and payload.get("macs"):
                    devs = [d for d in self.devices if d["mac"] in payload["macs"]]
                return 200, json.dumps({"meta": {"rc": "ok"}, "data": devs}), {}
            m3 = re.match(r"/rest/device/(\w+)$", sub)
            if m3 and method == "PUT":
                dev = self.device_by_id(m3.group(1))
                self.puts.append((m3.group(1), copy.deepcopy(payload)))
                self._apply_put(dev, payload)
                return 200, json.dumps({"meta": {"rc": "ok"}, "data": [dev]}), {}
            if sub == "/cmd/devmgr" and method == "POST":
                self.devmgr.append(payload)
                return 200, json.dumps({"meta": {"rc": "ok"}, "data": []}), {}
        return 404, "not found", {}

    def _handle_self_hosted(self, method, path, payload, h):
        if path == "/api/login":
            if payload and payload.get("username") == self.username and payload.get("password") == self.password:
                return 200, json.dumps({"meta": {"rc": "ok"}, "data": []}), {
                    "Set-Cookie": ["unifises=sess9; Path=/; Secure; HttpOnly",
                                   "csrf_token=tok9; Path=/; Secure"]}
            return 400, json.dumps({"meta": {"rc": "error", "msg": "api.err.Invalid"}}), {}
        if not path.startswith("/api/s/default/"):
            return 404, "", {}
        if "unifises=sess9" not in (h.get("cookie") or ""):
            return 401, json.dumps({"meta": {"rc": "error", "msg": "api.err.LoginRequired"}}), {}
        if method != "GET" and h.get("x-csrf-token") != "tok9":
            return 403, "", {}
        sub = path[len("/api/s/default"):]
        if sub == "/stat/device":
            devs = self.devices
            if method == "POST" and payload and payload.get("macs"):
                devs = [d for d in self.devices if d["mac"] in payload["macs"]]
            return 200, json.dumps({"meta": {"rc": "ok"}, "data": devs}), {}
        m3 = re.match(r"/rest/device/(\w+)$", sub)
        if m3 and method == "PUT":
            dev = self.device_by_id(m3.group(1))
            self.puts.append((m3.group(1), copy.deepcopy(payload)))
            self._apply_put(dev, payload)
            return 200, json.dumps({"meta": {"rc": "ok"}, "data": [dev]}), {}
        if sub == "/cmd/devmgr" and method == "POST":
            self.devmgr.append(payload)
            return 200, json.dumps({"meta": {"rc": "ok"}, "data": []}), {}
        return 404, "", {}


# ---------------------------------------------------------------------------
# Driver instances
# ---------------------------------------------------------------------------

def xml_defaults(folder):
    root = ET.parse(os.path.join(ROOT, folder, "driver.xml")).getroot()
    props = {}
    for p in root.findall("config/properties/property"):
        props[p.findtext("name")] = p.findtext("default") or ""
    return props


class Driver:
    def __init__(self, world, device_id, folder):
        self.world = world
        self.device_id = device_id
        self.folder = folder
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        self.properties_log = {}
        self.property_lists = {}
        self.events = []
        self.variables = {}
        self.proxy_log = []
        self.errors = []
        py = {
            "error": lambda m: self.errors.append(m),
            "property": self._prop,
            "property_list": lambda n, v: self.property_lists.__setitem__(n, v.split(",")),
            "to_proxy": lambda b, c, p: self.proxy_log.append((b, c, lua_to_py(p))),
            "to_device": lambda i, c, p: world.messages.append((self.device_id, int(i), c, lua_to_py(p))),
            "device_id": lambda: self.device_id,
            "bound_consumers": lambda d, b: self.lua.table_from(
                {cid: "child" for cid in world.children_of(self.device_id)}),
            "bound_provider": lambda d, b: world.provider_of(self.device_id),
            "event": lambda n: self.events.append(n),
            "variable": lambda n, v: self.variables.__setitem__(n, v),
            "http": self._http,
        }
        self.lua.execute(STUB, self.lua.table_from(py))
        self.lua.globals().Properties = self.lua.table_from(xml_defaults(folder))
        pkg = self.lua.globals().package
        pkg.path = ";".join([
            os.path.join(ROOT, folder, "?.lua"),
            os.path.join(ROOT, "common", "?.lua"),
        ])
        src = open(os.path.join(ROOT, folder, "driver.lua"), encoding="utf-8").read()
        self.lua.execute(src)

    def _prop(self, name, value):
        self.properties_log[name] = value

    def _http(self, method, url, body, headers, cb, opts):
        self.world.http_queue.append((self, method, url, body, lua_to_py(headers), cb))

    @property
    def g(self):
        return self.lua.globals()

    def prop(self, name):
        return self.g.Properties[name]

    def set_property(self, name, value):
        self.g.Properties[name] = value
        self.g.OnPropertyChanged(name)

    def command(self, name, params=None):
        self.g.ExecuteCommand(name, self.lua.table_from(params or {}))

    def action(self, name):
        self.command("LUA_ACTION", {"ACTION": name})


class World:
    def __init__(self, properties=None, unifi=None):
        self.unifi = unifi or FakeUniFi()
        self.messages = []
        self.http_queue = []
        self.drivers = {}
        self.bindings = {}   # child id -> master id
        self.clock = 0
        self.master = self.add(100, "unifi_network")
        props = {
            "Controller Address": "192.168.1.1",
            "API Key": FakeUniFi.API_KEY,
        }
        props.update(properties or {})
        for k, v in props.items():
            self.master.g.Properties[k] = v

    def add(self, device_id, folder):
        d = Driver(self, device_id, folder)
        self.drivers[device_id] = d
        return d

    def add_child(self, device_id, folder):
        child = self.add(device_id, folder)
        self.bindings[device_id] = self.master.device_id
        return child

    def children_of(self, master_id):
        return [c for c, m in self.bindings.items() if m == master_id]

    def provider_of(self, child_id):
        return self.bindings.get(child_id, 0)

    def start(self):
        for d in list(self.drivers.values()):
            d.g.OnDriverInit()
        for d in list(self.drivers.values()):
            d.g.OnDriverLateInit()

    # deliver queued HTTP responses and driver messages until nothing is left
    def pump(self):
        for _ in range(10000):
            if self.http_queue:
                drv, method, url, body, headers, cb = self.http_queue.pop(0)
                code, rbody, rheaders = self.unifi.handle(method, url, body, headers)
                cb(code, rbody, drv.lua.table_from(rheaders), None)
                continue
            if self.messages:
                src, dst, cmd, params = self.messages.pop(0)
                target = self.drivers.get(dst)
                if target:
                    target.g.ExecuteCommand(cmd, target.lua.table_from(params or {}))
                continue
            return
        raise RuntimeError("pump did not settle")

    def advance(self, ms):
        target = self.clock + ms
        self.pump()
        while True:
            dues = [d.g.C4TEST_next_due() for d in self.drivers.values()]
            dues = [x for x in dues if x is not None and x <= target]
            if not dues:
                break
            t = min(dues)
            self.clock = max(self.clock, t)
            for d in self.drivers.values():
                d.g.CLOCK_MS = self.clock
            for d in list(self.drivers.values()):
                d.g.C4TEST_fire_due(self.clock)
            self.pump()
        self.clock = target
        for d in self.drivers.values():
            d.g.CLOCK_MS = self.clock
        self.pump()

    def errors(self):
        return {d.folder + str(i): d.errors for i, d in self.drivers.items() if d.errors}
