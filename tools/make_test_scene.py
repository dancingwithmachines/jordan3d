#!/usr/bin/env python3
"""Generate a synthetic colour plate + matching depth map.

Purely so the renderer can be verified without a real photograph: the layers
sit at known depths, so if the parallax is wired up correctly they separate
in a predictable order. Pure stdlib — writes PNG by hand.

    python3 tools/make_test_scene.py
"""
import math
import os
import struct
import zlib

W, H = 1600, 1000
OUT = os.path.join(os.path.dirname(__file__), '..', 'assets')


def write_png(path, w, h, rows, color_type):
    """color_type 2 = RGB, 0 = greyscale. `rows` is a list of row bytearrays."""
    raw = b''.join(b'\x00' + bytes(r) for r in rows)

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    ihdr = struct.pack('>IIBBBBB', w, h, 8, color_type, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', ihdr))
        f.write(chunk(b'IDAT', zlib.compress(raw, 6)))
        f.write(chunk(b'IEND', b''))


def checker(x, y, size, lo, hi):
    return hi if ((x // size) + (y // size)) % 2 else lo


def scene(x, y):
    """Return (rgb, depth) for one pixel. depth: 0 far .. 255 near."""
    u, v = x / W, y / H

    # foreground rail across the bottom — nearest layer
    if v > 0.88 + 0.01 * math.sin(u * 20):
        t = checker(x, y, 24, 0.75, 1.0)
        return (int(30 * t), int(28 * t), int(34 * t)), 245

    # subject: a large ellipse, right of centre
    dx = (u - 0.60) / 0.20
    dy = (v - 0.58) / 0.36
    if dx * dx + dy * dy < 1.0:
        shade = 1.0 - 0.45 * math.sqrt(max(0.0, dx * dx + dy * dy))
        t = checker(x, y, 40, 0.82, 1.0) * shade
        return (int(198 * t), int(38 * t), int(52 * t)), 210

    # mid-ground blocks
    band = 0.62 + 0.06 * math.sin(u * 9.0 + 1.2)
    if v > band:
        col = int(u * 14) % 3
        t = checker(x, y, 32, 0.86, 1.0)
        base = [(96, 104, 120), (78, 86, 104), (112, 118, 132)][col]
        return tuple(int(c * t) for c in base), 120

    # distant ridge
    ridge = 0.42 + 0.10 * math.sin(u * 4.0) + 0.04 * math.sin(u * 11.0 + 2.0)
    if v > ridge:
        t = checker(x, y, 48, 0.92, 1.0)
        return (int(58 * t), int(64 * t), int(86 * t)), 55

    # sky gradient
    g = v / max(ridge, 1e-6)
    return (int(18 + 40 * g), int(22 + 46 * g), int(38 + 62 * g)), 12


def main():
    os.makedirs(OUT, exist_ok=True)
    color_rows, depth_rows = [], []

    for y in range(H):
        crow = bytearray()
        drow = bytearray()
        for x in range(W):
            (r, g, b), d = scene(x, y)
            crow += bytes((r, g, b))
            drow.append(d)
        color_rows.append(crow)
        depth_rows.append(drow)

    write_png(os.path.join(OUT, 'test-color.png'), W, H, color_rows, 2)
    write_png(os.path.join(OUT, 'test-depth.png'), W, H, depth_rows, 0)
    print(f'wrote assets/test-color.png and assets/test-depth.png ({W}x{H})')


if __name__ == '__main__':
    main()
