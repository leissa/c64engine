# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Commodore 64 game engine written entirely in 6510 assembly for the **ACME** cross-assembler.
It scrolls a full multicolor bitmap in all 8 directions using AGSP (FLD + line crunch + VSP), multiplexes 24×2 sprites,
streams tiles from a 256×96 map, and plays music — all inside one cycle-exact raster interrupt chain.
It ships as a 1 MiB EasyFlash cartridge.

There is no linter and no unit-test framework.
The one automated check is `make regress` (see *Testing*), which replays a scripted joystick pattern in a headless VICE
and fails on a blown raster budget or, against a saved reference, on any rendering change.

## Build

`config.default` is git-ignored and **required**; create it first:

```bash
cp config.default.template config.default   # then edit tool paths
make                                        # -> engine.crt
make run                                    # x64 +easyflashcrtwrite -cartcrt engine.crt
make clean                                  # crt/obj/efboot/prg/labels
make distclean                              # also removes the fetched ./eapi
```

The first `make` fetches the EAPI sources into `./eapi` (git-ignored) and assembles them with the same `acme`;
after that the build needs no network.
Use `make Q=` to echo every command and to pass `-v` to `mkcart.py`.

`make dev` / `make prg` are the fast iteration path: `-DDEVELOP=1` (plus `-DDEBUG=1` for `dev`) makes `engine.acme` emit
`engine.prg` via its own `!to`, which you can load in VICE directly.
That `.prg` *is* the cartridge payload — same image, just entered from the BASIC starter instead of from the boot stub,
which makes it a good A/B reference when the cartridge misbehaves.
Both targets are deliberately phony and rebuild unconditionally: they write the same `engine.prg` with different flags,
so timestamp tracking would wrongly skip a rebuild when you switch between them.

**`make run` must keep `+easyflashcrtwrite`.**
VICE writes the cartridge image back on exit by default, which rewrites
the CRT name and — with its optimizer — drops every unused bank, silently replacing your 1 MiB artifact with a 4-bank
one that `make` then considers up to date.

### Cartridge pipeline

`engine.acme` → `engine.obj` and `easyflash.acme` → `efboot.bin`, both fed to `tools/mkcart.py`, which writes
`engine.crt` directly rather than going through `cartconv -t easy` (explicit control over per-bank placement;
`cartconv -c` validates the result).
Tile data is `!bin`'d into the image at the `TILE_*` addresses, so there is no separate asset pipeline — adding a
tile-data file means only picking an address in `lib/mem.acme` and a `!bin` in `engine.acme`.

