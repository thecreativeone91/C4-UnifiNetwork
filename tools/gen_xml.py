#!/usr/bin/env python3
"""Generate driver.xml for all three drivers from one description, so the
shared parts (link class, child properties, events) stay identical.

    python3 tools/gen_xml.py
"""
import os
from xml.sax.saxutils import escape

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
VERSION_NUMBER = 101          # <version>; bump for every release
DATE = "10/18/2026 12:00 PM"
LINK_CLASS = "UNIFI_NETWORK_LINK"


def prop(name, ptype="STRING", default="", readonly=False, items=None, minimum=None, maximum=None,
         password=False, description=None):
    out = ["      <property>", f"        <name>{escape(name)}</name>", f"        <type>{ptype}</type>"]
    if readonly:
        out.append("        <readonly>true</readonly>")
    if password:
        out.append("        <password>true</password>")
    if minimum is not None:
        out.append(f"        <minimum>{minimum}</minimum>")
        out.append(f"        <maximum>{maximum}</maximum>")
    if ptype == "DYNAMIC_LIST":
        out.append("        <readonly>false</readonly>")
    else:
        out.append(f"        <default>{escape(str(default))}</default>")
    if items:
        out.append("        <items>")
        for item in items:
            out.append(f"          <item>{escape(item)}</item>")
        out.append("        </items>")
    if description:
        out.append(f"        <description>{escape(description)}</description>")
    out.append("      </property>")
    return "\n".join(out)


def ro(name):
    return prop(name, readonly=True)


def debug():
    return prop("Debug Mode", "LIST", "Off", items=["Off", "On"])


def connection(cid, name, cls, consumer, comment=None):
    lines = []
    if comment:
        lines.append(f"    <!-- {comment} -->")
    lines += [
        "    <connection>",
        f"      <id>{cid}</id>",
        "      <facing>6</facing>",
        "      <type>1</type>",
        f"      <connectionname>{escape(name)}</connectionname>",
        f"      <consumer>{'True' if consumer else 'False'}</consumer>",
        "      <linelevel>False</linelevel>",
        "      <classes>",
        f"        <class><classname>{cls}</classname></class>",
        "      </classes>",
        "    </connection>",
    ]
    return "\n".join(lines)


def events(names):
    return "\n".join(
        f"      <event><id>{i}</id><name>{escape(n)}</name><description>{escape(d)}</description></event>"
        for i, (n, d) in enumerate(names, 1))


def actions(names):
    return "\n".join(
        f"      <action><name>{escape(n)}</name><command>{escape(n)}</command></action>" for n in names)


def commands(items):
    return "\n".join(
        f"      <command>\n        <name>{escape(n)}</name>\n        <description>{escape(d)}</description>\n      </command>"
        for n, d in items)


def document(name, model, connections, props, evts, acts, cmds, proxy):
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<devicedata>
  <copyright>Open Source (MIT License)</copyright>
  <creator>Open Source</creator>
  <manufacturer>Ubiquiti</manufacturer>
  <name>{escape(name)}</name>
  <model>{escape(model)}</model>
  <created>{DATE}</created>
  <modified>{DATE}</modified>
  <version>{VERSION_NUMBER}</version>
  <control>lua_gen</control>
  <controlmethod>ip</controlmethod>
  <driver>DriverWorks</driver>
  <minimum_os_version>3.0.0</minimum_os_version>
  <small image_source="c4z">icons/device_sm.png</small>
  <large image_source="c4z">icons/device_lg.png</large>

  <connections>
{connections}
  </connections>

  <config>
    <documentation file="www/documentation.html"/>
    <script file="driver.lua"/>
    <actions>
{actions(acts)}
    </actions>
    <events>
{events(evts)}
    </events>
    <commands>
{commands(cmds)}
    </commands>
    <properties>
{chr(10).join(props)}
    </properties>
  </config>

  <!--
    Combo self-proxy: the driver is its own proxy, named after the .c4z file.
    Without a proxy Composer does not list the driver in its search.
  -->
  <combo>true</combo>
  <proxies>
    <proxy name="{escape(name)}">{proxy}</proxy>
  </proxies>
