# c64engine

A game engine for the c64.

## Building

The engine builds as a 1 MiB [EasyFlash](http://skoe.de/easyflash/) cartridge.

Dependencies:
* [acme](https://sourceforge.net/projects/acme-crossass/)
* python3 and wget

The following is fetched automatically by the `Makefile`:
* [EAPI](http://skoe.de/easyflash/files/devdocs/EasyFlash-ProgRef.pdf), the EasyFlash flash driver, from a pinned
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

* Bitmap scrolling using [AGSP](https://codebase64.net/doku.php?id=base:agsp_any_given_screen_position)

    This technique only requires 36 raster lines CPU time and 33 raster lines of screen space.
    All other screen space - including screen memory (used for colors ```%01``` and ```%10```) and color ram (color
    ```%11```) is moved around as well.

* Sprite-Multiplexer

    Multiplixing 24 x 2 sprites.
    This means 24 virtual multi-color sprites where each sprite is overlayed with a single-color sprite for more colors
    and better resolution.

* Tile-Copying

    The binary format of the files is as follows:

    * `map.bin`: `map width` * `map height` bytes (here 256 * 96).

        Each byte is a tile index into the tile data: pixels, screen, colors

    * `pixels.bin`: `tile width` * `tile height` * 8 bytes per tile (here 3 * 2 * 8).

        Each bit pair in a byte is a color number: 0-3 (multicolor)

    * `screen.bin`: `tile width` * `tile height` bytes per tile.

        For each byte, the upper 4 bits are color 1 and the lower 4 bits are color 2

    * `colors.bin`: `tile width` * `tile height` bytes per tile.

        For each byte, the upper 4 bits are ignored and the lower 4 bits are color 3

    Color `%00` (the shared background color) is black, but this can of course be changed to any of the 16 colors.
    If you are generating your own tile data, it is adviced to give priority to color number `%11`.
    In this way it is possible to reduce the problem of the sprite pointers overwriting the screen colors if certain
    tiles use only color `%00` & color `%11`.

    These four files are linked into the image by `engine.acme` at the addresses given in `lib/mem.acme`, and travel in
    the cartridge from there.

## Useful Links

* [Spritemate](http://spritemate.com/)
* [Secret colours of the Commodore 64](http://www.aaronbell.com/secret-colours-of-the-commodore-64/)
* [Commodore VIC-II Color Analysis](http://unusedino.de/ec64/technical/misc/vic656x/colors/)
* [Commodore 64 memory map](http://sta.c64.org/cbm64mem.html)