Everything about the layout follows the [EasyFlash Programmer's
Guide](http://skoe.de/easyflash/files/devdocs/EasyFlash-ProgRef.pdf);
the code cites section numbers.
Bank 0's ROMH chip holds EAPI at `$1800`, the `EF-Name:` menu entry at `$1b00` and the boot stub at `$1c00`;
banks 1-4 hold the payload.
`Makefile`'s `CART_SKIP` names the address ranges left out of the cartridge because `init_screen` builds them at
runtime, and must stay in sync with `lib/mem.acme`.

## Architecture

### Memory map — `lib/mem.acme`

This file is the single source of truth for the *entire* address space: zero-page variable allocation, code/data segment
bases, and VIC bank layout.
Read it before touching anything that allocates memory.
Highlights:

- The engine runs with `ALL_RAM_WITH_IO` (`$01 = %00110101`) — no BASIC, no KERNAL.
  Startup points NMI/IRQ vectors at `EMPTY_INTERRUPT`, kills CIA timer IRQs, and never acks NMI again, so the whole zero
  page except `$00`/`$01` is free.
- VIC uses bank 3 (`$c000-$ffff`): bitmap at `$c000`, screen at `$e000`, sprite frames at `$e400`.
  Sprite pointers live at `SPR_PTR = SCREEN+$0400-8`.
- `TILE_PIX` (`$9c00-$bfff`) is 9k of tile pixel data;
  the 4k of RAM under the I/O area is part of the bitmap, so `tiles.acme` toggles `RAM_ROM_SELECTION` to `ALL_RAM`
  around pixel writes.
- `$0200-$07ff` belongs to the cartridge boot: `EF_COPIER` (the relocated copier), `EF_TABLE_RAM` (the chunk table,
  lifted out of bank 1 because the copier switches banks as it walks), `EAPI_RAM` (reserved, see below) and `EF_BUFFER`
  (staging page).
  All of it is below the lowest payload destination `$0801`, so the copy cannot overwrite the code doing the copying.

### Raster IRQ chain — `raster.acme`

One frame is a hand-timed state machine of chained interrupts, each stage re-pointing `VECTOR_IRQ` at the next.
Almost every instruction carries a `; N` cycle-count comment and each block ends with a `;--> total`;
**these comments are load-bearing** — the `+wait`/`+wait_even`/`+wait_loop` macros in `lib/std.acme` pad to exact cycle
counts derived from them.
Changing an instruction means re-deriving the padding.

Stages, in order:

1. **`LINE_0`** (`FIRST_BADLINE-3`) — double-IRQ raster stabilization via `tsx`/`cli`, verified by a `jam` if
   `VIC_RASTER` is wrong.
2. **`LINE_0+1`** — computes the VSP nop-skip count from `HARD_X` and patches `.self_modifying_branch__nops`/`__lsb` in
   place.
3. **FLD + line crunch** — `HARD_Y` iterations of `inc_vic_control_y`, always totalling 25 raster lines.
   Sprites in the crunch area take a shorter 44-cycle path.
4. **VSP** — the self-modified nop field lands the badline on the right cycle.
   Guarded by `!if (>IRQ) != (>*) { !error }`:
   the critical code must not cross a page, which is why `IRQ` is `!align 255, 0`.
5. **Soft scroll**, then **sprite multiplexing** — see *Sprites* below.
6. **`last_irq`** — the "off-screen" budget: `JOYSTICK`, `COPY_TILES`, `PLAY_SONG`, the panel row, an insertion-sort
   pass over `SPR_I` by `SPR_Y`, and the sprite scheduling for the next frame.

`HARD_X`/`HARD_Y`/`SOFT_X`/`SOFT_Y` are not variables but `*+1` labels pointing at immediate operands inside the IRQ —
self-modifying code is the norm here, not an exception.

### Scrolling — `scroll.acme`

All four of `SCROLL_U/D/L/R` are generated from one `+scroll_axis .vertical, .dir` macro; they differ only in which
axis they walk and in the sign of every step.
They advance `SOFT_*` by `SCROLL_SPEED` and, on wrap, `HARD_*`.
`INC_HARD_Y`/`DEC_HARD_Y` handle the AGSP coupling where a Y wrap shifts `HARD_X` by 16.
At the halfway point of a soft scroll they seed `C_COPY`/`R_COPY` and step the `{C,R}_{MAP,SCR,PIX,CLR}_POS_*` pointer
sets, which are the source (map) and destination (screen/bitmap/color) cursors for tile copying.

**The horizontal axis runs backwards.** `SOFT_X` and `HARD_X` step *against* the map cursor, so `SCROLL_L`
(`.dir = -1`) increments both — the VSP delay in `raster.acme` is `39-HARD_X`, which is where the inversion comes
from.  The macro carries `.soft_dir` (`= .dir` vertically, `= -.dir` horizontally) for exactly this: anything reading
or stepping `SOFT_*`/`HARD_X` keys off `.soft_dir`, everything else off `.dir`.  Getting that wrong swaps the copy
trigger between the two horizontal directions and is invisible in a screenshot.

`SCROLL_SPRITES_UP/DOWN/LEFT/RIGHT` keep the sprites pinned to the map: `SPR_X`/`SPR_Y` are screen coordinates, so a
camera step has to move every sprite the other way.  Sprite ids `0..CRUNCH_SPRITES-1` are excluded — they are the ones
`_spr_y` parks in the FLD/crunch area, and they must keep the smallest `SPR_Y` or `last_irq` hands the multiplexer a
sprite starting before `SPRITES_TOP_Y` and the 44-cycle crunch path mistimes.  That is what the `SPR_WRAP_TOP` bound
enforces.  `SPR_X` is half resolution (`last_irq` does an `asl`), so it only steps on every second pixel of camera
travel.

**Recycling a sprite must reposition it in `SPR_I` by hand.**  Shifting every sprite by the same amount leaves the
sorted order intact, but a sprite that wraps travels from one end of the Y range to the other and has to travel the
whole length of `SPR_I` with it.  Left to the insertion sort in `last_irq` that is its O(n²) case, and it cost **~26 of
the 47 raster lines** of off-screen budget for a single wrap — measured, not estimated.  So the wrap moves the entry in
`SPR_I` directly and the sort then finds nothing to do.  `SPR_WRAP_MARGIN` exists because the order read there is the
one sorted at the end of the *previous* frame, so a wrap can be noticed a frame or two late.

The tunable constraints that used to be comments are now `!error` assertions at the top of the file:
`(SCROLL_ROWS-1) % TILE_ROWS` and `(SCROLL_COLS-1) % TILE_COLS` must be zero, because the direction-reversal cursor
jump is expressed in tiles and ACME's division truncates.

### Sprites

Two disjoint sets share the eight hardware sprites, and the split is what keeps the crunch band's timing honest.

`PANEL_SPRITES` (8) sit on one raster row inside the black FLD/crunch band, one hardware sprite each, single colour —
meant for hitpoints, weapons, text.  `last_irq` writes them straight out from `PANEL_X`/`PANEL_C`/`PANEL_F` (X is full
9-bit, with `PANEL_X_MSB`); they take no part in the sort or the multiplexer.
**They must share one Y**: the 44-cycle crunch path is `63-19`, i.e. all eight sprites DMA-active across the whole
band, so staggering them would need the FLD/crunch loop to carry a per-line cycle count.

`SPRITES` (16) are the world sprites below that, two hardware sprites each — a hires overlay over a multicolour one —
multiplexed over `SPRITE_SLOTS` (4) pairs.  `VIC_SPR_MULTI` is flipped between the two: `last_irq` clears it for the
panel row, the multiplexer sets `%10101010` when it takes over (safe, because the panel row ends at
`SPRITES_TOP_Y + SPRITE_HEIGHT`, just above the soft-scroll release line).

**Scheduling is decided in `last_irq`, before the frame is drawn.**  A slot is busy for `SPRITE_HEIGHT` lines, so
sprite *n* of the display list can only use slot `n % SPRITE_SLOTS` if it is that far below sprite `n-SPRITE_SLOTS`.
The old code discovered this the hard way and dropped whatever it could not place — sprites blinking out at random
whenever they clustered in Y.  Now the list is thinned until it fits:

| zones | shown per frame | each sprite appears |
|---|---|---|
| 4 | all 16 | every frame |
| 2 | every 2nd in Y order | every 2nd frame |
| 1 | every 4th in Y order | every 4th frame |

Thinning **in Y order, not by sprite id**, is the point: it halves the density of a cluster instead of leaving its
members to collide.  One zone is always feasible — `SPRITE_SLOTS` sprites over `SPRITE_SLOTS` slots — so the chain
terminates and nothing ever vanishes; it just degrades to a steady, controlled flicker.  `SPR_SHOWN` is how many
entries of `SPR_Q` the multiplexer walks, `SPR_FRAME` picks the phase.

The invariant worth re-checking after any change here is that the multiplexer places *every* scheduled sprite, i.e.
the `.last_irq` "too late" path is now unreachable.  Verified by stashing X at that exit and comparing it against
`SPR_SHOWN` in `last_irq`, over Y spacings from 8 down to 0.

Because the phase advances in `last_irq`, a clustered layout would keep the screen changing after the autopilot has
frozen `JOYSTICK`, which would break the reproducibility `make regress` depends on — hence `AP_FROZEN`, which stops
the phase too.

### Tile copying — `tiles.acme`

Copying a whole column or row of tiles doesn't fit in one frame's raster budget, so it's split across
`COPY_COL_FRAMES`/`COPY_ROW_FRAMES` frames.
`COPY_TILES` (called once per frame from `last_irq`) dispatches on the `C_COPY`/`R_COPY` counters into
`copy_col_tiles1/2` and `copy_row_tiles1/2`, which set `ITERATIONS` and fall into one shared `copy_*_tiles` body.
The `copy_tile_charN` routines are macro-generated, one per position within a tile (`TILE_COLS`×`TILE_ROWS` = 3×2);
because they all come from the same macro they are equal-sized, and `+jsr_copy_tile_char` addresses one arithmetically
instead of running a char index down a `cmp`/`bne` chain.

The per-frame loop is **unrolled by the tile cycle and specialised on the fixed coordinate**: along a column copy the
tile row is fixed and the sub-column cycles, along a row copy the reverse.  That makes the sub-char a compile-time
constant per slot, and lets the map byte be fetched once per tile rather than once per char.  A frame boundary can
fall anywhere in the cycle, so the loop is entered at the slot the previous frame stopped on and each slot has an exit
recording where to resume; the invariant is that the saved map pointer addresses the tile holding the *next* slot,
which is why the slot-0 exit (meaning "tile finished") steps it on.  Slot, exit and variant bodies must stay
equal-sized so they can be reached by `base + n*SIZE` — all three are asserted.

Keep an eye on the code segment.  It ends around `$1ae0` against `SONG_DATA` at `$2000`, and unrolling here eats that
margin fast: expanding the loop per entry point instead of sharing it cost ~900 bytes.  ACME only *warns* when the
next segment starts inside this one, so an overflow silently gets the tail of the code overwritten by the song binary
and shows up as a dead engine, not a build failure — `engine.acme` now turns that into an `!error`.

`init_screen` in `engine.acme` fills the initial screen by calling `SCROLL_L` + `COPY_TILES` in a loop rather than
duplicating the copy logic.  It only exercises the *row* path, which makes it a good first check after touching
`tiles.acme`: if the row copy is broken the screen comes up empty.

### Cartridge boot — `easyflash.acme` + `tools/mkcart.py`

EasyFlash powers up in Ultimax with bank 0 selected, so the reset vector and start-up code live at the end of bank 0's
ROMH chip, where Ultimax maps them to `$fc00-$ffff`.
Three constraints shape the rest, and each one cost a debugging round:

- **The code must move to RAM before anything touches `$de02`.**
  Ultimax can't write RAM above `$0fff`, and switching to
  16K mode moves ROMH from `$e000` to `$a000` — pulling the executing code out from under the CPU.
  So the stub relocates the copier to `EF_COPIER` and jumps there;
  both exits (boot and the `RUN/STOP` escape) then run from RAM.
- **The chunk table has to be lifted into RAM first.**
  It exists only in bank 1, and the copier switches banks as it
  walks the payload, so reading the table after the first bank wrap returns payload bytes instead of the terminator — an
  infinite loop.
- **Writes into `$8000-$bfff` go through the flash chip's command interface.**
  They reach RAM either way, but the
  Am29F040 decodes certain address/data sequences as unlock-and-program, and tens of kilobytes of map data is a
  plausible way to trip one on real hardware.
  So each page is staged via `EF_BUFFER` and stored with the cartridge switched off (`EF_RAM_LED`, which keeps the LED
  on).
  Verified: booting under VICE with write-back on and the optimizer off leaves all 128 chip images byte-identical.

The boot stub also has to do the I/O init the KERNAL would normally have done, and this is where the subtle bugs live.
Two that already bit:

- **CIA2 `DDRA` must be `$3f`.**
  Otherwise the engine's `sta CIA2_DATA_PORT_A` hits an all-inputs port, the VIC keeps
  reading bank 0, and you get a screen of structured garbage that looks like a corrupt copy but isn't.
- **`VIC_CONTROL_Y` must be left with RSEL set**, the way the KERNAL leaves `$1b`.
  The engine rewrites `$d011` several times per frame and always with RSEL clear, so this looks like it cannot
  matter — and under `x64sc` it does not.  Under `x64` booting with RSEL clear produces a **25-row display window**:
  four extra raster lines top and bottom, showing the FLD band above and one row too much map below, which reads as
  the bottom border wobbling as the AGSP shifts.  DEN makes no difference, so it stays clear and the copy stays
  hidden.  Booting from disk this never showed, because the KERNAL had already put `$1b` here.
- **The whole VIC register file must be initialised, `VIC_CONTROL_X` above all.**
  The engine writes `$d016` exactly once
  per frame from the raster IRQ (`raster.acme:96` is the only write in the tree) and never touches the registers it does
  not use.
  Leave `$d016` at its power-up value and the right-hand border stops closing from the VSP down — the display runs to
  the 40-column edge while the left side stays at 38.
  Booting from disk this never showed, because the KERNAL had already written `$c8`.

The general rule: anything the engine does not write every frame, the stub must put in a known state, because power-up
VIC contents are undefined on real hardware.
Note `x64` and `x64sc` disagree here — `x64sc` rendered the broken `$d016` case correctly, so **verify cartridge changes
under `x64` too**, it is the more revealing of the two for this engine.

`mkcart.py` mirrors the same layout from the other side and pads unused flash with `$ff`.
Its `petscii()` reproduces the `EF-Name:` magic from section 6 as a plain case swap rather than a hardcoded byte blob.

### Tunables — top of `engine.acme`

`SCROLL_SPEED` (1 or 2), `SPRITES` (0, or ≥4), `TILE_COLS`/`TILE_ROWS`, `SPRITES_TOP_Y`/`SPRITES_MAX_Y`, `TILES`,
`COPY_*_FRAMES`.
These feed `!if`/`!for` conditionals throughout `raster.acme` and `tiles.acme` that generate structurally different code
— e.g. `SPRITES = 0` inlines `inc_vic_control_y` as a macro, otherwise it becomes a `jsr`-able routine with different
cycle budgets.

## Conventions

- `lib/std.acme` provides the vocabulary: long branches (`+jeq`, `+jcc`, …), unsigned/signed comparison branches
  (`+bugt`, `+bsle`, …), `+set`/`+set16`/`+copy`, `+wait*`, `+create_basic_starter`, and page-boundary-checking
  skip-branches (`+bcc`, `+bne`, … with no argument) that `!warn` when a branch crosses a page.
- `!cpu 6510` — illegal opcodes are fair game.
- Every routine is wrapped in `!zone { }` so `.local` labels can repeat; `+`/`-` are ACME's anonymous forward/backward
  labels.
- `lib/vic.acme` and `lib/cia.acme` are register/constant definitions with the relevant bit-field documentation in
  comments — prefer the named constants over raw `$d0xx`.

## Testing

```bash
make regress                              # -> regress/, fails on any jam
cp -r regress regress-before              # capture a baseline before a refactor
make regress REGRESS_REF=regress-before   # ... and diff rendering against it
```

`tools/regress.sh` builds `engine.acme` with `-DAUTOPILOT=1 -DAP_FRAMES=n` at eight stop frames, runs each headless
with `-jamaction 5` so a `jam` quits the emulator, and reports failures.
`AP_TABLE` in `joystick.acme` is the scripted stick: each direction alone, both diagonals, and three direction-reversal
patterns — reversals matter because they re-seed the copy counter and jump the cursor to the opposite edge while a copy
is still in flight.

**The autopilot freezes `JOYSTICK` completely once it has replayed `AP_FRAMES` frames** — no scroll, no colour cycling.
That is not cosmetic: with the engine still animating, the exit screenshot depends on which cycle the emulator happens
to be stopped on and the same binary produces different images run to run.  Don't remove the freeze.

Two things this has already established, so don't re-derive them: rapid direction reversal and diagonal scrolling are
clean at both `SCROLL_SPEED` values, and the copies overrunning their nominal frame budget on a diagonal (they
serialise — `COPY_TILES` finishes `C_COPY` before touching `R_COPY`) is absorbed by the spare rows/columns
`SCROLL_ROWS = SCR_ROWS-2` leaves.

### Measuring the off-screen budget

`make regress` only tells you whether the budget was blown.  To measure how much is left, temporarily parameterise the
`-DDEVELOP` overrun check's `cmp #LINE_0-1`, force a constant stick direction (`sed` the `lda CIA1_PORT_2` in
`joystick.acme` to `lda #$f5` for down+right), and bisect the threshold over a long run: the lowest value that does
*not* jam is the raster line `last_irq` finishes on.  `LINE_0-1 = 47` is the limit.

