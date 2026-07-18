#!/usr/bin/env python3
"""Hand-write a tiny valid PNG using only zlib+struct (no PIL).

Produces a 2x2 truecolor (RGB) PNG: IHDR + IDAT(zlib) + IEND.
"""
import zlib
import struct
import sys


def chunk(ctype: bytes, data: bytes) -> bytes:
    assert len(ctype) == 4
    crc = zlib.crc32(ctype + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + ctype + data + struct.pack(">I", crc)


def make_png(width=2, height=2) -> bytes:
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    pixels = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
    raw = bytearray()
    idx = 0
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        for x in range(width):
            r, g, b = pixels[idx]
            raw += bytes((r, g, b))
            idx += 1
    idat = zlib.compress(bytes(raw), 9)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "fixture.png"
    with open(out, "wb") as f:
        f.write(make_png())
    print(f"wrote {out} ({len(make_png())} bytes)")
