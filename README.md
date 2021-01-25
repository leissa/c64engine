# c64engine

A game engine for the c64.

## Building

Dependencies:
* [acme](https://sourceforge.net/projects/acme-crossass/)
* [cc65](https://github.com/cc65/cc65)

The following dependencies are automatically dealt with by the `Makefile`:
* [Krill's loader](https://csdb.dk/release/?id=189130)
* [exomizer](https://github.com/exomiser/Exomiser) (using Krill's intree sources)
* [tinycrunch](https://csdb.dk/release/?id=168629) (using Krill's intree sources)

```bash
cp config.default.template config.default
vim config.default # edit
make
```

## Running

Before running in VICE, make sure 'True drive emulation' is enabled and 'IEC-device' is -disabled-.
```bash
make run
```

Use joystick in port 2 to run the demo.

## Features

* Bitmap scrolling using [AGSP](http://codebase64.org/doku.php?id=base:agsp_any_given_screen_position)

    This technique only requires 36 raster lines CPU time and 33 raster lines of screen space. All other screen space - including screen memory (used for colors ```%01``` and ```%10```) and color ram (color ```%11```) is moved around as well.

* Sprite-Multiplexer

    Multiplixing 24 x 2 sprites. This means 24 virtual multi-color sprites where each sprite is overlayed with a single-color sprite for more colors and better resolution.

* Tile-Copying

    The binary format of the files is as follows:

    map.bin: map width * map height bytes (here 256 * 96). Each byte is a tile index into the tile data: pixels, screen, colors
    pixels.bin: tile width * tile height * 8 bytes per tile (here 3 * 2 * 8). Each bit pair in a byte is a color number: 0-3 (multicolor)
    screen.bin: tile width * tile height bytes per tile. For each byte, the upper 4 bits are color 1 and the lower 4 bits are color 2
    colors.bin: tile width * tile height bytes per tile. For each byte, the upper 4 bits are ignored and the lower 4 bits are color 3

    Color 0 (the shared background color) is black, but this can of course be changed to any of the 16 colors. If you are generating
    your own tile data, it is adviced to give priority to color number 3. In this way it is possible to reduce the problem of the
    sprite pointers overwriting the screen colors if certain tiles use only 2 colors (color 0 & color 3).

* Map-loader (credits for the disk loader go to Krill)

## Useful Links

* [Spritemate](http://spritemate.com/)
* [Secret colours of the Commodore 64](http://www.aaronbell.com/secret-colours-of-the-commodore-64/)
* [Commodore VIC-II Color Analysis](http://unusedino.de/ec64/technical/misc/vic656x/colors/)
* [Commodore 64 memory map](http://sta.c64.org/cbm64mem.html)
* [ca65 macro assembler from cc65](http://www.cc65.org/doc/ca65.html): I consider switching over from ACME.
