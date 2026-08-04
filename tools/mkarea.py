#!/usr/bin/env python3
"""Cut an area out of the world atlas and write it as map.bin.

map.bin is the map: exactly AREA_COLS x AREA_ROWS tile indices, one byte each, row
major with an AREA_COLS byte stride, which the engine reads at
TILE_MAP + row*AREA_COLS + col.  engine.acme asserts that size, so a file of the
wrong shape fails the build rather than scrolling garbage.

map-world.bin is a 256x96 atlas to cut areas out of -- an authoring convenience,
nothing the engine knows about.  map.bin is checked in, so the build never runs
this.

  tools/mkarea.py --src map-world.bin -o map.bin --cut 40,2
  tools/mkarea.py -o map.bin --fill 136          # uniform map, for camera-bound checks
"""
import argparse

SRC_W, SRC_H = 256, 96          # shape of the atlas file, not of the map
AREA = 32                       # AREA_COLS / AREA_ROWS in engine.acme


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--src", default="map-world.bin", help=f"{SRC_W}x{SRC_H} source world map")
    p.add_argument("-o", "--out", default="map.bin")
    p.add_argument("--cut", default="40,2", help="col,row of the area in the source")
    p.add_argument("--size", type=int, default=AREA, help="area edge, in tiles")
    p.add_argument("--fill", type=int, default=None,
                   help="ignore --cut and fill the whole map with this tile index")
    a = p.parse_args()

    if a.fill is not None:
        out = bytearray([a.fill]) * (a.size * a.size)
        what = f"filled with tile {a.fill}"
    else:
        cut_c, cut_r = (int(v) for v in a.cut.split(","))
        with open(a.src, "rb") as f:
            src = f.read()
        if len(src) != SRC_W * SRC_H:
            p.error(f"{a.src} is {len(src)} bytes, expected {SRC_W}x{SRC_H} = {SRC_W * SRC_H}")

        out = bytearray(a.size * a.size)
        for r in range(a.size):
            for c in range(a.size):
                out[r * a.size + c] = src[((cut_r + r) % SRC_H) * SRC_W + ((cut_c + c) % SRC_W)]
        what = f"cut from ({cut_c},{cut_r}) of {a.src}"

    with open(a.out, "wb") as f:
        f.write(out)
    print(f"{a.out}: {a.size}x{a.size} tiles ({len(out)} bytes), {what}")


if __name__ == "__main__":
    main()
