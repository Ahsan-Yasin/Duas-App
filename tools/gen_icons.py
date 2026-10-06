"""Generate the launcher icons (mipmap-*/ic_launcher.png) with pure Python (zlib + struct).

Deep green (#0F6E5A) rounded square with a white crescent and a small star, 4x4 supersampled.
Run: python tools/gen_icons.py
"""
import math
import os
import struct
import zlib

RES = os.path.join(os.path.dirname(__file__), "..", "android", "app", "src", "main", "res")
SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
GREEN = (0x0F, 0x6E, 0x5A)
WHITE = (0xFF, 0xFF, 0xFF)
SS = 4  # supersamples per axis

# Geometry in unit coordinates (0..1).
INSET = 0.02
CORNER = 0.22
MOON_C, MOON_R = (0.45, 0.53), 0.29
CUT_C, CUT_R = (0.56, 0.45), 0.245
STAR_C, STAR_R = (0.70, 0.33), 0.085


def star_polygon(cx, cy, r_out, r_in, points=5):
    pts = []
    for k in range(points * 2):
        r = r_out if k % 2 == 0 else r_in
        a = -math.pi / 2 + k * math.pi / points
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


STAR = star_polygon(STAR_C[0], STAR_C[1], STAR_R, STAR_R * 0.42)


def in_polygon(x, y, poly):
    inside = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def in_rounded_square(x, y):
    lo, hi = INSET, 1 - INSET
    if x < lo or x > hi or y < lo or y > hi:
        return False
    cx = min(max(x, lo + CORNER), hi - CORNER)
    cy = min(max(y, lo + CORNER), hi - CORNER)
    return (x - cx) ** 2 + (y - cy) ** 2 <= CORNER ** 2


def is_white(x, y):
    in_moon = (x - MOON_C[0]) ** 2 + (y - MOON_C[1]) ** 2 <= MOON_R ** 2
    in_cut = (x - CUT_C[0]) ** 2 + (y - CUT_C[1]) ** 2 <= CUT_R ** 2
    return (in_moon and not in_cut) or in_polygon(x, y, STAR)


def render(size):
    rows = []
    for py in range(size):
        row = bytearray([0])  # filter: none
        for px in range(size):
            bg = fg = 0
            for sy in range(SS):
                for sx in range(SS):
                    x = (px + (sx + 0.5) / SS) / size
                    y = (py + (sy + 0.5) / SS) / size
                    if in_rounded_square(x, y):
                        bg += 1
                        if is_white(x, y):
                            fg += 1
            total = SS * SS
            alpha = bg / total
            if bg:
                t = fg / bg
                rgb = [round(GREEN[i] * (1 - t) + WHITE[i] * t) for i in range(3)]
            else:
                rgb = [0, 0, 0]
            row += bytes(rgb + [round(alpha * 255)])
        rows.append(bytes(row))
    return b"".join(rows)


def png(size, pixels):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(pixels, 9)) + chunk(b"IEND", b"")


def main():
    for density, size in SIZES.items():
        folder = os.path.join(RES, f"mipmap-{density}")
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, "ic_launcher.png")
        with open(path, "wb") as f:
            f.write(png(size, render(size)))
        print(f"wrote {os.path.abspath(path)}")


if __name__ == "__main__":
    main()
