# c64engine

A game engine for the c64.

## Building

The engine builds as a 1 MiB [EasyFlash](http://skoe.de/easyflash/) cartridge.

Dependencies:

- [acme](https://sourceforge.net/projects/acme-crossass/)
- python3 and wget

The following is fetched automatically by the `Makefile`:

- [EAPI](http://skoe.de/easyflash/files/devdocs/EasyFlash-ProgRef.pdf), the EasyFlash flash driver, from a pinned
  revision of the [EasySDK](https://github.com/luigidifraia/easyflash) and assembled with `acme`

```bash
cp config.default.template config.default
vim config.default # edit
make
```

This produces `engine.crt`, ready to run in an emulator or to flash onto an EasyFlash 1/3 with the usual tools.
It shows up in the EasyFlash 3 menu as `c64engine`; override with `make CART_NAME="..."`.

## Running

```bash
make run
```

Use joystick in port 2 to run the demo.
Hold `RUN/STOP` while the machine resets to switch the cartridge off and drop to BASIC.

The cartridge does not fit in ROM: the tile data at `$3000-$bfff` lies straight through both cartridge windows, so a
small boot stub in bank 0 copies everything into RAM, switches the cartridge off and jumps to the engine.
See `easyflash.acme` and `tools/mkcart.py`.

Note that `make run` passes `+easyflashcrtwrite`.
VICE otherwise writes the cartridge image back on exit, which rewrites the name and drops every unused bank from
`engine.crt`.

## Features

- Bitmap scrolling using [AGSP](https://codebase64.net/doku.php?id=base:agsp_any_given_screen_position)

  A full multicolor bitmap scrolls in all 8 directions without any pixel data being moved: FLD plus line crunch for
  the vertical offset, VSP (DMA delay) for the horizontal one.
  Screen memory (colors `%01` and `%10`) and color RAM (`%11`) move with it.

  The AGSP band costs a fixed **25 raster lines** of screen space at the top of the frame, and the hand-timed part of
  the frame runs from raster line 45 to the soft-scroll release at line 82.
  Everything else — joystick, tile copying, music, sprite bookkeeping — runs in the off-screen budget below line 47.

- Sprite multiplexer

  **16 world sprites**, each built from two hardware sprites: a multicolor sprite with a single-color hires sprite
  overlaid on top, for more colors and better resolution.
  They are multiplexed over **4 hardware pairs** and pinned to the map, so they scroll with the world.

  When sprites cluster in Y and 4 pairs cannot cover them all, the display list is thinned in Y order — all 16 every
  frame, else every 2nd on alternate frames, else every 4th over four frames — instead of dropping whichever sprite
  happens not to fit.
  Nothing ever blinks out; the density degrades evenly.

  **8 panel sprites** on top of that, all sharing one raster line inside the black AGSP band: one hardware sprite
  each, single color, meant for hitpoints, weapons or text.
  They are written straight out every frame and take no part in the multiplexer.

  The two sets share the same 8 hardware sprites — the panel owns them across the band, the multiplexer takes over
  below it.

- Tile-Copying

  A tile is `TILE_COLS` x `TILE_ROWS` = 3 x 2 chars, i.e. 24 x 16 pixels, and there are `TILES` = 185 of them.
  Tiles are streamed into the bitmap a column or a row at a time as the camera moves, spread over several frames
  because a whole column or row does not fit in one frame's raster budget.
  - `map.bin`: one byte per map position, each a tile index into the three files below.

    The map is a single **area** of `AREA_COLS` x `AREA_ROWS` = 32 x 32 tiles — about 2.4 by 2.6 screens — and that is
    the whole world: `map.bin` is exactly 1024 bytes, row major with a 32 byte stride, and a tile index lives at
    `TILE_MAP + row*AREA_COLS + col`.
    The camera is clamped to it, so the scroll stops at the edges.

    This file is generated rather than authored — `map-world.bin` is a 256 x 96 atlas to cut areas out of, which the
    engine knows nothing about:

    ```bash
    tools/mkarea.py --src map-world.bin -o map.bin --cut 40,2
    ```

  The other three files are indexed **by char position first and by tile second**, not tile by tile.
  The copy loop reads `TILE_<what> + char*TILES + tile`, so all 185 bytes for char 0 come first, then all of char 1,
  and so on up to char 5.
  - `pixels.bin`: `char*8*TILES + row*TILES + tile`, so 8 rows per char and 48 bytes per tile.

    Each bit pair in a byte is a color number `%00`-`%11` (multicolor bitmap mode).

  - `screen.bin`: 6 bytes per tile, one per char.

    Upper 4 bits are the color for bit pair `%01`, lower 4 bits the color for `%10`.

  - `colors.bin`: 6 bytes per tile, one per char, and goes to color RAM.

    Upper 4 bits are ignored, lower 4 bits are the color for `%11`.

  Color `%00` (the shared background color) is black, but this can of course be changed to any of the 16 colors.
  If you are generating your own tile data, it is advised to give priority to color number `%11`.
  In this way it is possible to reduce the problem of the sprite pointers overwriting the screen colors if certain
  tiles use only color `%00` & color `%11`.

  All four files are linked into the image by `engine.acme` at the addresses given in `lib/mem.acme`, and travel in
  the cartridge from there — there is no separate asset pipeline.

## Development

```bash
make dev        # engine.prg with -DDEVELOP=1 -DDEBUG=1: border timing bands, raster-overrun check
make prg        # engine.prg with -DDEVELOP=1 only
make regress    # headless VICE run of a scripted joystick pattern; fails on a blown raster budget
```

`engine.prg` is the same payload as the cartridge, just entered from a BASIC starter instead of the boot stub, which
makes the two a useful A/B pair when the cartridge misbehaves.

`make regress` can also diff rendering against a captured baseline:

```bash
cp -r regress regress-before
make regress REGRESS_REF=regress-before
```

## Useful Links

- [Spritemate](http://spritemate.com/)
- [Secret colours of the Commodore 64](http://www.aaronbell.com/secret-colours-of-the-commodore-64/)
- [Commodore VIC-II Color Analysis](http://unusedino.de/ec64/technical/misc/vic656x/colors/)
- [Commodore 64 memory map](http://sta.c64.org/cbm64mem.html)