Do this over **thousands** of frames with a constant direction, not over the autopilot — the worst case is rare.
Measuring the diagonal phase of one `AP_TABLE` pass reported line 18 for a build whose true worst case was 36.
Reference points, all diagonal:

| build | frame ends on |
|---|---|
| before world-fixed sprites | < line 6 |
| sprites, wrap left to the sort | line 36 |
| sprites, wrap fixing `SPR_I` itself | line 20 |
| 16 world + 8 panel, scheduled | line 12 |

Beware a **spurious jam**: one sweep of this reported line 40 for a build whose real worst case is 12, and a rerun of
the identical tree gave 10.  Confirm any surprising reading with a repeat before acting on it.

The same technique works for any other invariant that should hold every frame — stash the value in a spare zero-page
byte inside the cycle-exact code (there is documented slack before the soft-scroll wait), then compare and `jam` in
`last_irq` where timing is free.  That is how the AGSP end line, the soft-scroll wait target, RSEL and `SPR_I`'s
permutation invariant were all checked.

### What headless screenshots cannot tell you

`-exitscreenshot` stops the emulator at a cycle count, not at a frame boundary, and the capture is **not reproducible
at frame granularity** — the same binary at the same `-limitcycles` has been observed to produce a 24-row and a 25-row
window on different runs.  Roughly one capture in 30 shows a display area 4 lines taller at each end.  This happens on
old commits too, at the same rate.  It is a capture artifact; do not go hunting for it in the engine.

