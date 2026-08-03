#!/usr/bin/env python3
"""Cut a 32x32 tile area out of the big world map and build map.bin from it.

map.bin is addressed by the engine as TILE_MAP + row*256 + col -- the map cursor
packs the row in the high byte and the column in the low byte -- so the row stride
is fixed at 256 whatever the area size is.  An area therefore lives as a 32x32
window inside that address space, which leaves room for an 8x3 grid of areas in
the same 24k.  Everything outside the area is filled with PAD so the camera
running past the bounds shows impassable undergrowth rather than stray tiles.

  tools/mkarea.py --src map-world.bin -o map.bin --cut 40,2 --at 96,32
"""
import argparse

MAP_W, MAP_H = 256, 96          # the address space, not the area
AREA = 32                       # area edge, in tiles
PAD = 0                         # tile 0: dense undergrowth, see the atlas


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--src", default="map-world.bin", help="256x96 source world map")
    p.add_argument("-o", "--out", default="map.bin")
    p.add_argument("--cut", default="40,2", help="col,row of the area in the source")
    p.add_argument("--at", default="96,32", help="col,row to place the area at")
    p.add_argument("--size", type=int, default=AREA)
    p.add_argument("--pad", type=int, default=PAD)
    a = p.parse_args()

    cut_c, cut_r = (int(v) for v in a.cut.split(","))
    at_c, at_r = (int(v) for v in a.at.split(","))
    if at_c + a.size > MAP_W or at_r + a.size > MAP_H:
        p.error(f"area at {at_c},{at_r} of size {a.size} does not fit in {MAP_W}x{MAP_H}")

    with open(a.src, "rb") as f:
        src = f.read()
    if len(src) != MAP_W * MAP_H:
        p.error(f"{a.src} is {len(src)} bytes, expected {MAP_W * MAP_H}")

    out = bytearray([a.pad]) * (MAP_W * MAP_H)
    for r in range(a.size):
        for c in range(a.size):
            t = src[((cut_r + r) % MAP_H) * MAP_W + ((cut_c + c) % MAP_W)]
            out[(at_r + r) * MAP_W + (at_c + c)] = t

    with open(a.out, "wb") as f:
        f.write(out)
    print(f"{a.out}: {a.size}x{a.size} area from ({cut_c},{cut_r}) placed at "
          f"({at_c},{at_r}), rest = tile {a.pad}")


if __name__ == "__main__":
    main()
