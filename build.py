#!/usr/bin/env python3
"""Build the three drivers into dist/.

    python3 build.py            # regenerate XML/docs/icons, test, package
    python3 build.py --no-test  # skip the Lua test suite

Shared Lua modules in common/ are copied into the root of every package.
Package filenames are NOT versioned: Composer ties a driver's assets to the
.c4z filename. The version lives in each driver.xml <version>.
"""
import os
import subprocess
import sys
import zipfile

from lxml import etree

ROOT = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(ROOT, "dist")
COMMON = os.path.join(ROOT, "common")

DRIVERS = [
    ("unifi_network", "unifi_network.c4z", ["json.lua", "c4_utils.lua"]),
    ("unifi_pdu_outlet", "unifi_pdu_outlet.c4z", ["json.lua", "c4_utils.lua", "child_core.lua"]),
    ("unifi_poe_port", "unifi_poe_port.c4z", ["json.lua", "c4_utils.lua", "child_core.lua"]),
]

SKIP = {".DS_Store", "__pycache__"}


def check_driver(folder, shared, package_name):
    problems = []
    tree = etree.parse(os.path.join(folder, "driver.xml"))  # raises on malformed XML
    # Composer only lists drivers that have a proxy; ours are combo self-proxies
    # named after the package file.
    proxies = [p.text for p in tree.findall("proxies/proxy")]
    if package_name[:-4] not in proxies or tree.findtext("combo") != "true":
        problems.append(f"needs <combo>true</combo> and a self-proxy named {package_name[:-4]}")
    for tag in ("small", "large"):
        el = tree.find(tag)
        if el is not None and not os.path.exists(os.path.join(folder, "www", el.text)):
            problems.append(f"missing {tag} icon www/{el.text}")
    script = tree.find("config/script")
    if script is None or not os.path.exists(os.path.join(folder, script.get("file"))):
        problems.append("missing driver script")
    doc = tree.find("config/documentation")
    if doc is not None and not os.path.exists(os.path.join(folder, doc.get("file"))):
        problems.append("missing documentation file")
    ids = [c.findtext("id") for c in tree.findall("connections/connection")]
    if len(ids) != len(set(ids)):
        problems.append("duplicate connection ids")
    for f in shared:
        if os.path.exists(os.path.join(folder, f)):
            problems.append(f"{f} exists in both {os.path.basename(folder)}/ and common/")
    return problems


def package(folder, name, shared):
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, name)
    if os.path.exists(out):
        os.remove(out)
    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for base, dirs, files in os.walk(folder):
            dirs[:] = sorted(d for d in dirs if d not in SKIP)
            for f in sorted(files):
                if f in SKIP:
                    continue
                full = os.path.join(base, f)
                z.write(full, os.path.relpath(full, folder).replace(os.sep, "/"))
                count += 1
        for f in shared:
            z.write(os.path.join(COMMON, f), f)
            count += 1
    return out, count


def main():
    subprocess.check_call([sys.executable, os.path.join(ROOT, "tools", "gen_xml.py")])
    subprocess.check_call([sys.executable, os.path.join(ROOT, "tools", "make_icons.py")])
    if "--no-test" not in sys.argv:
        subprocess.check_call([sys.executable, os.path.join(ROOT, "tests", "test_drivers.py")],
                              stdout=subprocess.DEVNULL)
        print("tests passed")

    failed = False
    for sub, name, shared in DRIVERS:
        folder = os.path.join(ROOT, sub)
        problems = check_driver(folder, shared, name)
        if problems:
            failed = True
            for p in problems:
                print(f"[{sub}] {p}")
            continue
        out, count = package(folder, name, shared)
        print(f"built {os.path.relpath(out, ROOT)} ({count} files, {os.path.getsize(out) // 1024} KB)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