That is why the autopilot freezes the screen before the screenshot is taken, and why anything frame-by-frame has to be
measured from inside the program with a `jam`, not from images.

**Test the cartridge under `x64`, not just the `.prg` under `x64sc`.**  The cartridge payload is byte-identical to the
`.prg`, so anything that reproduces on one and not the other is boot state, not engine code — that is exactly how the
`VIC_CONTROL_Y` RSEL bug above was found, after a long detour chasing it in the scroll code.  The four combinations
are cheap to run and disagreeing pairs localise the fault immediately:

```bash
acme -DSYSTEM=64 -DAUTOPILOT=1 -DAP_FRAMES=n -f cbm -o ap.obj engine.acme   # same payload both ways
x64   -warp -sounddev dummy +easyflashcrtwrite -limitcycles 22000000 -exitscreenshot a.png -cartcrt ap.crt
x64sc -warp -sounddev dummy -autostartprgmode 1 -limitcycles 22000000 -exitscreenshot b.png -autostart ap.prg
```

## Debugging

`-DDEBUG=1` (i.e. `make dev`) turns on:

- `VIC_BORDER` colour bands marking where `JOYSTICK`, `COPY_TILES`, sprite sorting, and multiplexing run — this is how
  you see the raster budget.
- Text/40-col-ish VIC control values instead of multicolor bitmap mode.
- `!warn` output for the code/frame end addresses and wasted bytes before `IRQ`.

`-DDEVELOP=1` alone adds a raster-overrun check at the end of `last_irq` that executes `jam` if the frame's work spilled
past `LINE_0-1`.
A freeze in VICE's monitor at a `jam` means you blew the cycle budget.

`-DEFDEBUG=1` on `easyflash.acme` paints the border at each boot milestone via `+ef_mark` (white → red → cyan → purple →
green → yellow).
If the engine starts it repaints the border itself, so any leftover marker colour tells you where the boot stalled.
This is the fastest way to bisect a cartridge that won't come up — VICE's `-moncommands` breakpoints proved unreliable
here.

Useful non-interactive runs (VICE writes a screenshot and exits on its own):

```bash
x64sc -warp -sounddev dummy +easyflashcrtwrite -limitcycles 12000000 \
      -exitscreenshot /tmp/out.png -cartcrt engine.crt
```

Comparing that against the same run on `engine.prg` (`-autostartprgmode 1 +drive8truedrive -autostart engine.prg`)
isolates cartridge-boot bugs from engine bugs: the two should render the same frame apart from sprite animation phase.
