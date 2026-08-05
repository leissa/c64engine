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

The cartridge does not fit in ROM: the tile data at `$3000-$adff` lies straight through both cartridge windows, so a
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
  Their row fills the visible part of the band exactly — the band shows 21 raster lines and a sprite is 21 lines tall —
  so the panel neither loses its top edge to the border nor hangs down into the map.

  The two sets share the same 8 hardware sprites — the panel owns them across the band, the multiplexer takes over
  below it.

- Tile-Copying

  A tile is `TILE_COLS` x `TILE_ROWS` = 3 x 2 chars, i.e. 24 x 16 pixels, and an area's tileset holds `TILES` = 128 of them.
  Tiles are streamed into the bitmap a column or a row at a time as the camera moves, spread over several frames
  because a whole column or row does not fit in one frame's raster budget.
  - `map.bin`: one byte per map position, each a tile index into the three files below.

    The map is a single **area** of `AREA_COLS` x `AREA_ROWS` = 32 x 32 tiles — about 2.4 by 2.6 screens — and that is
    the whole world: `map.bin` is exactly 1024 bytes, row major with a 32 byte stride, and a tile index lives at
    `TILE_MAP + row*AREA_COLS + col`.
    The camera is clamped to it, so the scroll stops at the edges.

  These four files *are* the area — authored assets, checked in, with no generator behind them.
  The tileset is per area rather than global, which is why its indices are dense: the demo area uses 95 of the `TILES` =
  128 slots, and a tileset per area costs nothing on a 1 MiB cartridge.
  Areas that share a look can share one.

  The other three files are indexed **by char position first and by tile second**, not tile by tile.
  The copy loop reads `TILE_<what> + char*TILES + tile`, so all 128 bytes for char 0 come first, then all of char 1, and so on up to char 5.
  `TILES` = 128 is what makes that fast: the copy reads a plane with `abs,x` indexed by the tile, so each plane is aligned to 128 bytes and never straddles a page.
  That is worth two raster lines a frame in page-crossing penalties.
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

  Screen memory is a 1024 byte ring and the VIC reads the sprite pointers from a slot inside it, so eight char cells of
  the map always take their `%01`/`%10` colors from pointer bytes that change every frame.
  Which cells those are is set by `RING_PHASE`, and it is chosen so that as many of them as possible land where the
  camera and the AGSP band can never show them — 32 instead of 57 out of 32 x 32 tiles.
  `tools/ringphase.py` enumerates all 1024 phases; the choice is pure geometry, so it holds for any map, and the `%11`
  advice above is what removes the rest.

  They are fixed cells of the map, not of the screen, so they do not move with the camera.
  For `RING_PHASE` = 544 they are these seven runs of eight, in char coordinates into the area — column `0`-`95`, row
  `0`-`63`, so char `(col, row)` belongs to tile `(col/3, row/2)` at sub-position `(col%3, row%2)`:

  | char row | char cols | tile row | tile sub-row | tile cols touched | ever visible |
  | -------: | --------: | -------: | -----------: | ----------------: | ------------ |
  |       10 |     72-79 |        5 |            0 |             24-26 | yes          |
  |       11 |     32-39 |        5 |            1 |             10-13 | yes          |
  |       36 |     56-63 |       18 |            0 |             18-21 | yes          |
  |       37 |     16-23 |       18 |            1 |               5-7 | yes          |
  |       61 |     80-87 |       30 |            1 |             26-29 | never        |
  |       62 |     40-47 |       31 |            0 |             13-15 | never        |
  |       63 |       0-7 |       31 |            1 |               0-2 | never        |

  56 cells in total, of which the last three runs — 24 cells — sit where the camera clamp and the AGSP band can never
  show them.
  Within a run the cells are hardware sprites `0` to `7` from left to right: a cell's `%01` color is the high nibble of
  that sprite's pointer byte, `%10` the low nibble.
  The four visible runs are exactly where a tile drawn with only `%00` and `%11` pays off, and on the demo area's art
  9 of those 32 cells already are.

  The coordinates follow from `(RING_PHASE + col + SCREEN_COLS*row) mod 1024` landing in the eight pointer bytes, so
  regenerate the table after changing `RING_PHASE`, the area size or the camera clamp:

  ```bash
  tools/ringphase.py --phase 544 --art
  ```

  All four files are linked into the image by `engine.acme` at the addresses given in `lib/mem.acme`, and travel in
  the cartridge from there — there is no separate asset pipeline.

## Development

```bash
make dev        # engine-dev.crt with -DDEVELOP=1 -DDEBUG=1: border timing bands, raster-overrun check
make run-dev    # ... and run it
make regress    # headless VICE run of a scripted joystick pattern; fails on a blown raster budget
```

The development cartridge is built and booted exactly like the release one, so it exercises the boot stub too.
`make dev DEV_FLAGS=-DDEVELOP=1` gives the raster-overrun check without the debug display.

`engine.obj` is the same payload as a plain program: the BASIC starter at `$0801` is always assembled in, so
`cp engine.obj x.prg` gives VICE something to autostart, which makes the cartridge and the bare payload a useful A/B
pair when the cartridge misbehaves.

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
