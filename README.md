# UniFi Network for Control4 — PDU Outlets + PoE Ports

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Control4 OS](https://img.shields.io/badge/Control4%20OS-3.0%2B-orange.svg)
![UniFi Network](https://img.shields.io/badge/UniFi%20Network-9%2B-1f8ae6.svg)

Three open-source Control4 drivers for [UniFi Network](https://ui.com):

- **UniFi Network** (`unifi_network.c4z`) — the master driver. Connects to the UniFi console with the UniFi Network API, discovers PDUs and PoE switches, polls their state and carries out power commands.
- **UniFi PDU Outlet** (`unifi_pdu_outlet.c4z`) — one per outlet of a UniFi SmartPower PDU / strip / plug. On, off, toggle, power cycle, live watts/volts/amps.
- **UniFi PoE Port** (`unifi_poe_port.c4z`) — one per switch port. PoE on, off, toggle, power cycle (switch-side or off-wait-on), live PoE watts and link.

```
                         Connections → Control
  ┌──────────────────┐   "UniFi Network"   ┌──────────────────────┐
  │ UniFi PDU Outlet │ ──────────────────► │                      │   HTTPS   ┌────────────────┐
  ├──────────────────┤                     │    UniFi Network     │ ────────► │ UniFi console  │
  │ UniFi PoE Port   │ ──────────────────► │    (master)          │ ◄──────── │ (UDM/UCG/CK/…) │
  └──────────────────┘                     └──────────────────────┘           └────────────────┘
     ▲ optional RELAY / CONTACT_SENSOR bindings to Control4 relay / contact drivers
```

---

## Features

- Official **UniFi Network API** (API key) for application version, site and device lookup, and PoE **POWER_CYCLE**
- Classic controller API for port/outlet state and PoE/outlet **on/off** (not in the official API yet), using the API key or a local account (cookie + CSRF, automatic re-login)
- Read-modify-write of the complete `port_overrides` / `outlet_overrides` arrays from a fresh device record, so other ports keep their profile, VLAN, name and PoE settings; writes are queued one at a time
- Child drivers choose device and outlet/port from **dynamic lists** filled in by the master; selections survive reboots
- **Uplink protection**: a switch's uplink port can't be switched off or cycled unless you allow it
- Power On restores the port's previous PoE mode (802.3 auto, passive 24V, passthrough)
- Fast polling only for devices in use (POST `stat/device` with a MAC filter) plus a full scan every 5 minutes
- Programming: commands, events (including changes made in the UniFi app), variables for conditionals
- Optional **RELAY** binding (CLOSE/OPEN/TOGGLE/TRIGGER) and **CONTACT_SENSOR** binding per child
- Works with UniFi OS consoles, UniFi OS Server and the legacy self-hosted Network application (local account, classic API only)

---

## Requirements

- Control4 OS **3.0** or later
- UniFi Network **9.x or later** on a UniFi OS console or UniFi OS Server for the API key / official API; any version for the classic API with a local account
- A UniFi API key, and/or a local-only UniFi admin account (Network admin rights, no MFA)

---

## Installation

1. **API key**: UniFi Network → Settings → Control Plane → Integrations (API Keys on some versions) → create key.
2. Composer Pro → add `unifi_network.c4z`. Set **Controller Address** and **API Key**. Run **Test Connection**.
   - If **Status** says the console rejected the API key on the classic API, also fill in **Username** / **Password** of a local admin account.
   - Self-hosted Network application: set **Controller Type** to *Self-Hosted Network Application*, **Controller Port** to 8443, and use **Username** / **Password**.
3. Add a `unifi_pdu_outlet.c4z` or `unifi_poe_port.c4z` per outlet/port.
4. Connections → Control: bind each child's **UniFi Network** to the master's **UniFi Network**.
5. In each child pick **UniFi Device**, then **Outlet** / **PoE Port**.
6. Optional: bind the child's **Power Relay** to a Control4 relay driver for Navigator/keypad control, or **Power State Contact** to a contact driver.

> Keep the `.c4z` filenames unchanged; Composer ties driver assets to the package name.

---

## Configuration

### UniFi Network

| Property | Default | Notes |
|---|---|---|
| Controller Type | UniFi OS Console | Or Self-Hosted Network Application |
| Controller Address / Port | — / 443 | 8443 self-hosted, 11443 UniFi OS Server |
| API Key | — | UniFi OS only |
| Username / Password | — | Local account for the classic API (optional on UniFi OS) |
| Site | default | Internal name, display name or site id |
| Verify SSL Certificate | No | Consoles use self-signed certificates |
| Poll Interval (seconds) | 10 | Devices in use; full scan every 5 min |
| Protect Uplink Ports | Yes | Blocks PoE off/cycle on uplink ports |
| Debug Mode | Off | |

Read-only: Driver Version, Status, Network Application, Official API, Site ID, PDU Devices Found, PoE Switches Found, Linked Drivers.

### UniFi PDU Outlet / UniFi PoE Port

| Property | Default | Notes |
|---|---|---|
| UniFi Device | (none) | Filled in by the master |
| Outlet / PoE Port | (none) | Only PoE-capable ports are listed |
| Power Cycle Method (PoE) | Switch Power Cycle | Or Off Then On |
| Power Cycle Off Time (seconds) | 5 outlet / 10 PoE | Off time for off-then-on cycles |
| Debug Mode | Off | |

Read-only: Status, Outlet/Port Name, Device Status, Power State, Power Draw, Voltage/Current (outlet), PoE Mode, PoE Delivering Power, Link, Uplink Port (PoE), Last Error.

---

## Programming

**UniFi Network** — events `Connected`, `Connection Lost`; command `Refresh Devices`; actions Test Connection, Refresh Devices, Log Device List.

**Children** — commands `Power On`, `Power Off`, `Toggle Power`, `Power Cycle`; events `Power Turned On`, `Power Turned Off`, `Power Cycle Started`, `Power Cycle Complete`, `Command Failed`, `Device Online`, `Device Offline`; variables `POWER_STATE` (bool), `POWER_WATTS`, `DEVICE_ONLINE` (bool).

Relay binding: `CLOSE` → on, `OPEN` → off, `TOGGLE` → toggle, `TRIGGER` → power cycle; reports `CLOSED` while powered.

---

## API calls used

| Purpose | Request |
|---|---|
| App version | `GET /proxy/network/integration/v1/info` |
| Site id | `GET /proxy/network/integration/v1/sites` |
| Device ids | `GET /proxy/network/integration/v1/sites/{siteId}/devices` |
| PoE power cycle | `POST …/sites/{siteId}/devices/{deviceId}/interfaces/ports/{portIdx}/actions` `{"action":"POWER_CYCLE"}` |
| PoE power cycle (fallback) | `POST /proxy/network/api/s/{site}/cmd/devmgr` `{"cmd":"power-cycle","mac":…,"port_idx":…}` |
| State | `GET` / `POST /proxy/network/api/s/{site}/stat/device` (`{"macs":[…]}`) |
| PoE on/off | `PUT /proxy/network/api/s/{site}/rest/device/{_id}` `{"port_overrides":[…]}` |
| Outlet on/off | `PUT /proxy/network/api/s/{site}/rest/device/{_id}` `{"outlet_overrides":[…]}` |
| Login (local account) | `POST /api/auth/login` (UniFi OS) or `/api/login` (self-hosted) |

Self-hosted controllers use the same classic paths without `/proxy/network`.

---

## Building from source

```
pip install lupa lxml pillow
python3 build.py
```

`build.py` regenerates each `driver.xml` and the child documentation (`tools/gen_xml.py`), redraws the icons (`tools/make_icons.py`), runs the test suite and writes the three `.c4z` files to `dist/`. Shared Lua in `common/` is copied into each package.

`tests/` runs every driver in Lua 5.1 (lupa) against a stubbed Control4 runtime and a fake UniFi console: API key and local-account auth, self-hosted paths, re-login after session expiry, full-array override writes that keep other ports' settings, concurrent commands, power cycles, uplink protection, external changes and restart persistence.

---

## Project layout

```
unifi_network/       master driver: driver.lua, http.lua, unifi_client.lua, unifi_model.lua
unifi_pdu_outlet/    outlet child: driver.lua (+ common/child_core.lua)
unifi_poe_port/      PoE child:   driver.lua (+ common/child_core.lua)
common/              json.lua, c4_utils.lua, child_core.lua (copied into packages)
tools/               gen_xml.py, make_icons.py, child_doc.html.in
tests/               harness.py, test_drivers.py
```

---

## Status and known limitations

- Tested in the simulated runtime; validate on real hardware before relying on it for critical loads.
- PoE and outlet on/off use the classic controller API because the official API has no such action yet. If a future UniFi release adds one, it can replace the classic write.
- Some consoles accept the API key only on the official API; add a local account in that case.
- Local accounts with MFA can't log in; use a local-only admin.
- Turning off PoE to the console, the Control4 controller or a switch in between cuts your own control path.

---

## References

- [UniFi developer documentation](https://developer.ui.com/)
- [ha-unifi-insights](https://github.com/ruaan-deysel/ha-unifi-insights) — official-API PoE `POWER_CYCLE` and outlet override handling
- [homebridge-unifi-smartpower](https://github.com/derek-miller/homebridge-unifi-smartpower) — PoE mode / outlet relay overrides
- [node-unifi](https://github.com/jens-maus/node-unifi) — classic API login, `devmgr` power-cycle and `rest/device`

---

## License

MIT — see [LICENSE](LICENSE). Not affiliated with or endorsed by Ubiquiti Inc. or Snap One.
