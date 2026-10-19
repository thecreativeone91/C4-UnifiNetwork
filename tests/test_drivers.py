"""End-to-end tests for the three drivers in a stubbed Control4 runtime.

    python3 tests/test_drivers.py        (or: python3 -m pytest -q tests/)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from harness import FakeUniFi, World, ROOT  # noqa: E402
from lupa import lua51  # noqa: E402

PDU = "aa:bb:cc:00:00:01"
SW = "aa:bb:cc:00:00:02"


def world(props=None, unifi=None, outlets=(), ports=()):
    w = World(props, unifi)
    kids = []
    for i, _ in enumerate(outlets):
        kids.append(w.add_child(200 + i, "unifi_pdu_outlet"))
    for i, _ in enumerate(ports):
        kids.append(w.add_child(300 + i, "unifi_poe_port"))
    w.start()
    w.advance(2000)
    for kid, (mac, idx) in zip(kids, list(outlets) + list(ports)):
        select(w, kid, mac, idx)
    return (w, *kids)


def select(w, kid, mac, idx):
    devices = kid.property_lists["UniFi Device"]
    label = next(v for v in devices if v.endswith("[" + mac + "]"))
    kid.set_property("UniFi Device", label)
    w.advance(100)
    item_prop = "Outlet" if kid.folder == "unifi_pdu_outlet" else "PoE Port"
    items = kid.property_lists[item_prop]
    kid.set_property(item_prop, next(v for v in items if v.startswith(f"{idx} - ")))
    w.advance(100)


def puts_for(w, dev_id):
    return [p for d, p in w.unifi.puts if d == dev_id]


# ------------------------------------------------------------------ JSON

def test_json_round_trip_keeps_empty_objects_and_nulls():
    lua = lua51.LuaRuntime()
    lua.globals().package.path = os.path.join(ROOT, "common", "?.lua")
    out = lua.eval(r'''(function()
      local json = require("json")
      local s = [[{"a":{},"b":[],"c":null,"d":[1,2.5,"x\u00e9\ud83d\ude00"],"e":true,"f":-3e2}]]
      return json.encode(json.decode(s))
    end)()''')
    assert out == '{"a":{},"b":[],"c":null,"d":[1,2.5,"xé\U0001F600"],"e":true,"f":-300}'


# ------------------------------------------------------------------ master

def test_master_connects_and_reads_official_api():
    w, = world()
    m = w.master
    assert m.prop("Status") == "Connected", m.prop("Status")
    assert m.prop("PDU Devices Found") == "1"
    assert m.prop("PoE Switches Found") == "1"           # AP has no PoE ports
    assert m.prop("Official API") == "Connected"
    assert m.prop("Network Application") == "UniFi Network 10.1.84"
    assert m.prop("Site ID") == "site-uuid"
    assert "Connected" in m.events
    assert not w.errors()


def test_not_configured():
    w = World({"API Key": "", "Controller Address": ""})
    w.start()
    w.advance(2000)
    assert w.master.prop("Status").startswith("Not configured")


def test_classic_rejects_key_without_account_reports_clearly():
    u = FakeUniFi()
    u.classic_accepts_key = False
    w, = world(unifi=u)
    assert "Username" in w.master.prop("Status")
    assert "Connection Lost" in w.master.events


def test_local_account_login_cookie_csrf_and_relogin():
    u = FakeUniFi()
    u.classic_accepts_key = False
    w, kid = world({"Username": "c4", "Password": "pw"}, u, outlets=[(PDU, 2)])
    assert w.master.prop("Status") == "Connected"
    logins = [e for e in u.log if e[1] == "/api/auth/login"]
    assert len(logins) == 1
    # classic requests use the session, not the key
    classic = [e for e in u.log if e[1].startswith("/proxy/network/api/")]
    assert all(e[3].get("Cookie") == "TOKEN=abc123" for e in classic)
    assert all("X-API-KEY" not in e[3] for e in classic)

    # session expires: next write logs in once and succeeds
    u.token = "newtoken"
    kid.command("Power Off")
    w.advance(500)
    assert len([e for e in u.log if e[1] == "/api/auth/login"]) == 2
    assert puts_for(w, "pdu1"), "write did not happen after re-login"
    put = [e for e in u.log if e[0] == "PUT"][-1]
    assert put[3]["X-CSRF-Token"] == "csrf1"


def test_self_hosted_controller_uses_account_and_classic_only():
    u = FakeUniFi()
    u.self_hosted = True
    w, kid = world({"Controller Type": "Self-Hosted Network Application", "Controller Port": "8443",
                    "Username": "c4", "Password": "pw"}, u, ports=[(SW, 3)])
    assert w.master.prop("Status") == "Connected", w.master.prop("Status")
    assert w.master.prop("Official API").startswith("Not available")
    assert all(e[1].startswith("/api/") for e in u.log)
    assert all("X-API-KEY" not in e[3] for e in u.log)
    kid.command("Power Cycle")      # no official API -> classic devmgr
    w.advance(500)
    assert u.devmgr == [{"cmd": "power-cycle", "mac": SW, "port_idx": 3}]
    kid.command("Power Off")
    w.advance(500)
    assert puts_for(w, "sw1")


# ------------------------------------------------------------------ outlets

def test_outlet_lists_and_state():
    w, kid = world(outlets=[(PDU, 2)])
    assert kid.property_lists["UniFi Device"] == ["(none)", "Rack PDU (USPPDUP) [aa:bb:cc:00:00:01]"]
    assert kid.property_lists["Outlet"][:3] == ["(none)", "1 - Outlet 1", "2 - Outlet 2"]
    assert kid.prop("Power State") == "On"
    assert kid.prop("Power Draw") == "12.5 W"
    assert kid.prop("Voltage") == "120.1 V"
    assert kid.prop("Status") == "OK"
    assert kid.variables["POWER_STATE"] == "1"
    assert (2, "CLOSED", {}) in kid.proxy_log


def test_outlet_off_writes_full_array_seeded_from_table():
    w, kid = world(outlets=[(PDU, 2)])
    kid.command("Power Off")
    w.advance(500)
    (payload,) = puts_for(w, "pdu1")
    ov = payload["outlet_overrides"]
    assert [o["index"] for o in ov] == [1, 2, 3, 4]
    assert [o["relay_state"] for o in ov] == [True, False, True, True]
    assert kid.prop("Power State") == "Off"
    assert "Power Turned Off" in kid.events
    assert kid.variables["POWER_STATE"] == "0"
    assert kid.proxy_log[-1][:2] == (3, "OPENED") or (2, "OPENED", {}) in kid.proxy_log
    w.advance(5000)
    assert kid.prop("Power State") == "Off"            # confirmed by poll
    assert [o["relay_state"] for o in w.unifi.devices[0]["outlet_table"]] == [True, False, True, True]


def test_outlet_toggle_and_relay_binding():
    w, kid = world(outlets=[(PDU, 3)])
    kid.g.ReceivedFromProxy(2, "OPEN", kid.lua.table_from({}))
    w.advance(500)
    assert kid.prop("Power State") == "Off"
    kid.command("Toggle Power")
    w.advance(500)
    assert kid.prop("Power State") == "On"
    kid.g.ReceivedFromProxy(2, "CLOSE", kid.lua.table_from({}))
    w.advance(500)
    assert kid.prop("Power State") == "On"


def test_outlet_power_cycle():
    w, kid = world(outlets=[(PDU, 1)])
    kid.command("Power Cycle")
    w.advance(500)
    assert kid.prop("Status") == "Power cycling"
    assert kid.prop("Power State") == "Off"
    w.advance(9000)
    payloads = puts_for(w, "pdu1")
    assert [p["outlet_overrides"][0]["relay_state"] for p in payloads] == [False, True]
    assert kid.prop("Power State") == "On"
    assert kid.prop("Status") == "OK"
    assert "Power Cycle Started" in kid.events and "Power Cycle Complete" in kid.events


def test_two_outlets_changed_at_once_are_serialized():
    w, a, b = world(outlets=[(PDU, 1), (PDU, 3)])
    a.command("Power Off")
    b.command("Power Off")
    w.advance(500)
    states = [o["relay_state"] for o in w.unifi.devices[0]["outlet_table"]]
    assert states == [False, True, False, True], states
    assert a.prop("Power State") == "Off" and b.prop("Power State") == "Off"


# ------------------------------------------------------------------ PoE

def test_poe_lists_hide_non_poe_and_flag_uplink():
    w, kid = world(ports=[(SW, 3)])
    assert kid.property_lists["UniFi Device"] == ["(none)", "Core Switch (USW-24-PoE) [aa:bb:cc:00:00:02]"]
    items = kid.property_lists["PoE Port"]
    assert "7 - Port 7" not in items                  # no PoE on port 7
    assert "8 - Port 8 (uplink)" in items
    assert "2 - Camera Porch" in items                # comma stripped for the list
    assert kid.prop("Power State") == "On"
    assert kid.prop("Link") == "Up (1000 Mbps)"
    assert kid.prop("PoE Mode") == "auto"


def test_poe_off_keeps_other_overrides_intact():
    w, kid = world(ports=[(SW, 3)])
    kid.command("Power Off")
    w.advance(500)
    (payload,) = puts_for(w, "sw1")
    ov = {o["port_idx"]: o for o in payload["port_overrides"]}
    assert set(ov) == {2, 3, 6}
    assert ov[2] == {"port_idx": 2, "name": "Camera, Porch", "portconf_id": "abc", "poe_mode": "auto",
                     "stp_port_mode": True, "custom": {}, "excluded_networkconf_ids": [], "speed_caps": None}
    assert ov[3] == {"port_idx": 3, "name": "Port 3", "poe_mode": "off"}
    assert ov[6]["poe_mode"] == "pasv24"
    assert kid.prop("Power State") == "Off"
    assert kid.prop("PoE Delivering Power") == "Yes"   # optimistic until the next poll
    w.advance(4000)
    assert kid.prop("PoE Delivering Power") == "No"

    kid.command("Power On")
    w.advance(500)
    assert puts_for(w, "sw1")[-1]["port_overrides"][-1]["poe_mode"] == "auto"
    assert kid.prop("Power State") == "On"


def test_poe_passive_port_restores_its_mode():
    w, kid = world(ports=[(SW, 6)])
    assert kid.prop("PoE Mode") == "pasv24"
    kid.command("Power Off")
    w.advance(4000)
    kid.command("Power On")
    w.advance(500)
    last = {o["port_idx"]: o for o in puts_for(w, "sw1")[-1]["port_overrides"]}
    assert last[6]["poe_mode"] == "pasv24"


def test_poe_switch_cycle_uses_official_api():
    w, kid = world(ports=[(SW, 4)])
    kid.command("Power Cycle")
    w.advance(500)
    assert w.unifi.actions == [("uuid-sw1", 4, {"action": "POWER_CYCLE"})]
    assert not w.unifi.devmgr and not w.unifi.puts
    assert kid.prop("Status") == "Power cycling"
    assert "Power Cycle Complete" in kid.events
    w.advance(11000)
    assert kid.prop("Status") == "OK"


def test_poe_switch_cycle_falls_back_to_classic():
    u = FakeUniFi()
    u.official_fails = True
    w, kid = world(unifi=u, ports=[(SW, 4)])
    kid.command("Power Cycle")
    w.advance(500)
    assert u.devmgr == [{"cmd": "power-cycle", "mac": SW, "port_idx": 4}]


def test_poe_off_then_on_cycle_method():
    w, kid = world(ports=[(SW, 5)])
    kid.set_property("Power Cycle Method", "Off Then On")
    kid.set_property("Power Cycle Off Time (seconds)", "3")
    kid.command("Power Cycle")
    w.advance(4000)
    modes = [{o["port_idx"]: o["poe_mode"] for o in p["port_overrides"]}[5] for p in puts_for(w, "sw1")]
    assert modes == ["off", "auto"]
    assert not w.unifi.actions


def test_uplink_port_is_protected():
    w, kid = world(ports=[(SW, 8)])
    kid.command("Power Off")
    w.advance(500)
    assert not w.unifi.puts
    assert "Command Failed" in kid.events
    assert "uplink" in kid.prop("Last Error")
    kid.command("Power Cycle")
    w.advance(500)
    assert not w.unifi.actions and not w.unifi.devmgr

    w.master.set_property("Protect Uplink Ports", "No")
    kid.command("Power Off")
    w.advance(500)
    assert puts_for(w, "sw1")


def test_external_change_fires_events():
    w, kid = world(ports=[(SW, 1)])
    w.unifi.devices[1]["port_table"][0]["poe_mode"] = "off"
    w.advance(11000)
    assert kid.prop("Power State") == "Off"
    assert "Power Turned Off" in kid.events
    w.unifi.devices[1]["state"] = 0
    w.advance(11000)
    assert kid.prop("Device Status") == "Offline"
    assert "Device Offline" in kid.events


def test_unselected_child_command_fails_cleanly():
    w = World()
    kid = w.add_child(200, "unifi_pdu_outlet")
    w.start()
    w.advance(2000)
    kid.command("Power On")
    w.advance(200)
    assert "Command Failed" in kid.events
    assert not w.unifi.puts


def test_unbound_child_reports_status():
    w = World()
    kid = w.add(250, "unifi_poe_port")
    w.start()
    w.advance(2000)
    assert kid.prop("Status").startswith("Not connected")


def test_selection_survives_restart():
    w, kid = world(outlets=[(PDU, 4)])
    persisted = dict(kid.g.PersistData.items())
    w2 = World()
    kid2 = w2.add_child(200, "unifi_pdu_outlet")
    for k, v in persisted.items():
        kid2.g.PersistData[k] = v
    w2.start()
    w2.advance(2000)
    assert kid2.prop("Outlet").startswith("4 - ")
    assert kid2.prop("Power State") == "On"


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print("ok   ", name)
        except Exception as e:  # noqa: BLE001
            failed += 1
            import traceback
            print("FAIL ", name)
            traceback.print_exc()
    print(f"{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
