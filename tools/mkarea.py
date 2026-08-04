#!/usr/bin/env python3
"""Cut an area out of the world atlas and write it plus the tileset it needs.

An area is four generated files, all checked in, so the build never runs this:

  map.bin      AREA_COLS x AREA_ROWS tile indices, one byte each, row major with an
               AREA_COLS byte stride, which the engine reads at
               TILE_MAP + row*AREA_COLS + col
  colors.bin   TILE_CHARS planes of TILES bytes -- char c of tile t is at c*TILES + t
  screen.bin   likewise
  pixels.bin   TILE_CHARS*8 planes of TILES bytes -- row r of char c of tile t is at
               c*8*TILES + r*TILES + t

engine.acme asserts every one of those sizes, so a file of the wrong shape fails the build rather than scrolling garbage.

The authored sources are world indexed and the engine knows nothing about them:
map-world.bin is a 256x96 atlas to cut areas out of, and colors-world.bin / screen-world.bin / pixels-world.bin are the
master tileset its indices refer to.
An area uses only some of those tiles, so its cut is renumbered to a dense 0..n-1 and its tileset re-cut at the engine's
TILES stride.
Cutting at TILES keeps every tile index inside one page of every plane, which is worth two raster lines a frame in
COPY_TILES -- see the page-crossing assertion in engine.acme.
A megabyte of flash is plenty for a tileset per area, reused across as many areas as share a look.

  tools/mkarea.py --cut 40,2                     # the village
  tools/mkarea.py --fill 136                     # uniform map, for camera-bound checks
  tools/mkarea.py --cut 40,2 --tiles 64          # ... against a smaller TILES
"""
import argparse

SRC_W, SRC_H = 256, 96          # shape of the atlas file, not of the map
AREA = 32                       # AREA_COLS / AREA_ROWS in engine.acme
TILES = 128                     # TILES in engine.acme -- the tileset's capacity
TILE_CHARS = 6                  # TILE_COLS * TILE_ROWS in engine.acme

# One entry per generated plane set: the authored master, the file to write, and how many planes of TILES bytes it holds.
PLANES = [("colors-world.bin", "colors.bin", TILE_CHARS),
          ("screen-world.bin", "screen.bin", TILE_CHARS),
          ("pixels-world.bin", "pixels.bin", TILE_CHARS * 8)]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--src", default="map-world.bin", help=f"{SRC_W}x{SRC_H} source world map")
    p.add_argument("-o", "--out", default="map.bin")
    p.add_argument("--cut", default="40,2", help="col,row of the area in the source")
    p.add_argument("--size", type=int, default=AREA, help="area edge, in tiles")
    p.add_argument("--fill", type=int, default=None,
                   help="ignore --cut and fill the whole map with this world tile index")
    p.add_argument("--tiles", type=int, default=TILES,
                   help="tileset capacity, TILES in engine.acme")
    a = p.parse_args()

    if a.fill is not None:
        world = bytearray([a.fill]) * (a.size * a.size)
        what = f"filled with world tile {a.fill}"
    else:
        cut_c, cut_r = (int(v) for v in a.cut.split(","))
        with open(a.src, "rb") as f:
            src = f.read()
        if len(src) != SRC_W * SRC_H:
            p.error(f"{a.src} is {len(src)} bytes, expected {SRC_W}x{SRC_H} = {SRC_W * SRC_H}")

        world = bytearray(a.size * a.size)
        for r in range(a.size):
            for c in range(a.size):
                world[r * a.size + c] = src[((cut_r + r) % SRC_H) * SRC_W + ((cut_c + c) % SRC_W)]
        what = f"cut from ({cut_c},{cut_r}) of {a.src}"

    # Renumber the tiles the area uses to a dense 0..n-1.
    # In world order, so that a tileset is a function of the area alone and regenerating an unchanged area is a no-op.
    used = sorted(set(world))
    if len(used) > a.tiles:
        p.error(f"the area needs {len(used)} distinct tiles but TILES is {a.tiles}")
    remap = {t: i for i, t in enumerate(used)}

    with open(a.out, "wb") as f:
        f.write(bytes(remap[t] for t in world))
    print(f"{a.out}: {a.size}x{a.size} tiles ({a.size * a.size} bytes), {what}")

    for master, out, planes in PLANES:
        with open(master, "rb") as f:
            data = f.read()
        if len(data) % planes:
            p.error(f"{master} is {len(data)} bytes, not {planes} whole planes")
        world_tiles = len(data) // planes
        if used[-1] >= world_tiles:
            p.error(f"the area uses world tile {used[-1]} but {master} holds {world_tiles}")

        dst = bytearray(planes * a.tiles)
        for plane in range(planes):
            for new, old in enumerate(used):
                dst[plane * a.tiles + new] = data[plane * world_tiles + old]
        with open(out, "wb") as f:
            f.write(dst)
        print(f"{out}: {planes} planes x {a.tiles} tiles ({len(dst)} bytes), from {master}")

    print(f"tileset: {len(used)} of {a.tiles} slots used, {a.tiles - len(used)} free")


if __name__ == "__main__":
    main()
