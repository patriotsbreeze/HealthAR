#!/usr/bin/env python3
"""Draws the demo app icon: hazard stripes and a large SIM, so it can't be mistaken for a product.

Plain Python stdlib. Writes App/Assets.xcassets/AppIcon.appiconset/icon-1024.png. iOS requires an
opaque icon, so the PNG has no alpha channel.
"""
import pathlib
import struct
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "App" / "Assets.xcassets" / "AppIcon.appiconset" / "icon-1024.png"
SIZE = 1024

YELLOW = (255, 204, 0)
BLACK = (16, 16, 16)
RED = (196, 24, 32)
WHITE = (255, 255, 255)

# 5 by 7 glyphs, one string per row.
GLYPHS = {
    "S": ["11111", "10000", "10000", "11111", "00001", "00001", "11111"],
    "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
}


def canvas():
    rows = []
    for y in range(SIZE):
        row = bytearray()
        for x in range(SIZE):
            in_band = 232 <= y < SIZE - 232
            if in_band:
                row += bytes(RED)
            else:
                row += bytes(YELLOW if (x + y) // 88 % 2 == 0 else BLACK)
        rows.append(row)
    return rows


def draw_text(rows, text, cell):
    gap = cell
    width = len(text) * 5 * cell + (len(text) - 1) * gap
    left = (SIZE - width) // 2
    top = (SIZE - 7 * cell) // 2
    for index, letter in enumerate(text):
        origin = left + index * (5 * cell + gap)
        for row_index, line in enumerate(GLYPHS[letter]):
            for column_index, bit in enumerate(line):
                if bit != "1":
                    continue
                for y in range(top + row_index * cell, top + (row_index + 1) * cell):
                    start = origin + column_index * cell
                    rows[y][start * 3:(start + cell) * 3] = bytes(WHITE) * cell


def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def png(rows):
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main():
    rows = canvas()
    draw_text(rows, "SIM", 44)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(png(rows))
    print(f"Wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
