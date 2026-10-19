#!/usr/bin/env python3
"""Draw original icons for the three drivers (Pillow only).

Artwork is built from simple shapes so it can be published freely; it is
deliberately not the Ubiquiti or UniFi logo.

    python3 tools/make_icons.py
"""
import os

from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SS = 8  # supersampling factor
SIZES = {"device_sm.png": 16, "device_lg.png": 32, "device_300.png": 300}

TOP = (46, 139, 230)
BOTTOM = (18, 64, 140)
GLYPH = (240, 245, 250, 255)
ACCENT = (255, 196, 46, 255)


def tile(size):
    n = size * SS
    grad = Image.new("RGBA", (n, n))
    px = grad.load()
    for y in range(n):
        t = y / max(1, n - 1)
        c = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,)
        for x in range(n):
            px[x, y] = c
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1], radius=int(n * 0.22), fill=255)
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out, ImageDraw.Draw(out), n


def network(size):
    img, d, n = tile(size)
    w = max(SS, int(n * 0.055))
    hub = (n * 0.5, n * 0.5)
    nodes = [(n * 0.24, n * 0.28), (n * 0.76, n * 0.28), (n * 0.24, n * 0.74), (n * 0.76, n * 0.74)]
    for x, y in nodes:
        d.line([hub, (x, y)], fill=GLYPH, width=w)
    r = n * 0.11
    for x, y in nodes:
        d.ellipse([x - r, y - r, x + r, y + r], fill=GLYPH)
    r = n * 0.15
    d.ellipse([hub[0] - r, hub[1] - r, hub[0] + r, hub[1] + r], fill=ACCENT)
    return img


def outlet(size):
    img, d, n = tile(size)
    m = n * 0.18
    d.rounded_rectangle([m, m, n - m, n - m], radius=int(n * 0.16), fill=GLYPH)
    slot_w, slot_h = n * 0.07, n * 0.2
    for cx in (n * 0.38, n * 0.62):
        d.rounded_rectangle([cx - slot_w / 2, n * 0.33, cx + slot_w / 2, n * 0.33 + slot_h],
                            radius=int(slot_w / 2), fill=BOTTOM + (255,))
    r = n * 0.06
    d.ellipse([n * 0.5 - r, n * 0.64 - r, n * 0.5 + r, n * 0.64 + r], fill=BOTTOM + (255,))
    return img


def poe_port(size):
    img, d, n = tile(size)
    # RJ45 jack outline
    x0, y0, x1, y1 = n * 0.2, n * 0.3, n * 0.8, n * 0.8
    d.rectangle([x0, y0, x1, y1], fill=GLYPH)
    d.rectangle([n * 0.38, n * 0.22, n * 0.62, y0 + 1], fill=GLYPH)
    for i in range(4):
        cx = n * (0.32 + i * 0.12)
        d.rectangle([cx - n * 0.025, n * 0.36, cx + n * 0.025, n * 0.48], fill=BOTTOM + (255,))
    # power bolt
    bolt = [(n * 0.54, n * 0.5), (n * 0.42, n * 0.66), (n * 0.5, n * 0.66),
            (n * 0.46, n * 0.78), (n * 0.6, n * 0.6), (n * 0.52, n * 0.6)]
    d.polygon(bolt, fill=ACCENT)
    return img


def save(draw, folder):
    icons = os.path.join(ROOT, folder, "www", "icons")
    os.makedirs(icons, exist_ok=True)
    for name, size in SIZES.items():
        draw(size).resize((size, size), Image.LANCZOS).save(os.path.join(icons, name))


def main():
    save(network, "unifi_network")
    save(outlet, "unifi_pdu_outlet")
    save(poe_port, "unifi_poe_port")
    print("icons written")


if __name__ == "__main__":
    main()