</devicedata>
"""


def master():
    conns = connection(1, "UniFi Network", LINK_CLASS, False,
                       "Bind every UniFi PDU Outlet and UniFi PoE Port driver to this connection.")
    props = [
        prop("Driver Version", readonly=True),
        ro("Status"),
        ro("Network Application"),
        ro("Official API"),
        ro("Site ID"),
        ro("PDU Devices Found"),
        ro("PoE Switches Found"),
        ro("Linked Drivers"),
        prop("Controller Type", "LIST", "UniFi OS Console",
             items=["UniFi OS Console", "Self-Hosted Network Application"]),
        prop("Controller Address", "STRING", ""),
        prop("Controller Port", "RANGED_INTEGER", 443, minimum=1, maximum=65535),
        prop("API Key", "STRING", "", password=True),
        prop("Username", "STRING", ""),
        prop("Password", "STRING", "", password=True),
        prop("Site", "STRING", "default"),
        prop("Verify SSL Certificate", "LIST", "No", items=["No", "Yes"]),
        prop("Poll Interval (seconds)", "RANGED_INTEGER", 10, minimum=5, maximum=300),
        prop("Protect Uplink Ports", "LIST", "Yes", items=["Yes", "No"]),
        debug(),
    ]
    evts = [
        ("Connected", "The driver reached the UniFi Network console"),
        ("Connection Lost", "The UniFi Network console stopped answering or rejected the credentials"),
    ]
    acts = ["Test Connection", "Refresh Devices", "Log Device List"]
    cmds = [("Refresh Devices", "UniFi Network: re-read all devices")]
    return document("UniFi Network", "UniFi Network (Open Source)", conns, props, evts, acts, cmds,
                    "unifi_network")


CHILD_EVENTS = [
    ("Power Turned On", "Power came on (by Control4, the UniFi app or anything else)"),
    ("Power Turned Off", "Power went off"),
    ("Power Cycle Started", "A power cycle was requested"),
    ("Power Cycle Complete", "A power cycle finished"),
    ("Command Failed", "A power command was refused or failed; see the Last Error property"),
    ("Device Online", "The UniFi device came back online"),
    ("Device Offline", "The UniFi device went offline"),
]


def child(kind):
    outlet = kind == "outlet"
    item = "Outlet" if outlet else "PoE Port"
    noun = "outlet" if outlet else "PoE port"
    conns = "\n".join([
        connection(1, "UniFi Network", LINK_CLASS, True, "Bind to the UniFi Network driver."),
        connection(2, "Power Relay", "RELAY", False,
                   "Optional: CLOSE = power on, OPEN = power off, TOGGLE, TRIGGER = power cycle."),
        connection(3, "Power State Contact", "CONTACT_SENSOR", False,
                   "Optional: closed while the " + noun + " is powered."),
    ])
    props = [
        prop("Driver Version", readonly=True),
        ro("Status"),
        prop("UniFi Device", "DYNAMIC_LIST"),
        prop(item, "DYNAMIC_LIST"),
        ro("Outlet Name" if outlet else "Port Name"),
        ro("Device Status"),
        ro("Power State"),
        ro("Power Draw"),
    ]
    if outlet:
        props += [ro("Voltage"), ro("Current")]
    else:
        props += [ro("PoE Mode"), ro("PoE Delivering Power"), ro("Link"), ro("Uplink Port"),
                  prop("Power Cycle Method", "LIST", "Switch Power Cycle",
                       items=["Switch Power Cycle", "Off Then On"])]
    props += [
        prop("Power Cycle Off Time (seconds)", "RANGED_INTEGER", 5 if outlet else 10, minimum=1, maximum=300),
        ro("Last Error"),
        debug(),
    ]
    acts = ["Power On", "Power Off", "Toggle Power", "Power Cycle", "Refresh"]
    label = "UniFi Outlet" if outlet else "UniFi PoE"
    cmds = [
        ("Power On", f"{label}: power on"),
        ("Power Off", f"{label}: power off"),
        ("Toggle Power", f"{label}: toggle power"),
        ("Power Cycle", f"{label}: power cycle"),
    ]
    name = "UniFi PDU Outlet" if outlet else "UniFi PoE Port"
    return document(name, name + " (Open Source)", conns, props, CHILD_EVENTS, acts, cmds,
                    "unifi_pdu_outlet" if outlet else "unifi_poe_port")


CHILD_DOCS = {
    "unifi_pdu_outlet": {
        "NAME": "UniFi PDU Outlet",
        "INTRO": "Controls one outlet of a UniFi SmartPower PDU, power strip or plug (USP-PDU-Pro, USP-PDU-HD, USP-Strip, USP-Plug): on, off, toggle and power cycle, with live power draw.",
        "ITEM": "Outlet",
        "PROPS": "",
        "CYCLE_WHEN": "a power cycle (default 5)",
        "RO": "Outlet Name, Voltage, Current",
        "EXTRA": "",
    },
    "unifi_poe_port": {
        "NAME": "UniFi PoE Port",
        "INTRO": "Controls PoE power on one port of a UniFi switch or gateway: on, off, toggle and power cycle, with live PoE draw and link state. Use it to reboot a camera, access point or other PoE device.",
        "ITEM": "PoE Port",
        "PROPS": "<tr><td>Power Cycle Method</td><td><b>Switch Power Cycle</b> asks the switch to cycle the port (official API POWER_CYCLE). <b>Off Then On</b> turns PoE off, waits, and turns it back on through the port settings.</td></tr>",
        "CYCLE_WHEN": "an <i>Off Then On</i> power cycle (default 10)",
        "RO": "Port Name, PoE Mode, PoE Delivering Power, Link, Uplink Port",
        "EXTRA": "<h2>Notes</h2><ul><li>Only PoE-capable ports are listed. A switch's uplink port is marked <i>(uplink)</i>; with <b>Protect Uplink Ports</b> on (UniFi Network driver) it cannot be turned off or cycled.</li><li>Power On restores the port's previous PoE mode (802.3 auto, passive 24V or passthrough).</li><li>A switch power cycle only works while the port is delivering PoE.</li></ul>"
                 "<p class=\"note\">Never turn off a port that powers the UniFi console, the Control4 controller or a switch between them; you would lose the connection needed to turn it back on.</p>",
    },
}


def write_child_docs():
    template = open(os.path.join(ROOT, "tools", "child_doc.html.in"), encoding="utf-8").read()
    for folder, values in CHILD_DOCS.items():
        text = template
        for k, v in values.items():
            text = text.replace("@" + k + "@", v)
        os.makedirs(os.path.join(ROOT, folder, "www"), exist_ok=True)
        with open(os.path.join(ROOT, folder, "www", "documentation.html"), "w", encoding="utf-8") as f:
            f.write(text)
        print(f"wrote {folder}/www/documentation.html")


def main():
    write_child_docs()
    for folder, text in (("unifi_network", master()),
                         ("unifi_pdu_outlet", child("outlet")),
                         ("unifi_poe_port", child("poe"))):
        with open(os.path.join(ROOT, folder, "driver.xml"), "w", encoding="utf-8") as f:
            f.write(text)
        print(f"wrote {folder}/driver.xml")


if __name__ == "__main__":
    main()
