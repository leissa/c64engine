# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Commodore 64 game engine written entirely in 6510 assembly for the **ACME** cross-assembler. It scrolls a full multicolor bitmap in all 8 directions using AGSP (FLD + line crunch + VSP), multiplexes 24×2 sprites, streams tiles from a 256×96 map, and plays music — all inside one cycle-exact raster interrupt chain.

There are no tests, no linter, and no test framework. Correctness is verified by running in VICE and watching for `jam` (see *Debugging*).

## Build

`config.default` is git-ignored and **required**; create it first:

```bash
cp config.default.template config.default   # then edit tool paths
make                                        # -> engine.d64
make run                                    # x64 engine.d64
make clean                                  # removes d64/exo/tc artifacts
make distclean                              # also removes ./krill
```

The first `make` downloads and builds Krill's loader into `./krill` (also git-ignored), which in turn provides `cc1541`, `exomizer`, and `tinycrunch`. Use `make Q=` to echo every command.

VICE must have *True drive emulation* **enabled** and *IEC-device* **disabled**, since the disk build installs Krill's 1541 drive code.

### Two build modes

| | Disk build (`make`) | `make dev` / `make prg` |
|---|---|---|
| Symbols | — | `-DDEVELOP=1` (+ `-DDEBUG=1` for `dev`) |
| Output | `engine.d64` | `engine.prg` (via `!to` in `engine.acme`) |
| Tile data | loaded at runtime from disk via `loadcompd` | assembled in with `!bin` at `TILE_*` addresses |
| Krill loader | installed and copied to `$0200` | omitted entirely |

`make dev`/`make prg` are the fast iteration path — plain ACME, no disk image, no compression. They are deliberately phony and rebuild unconditionally: both write the same `engine.prg` with different flags, so timestamp tracking would wrongly skip a rebuild when you switch between them.

### Asset pipeline (disk build only)

`%.bin` → `%.prg` → `%.tc` → `engine.d64`. The `.bin` files carry no load address; the Makefile prepends one from the per-file `map.bin.addr`-style variables, which **must stay in sync with the `TILE_*` constants in `lib/mem.acme`** (a `.bin` with no such variable is a hard error rather than a silently headerless PRG). Then `tinycrunch` compresses each, and `cc1541` writes them alongside the exomized `engine.exo` under the PETSCII names `map`, `colors`, `screen`, `pixels` that `engine.acme` passes to `loadcompd`. `engine.acme` also emits `labels.l` for VICE's monitor.

Adding a tile-data file means touching three places that must agree: the `TILE_*` base in `lib/mem.acme`, the `.addr` variable in the Makefile, and the `loadcompd` name in `engine.acme`. The Makefile's `DISK_ORDER` should also list it, so the directory order keeps matching the load order and the drive head only moves forward.

## Architecture

### Memory map — `lib/mem.acme`

This file is the single source of truth for the *entire* address space: zero-page variable allocation, code/data segment bases, and VIC bank layout. Read it before touching anything that allocates memory. Highlights:

- The engine runs with `ALL_RAM_WITH_IO` (`$01 = %00110101`) — no BASIC, no KERNAL. Startup points NMI/IRQ vectors at `EMPTY_INTERRUPT`, kills CIA timer IRQs, and never acks NMI again, so the whole zero page except `$00`/`$01` is free.
- VIC uses bank 3 (`$c000-$ffff`): bitmap at `$c000`, screen at `$e000`, sprite frames at `$e400`. Sprite pointers live at `SPR_PTR = SCREEN+$0400-8`.
- `TILE_PIX` (`$9c00-$bfff`) is 9k of tile pixel data; the 4k of RAM under the I/O area is part of the bitmap, so `tiles.acme` toggles `RAM_ROM_SELECTION` to `ALL_RAM` around pixel writes.
- `TILE_MAP` overlaps `DISK_LOADER_SRC`/`DISK_INSTALLER` — the installer is consumed before the map is loaded.

### Raster IRQ chain — `raster.acme`

One frame is a hand-timed state machine of chained interrupts, each stage re-pointing `VECTOR_IRQ` at the next. Almost every instruction carries a `; N` cycle-count comment and each block ends with a `;--> total`; **these comments are load-bearing** — the `+wait`/`+wait_even`/`+wait_loop` macros in `lib/std.acme` pad to exact cycle counts derived from them. Changing an instruction means re-deriving the padding.

Stages, in order:

1. **`LINE_0`** (`FIRST_BADLINE-3`) — double-IRQ raster stabilization via `tsx`/`cli`, verified by a `jam` if `VIC_RASTER` is wrong.
2. **`LINE_0+1`** — computes the VSP nop-skip count from `HARD_X` and patches `.self_modifying_branch__nops`/`__lsb` in place.
3. **FLD + line crunch** — `HARD_Y` iterations of `inc_vic_control_y`, always totalling 25 raster lines. Sprites in the crunch area take a shorter 44-cycle path.
4. **VSP** — the self-modified nop field lands the badline on the right cycle. Guarded by `!if (>IRQ) != (>*) { !error }`: the critical code must not cross a page, which is why `IRQ` is `!align 255, 0`.
5. **Soft scroll**, then **sprite multiplexing** (`SPRITES` virtual sprites over 8 hardware ones, two hardware sprites per virtual one for extra colors).
6. **`last_irq`** — the "off-screen" budget: `JOYSTICK`, `COPY_TILES`, `PLAY_SONG`, sprite register updates, and an unrolled bubble-sort pass over `SPR_I` by `SPR_Y`.

`HARD_X`/`HARD_Y`/`SOFT_X`/`SOFT_Y` are not variables but `*+1` labels pointing at immediate operands inside the IRQ — self-modifying code is the norm here, not an exception.

### Scrolling — `scroll.acme`

`SCROLL_U/D/L/R` advance `SOFT_*` by `SCROLL_SPEED` and, on wrap, `HARD_*`. `INC_HARD_Y`/`DEC_HARD_Y` handle the AGSP coupling where a Y wrap shifts `HARD_X` by 16. At the halfway point of a soft scroll they seed `C_COPY`/`R_COPY` and step the `{C,R}_{MAP,SCR,PIX,CLR}_POS_*` pointer sets, which are the source (map) and destination (screen/bitmap/color) cursors for tile copying.

### Tile copying — `tiles.acme`

Copying a whole column or row of tiles doesn't fit in one frame's raster budget, so it's split across `COPY_COL_FRAMES`/`COPY_ROW_FRAMES` frames. `COPY_TILES` (called once per frame from `last_irq`) dispatches on the `C_COPY`/`R_COPY` counters into `copy_col_tiles1/2` and `copy_row_tiles1/2`. The `copy_tile_charN` routines are macro-generated, one per position within a tile (`TILE_COLS`×`TILE_ROWS` = 3×2).

`init_screen` in `engine.acme` fills the initial screen by calling `SCROLL_L` + `COPY_TILES` in a loop rather than duplicating the copy logic.

### Tunables — top of `engine.acme`

`SCROLL_SPEED` (1 or 2), `SPRITES` (0, or ≥4), `TILE_COLS`/`TILE_ROWS`, `SPRITES_TOP_Y`/`SPRITES_MAX_Y`, `TILES`, `COPY_*_FRAMES`. These feed `!if`/`!for` conditionals throughout `raster.acme` and `tiles.acme` that generate structurally different code — e.g. `SPRITES = 0` inlines `inc_vic_control_y` as a macro, otherwise it becomes a `jsr`-able routine with different cycle budgets.

## Conventions

- `lib/std.acme` provides the vocabulary: long branches (`+jeq`, `+jcc`, …), unsigned/signed comparison branches (`+bugt`, `+bsle`, …), `+set`/`+set16`/`+copy`, `+wait*`, `+create_basic_starter`, and page-boundary-checking skip-branches (`+bcc`, `+bne`, … with no argument) that `!warn` when a branch crosses a page.
- `!cpu 6510` — illegal opcodes are fair game.
- Every routine is wrapped in `!zone { }` so `.local` labels can repeat; `+`/`-` are ACME's anonymous forward/backward labels.
- `lib/vic.acme` and `lib/cia.acme` are register/constant definitions with the relevant bit-field documentation in comments — prefer the named constants over raw `$d0xx`.

## Debugging

`-DDEBUG=1` (i.e. `make dev`) turns on:

- `VIC_BORDER` colour bands marking where `JOYSTICK`, `COPY_TILES`, sprite sorting, and multiplexing run — this is how you see the raster budget.
- Text/40-col-ish VIC control values instead of multicolor bitmap mode.
- `!warn` output for the code/frame end addresses and wasted bytes before `IRQ`.

`-DDEVELOP=1` alone adds a raster-overrun check at the end of `last_irq` that executes `jam` if the frame's work spilled past `LINE_0-1`. A freeze in VICE's monitor at a `jam` means you blew the cycle budget.
