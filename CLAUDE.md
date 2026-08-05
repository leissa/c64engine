# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Commodore 64 game engine written entirely in 6510 assembly for the **ACME** cross-assembler.
It scrolls a full multicolor bitmap in all 8 directions using AGSP (FLD + line crunch + VSP), multiplexes 16 world
sprites (two hardware sprites each, over 4 pairs) plus an 8-sprite panel row, streams tiles from a Zelda-style
32×32-tile area, and plays music — all inside one cycle-exact raster interrupt chain.
It ships as a 1 MiB EasyFlash cartridge.

There is no linter and no unit-test framework.
The one automated check is `make regress` (see _Testing_), which replays a scripted joystick pattern in a headless VICE
and fails on a blown raster budget or, against a saved reference, on any rendering change.

## Build

`config.default` is git-ignored and **required**; create it first:

```bash
cp config.default.template config.default   # then edit tool paths
make                                        # -> engine.crt
make run                                    # x64 +easyflashcrtwrite -cartcrt engine.crt
make dev                                    # -> engine-dev.crt, with the debug switches
make run-dev                                # ... and run it
make clean                                  # crt/obj/efboot/labels
make distclean                              # also removes the fetched ./eapi
```

The first `make` fetches the EAPI sources into `./eapi` (git-ignored) and assembles them with the same `acme`;
after that the build needs no network.
Use `make Q=` to echo every command and to pass `-v` to `mkcart.py`.

`make dev` is the fast iteration path.
It assembles with `DEV_FLAGS` — `-DDEVELOP=1 -DDEBUG=1` by default — and packs the result with the same `mkcart.py` and
boot stub as the release build, into its own `engine-dev.crt`; `make run-dev` runs it.
Going through the cartridge path means the thing you debug boots the way the shipped one does, which is worth having
given how many of the bugs below turned out to be boot state rather than engine code.
Override the switches to get one without the other, e.g. `make dev DEV_FLAGS=-DDEVELOP=1` for the raster overrun check
without the debug display.
The target is deliberately phony and rebuilds unconditionally, because make cannot see `DEV_FLAGS` change between runs.

**There is no `make prg`, and `engine.acme` has no `!to`.**
The engine object already _is_ a `.prg`: `+create_basic_starter` is unconditional, so a `-f cbm` build starts at `$0801`
with a BASIC starter, and VICE autostarts `engine.obj` as it stands — verified, it comes up with the engine's black
border.
So the A/B comparison against the cartridge costs a `cp engine.obj x.prg` rather than a build target.
Dropping the `!to` also removes the "Output file name already chosen" warning that every `-DDEVELOP` build with `-o`
used to print, including each of `make regress`'s eight.

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
The area's four files — `map.bin` plus the `colors.bin`/`screen.bin`/`pixels.bin` tileset — are authored assets with no
generator behind them, so there is nothing to run before a build; see _The map is one area_.

Everything about the layout follows the [EasyFlash Programmer's
Guide](http://skoe.de/easyflash/files/devdocs/EasyFlash-ProgRef.pdf);
the code cites section numbers.
Bank 0's ROMH chip holds EAPI at `$1800`, the `EF-Name:` menu entry at `$1b00` and the boot stub at `$1c00`;
banks 1-4 hold the payload.
`Makefile`'s `CART_SKIP` names the address ranges left out of the cartridge because `init_screen` builds them at
runtime, and must stay in sync with `lib/mem.acme`.

## Architecture

### Memory map — `lib/mem.acme`

This file is the single source of truth for the _entire_ address space: zero-page variable allocation, code/data segment
bases, and VIC bank layout.
Read it before touching anything that allocates memory.
Highlights:

- The engine runs with `ALL_RAM_WITH_IO` (`$01 = %00110101`) — no BASIC, no KERNAL.
  Startup points NMI/IRQ vectors at `EMPTY_INTERRUPT`, kills CIA timer IRQs, and never acks NMI again, so the whole zero
  page except `$00`/`$01` is free.
- VIC uses bank 3 (`$c000-$ffff`): bitmap at `$c000`, screen at `$e000`, sprite frames at `$e400`.
  Sprite pointers live at `SPRITE_PTR = SCREEN+$0400-8`.
- The area's tileset is `TILE_COLOR`/`TILE_SCREEN` (768 bytes each) and `TILE_PIXELS` (`$9600-$adff`, 6k), each base a multiple of `TILES` — see _Tile copying_ for why that alignment is worth raster lines.
  `$ae00-$bfff` is free and so is `$3400-$8fff`, so RAM is not the constraint here; the code segment's ~1k against `SONG_DATA` is.
  The 4k of RAM under the I/O area is part of the bitmap, so `tiles.acme` toggles `RAM_ROM_SELECTION` to `ALL_RAM` around pixel writes.
- `$0200-$07ff` belongs to the cartridge boot: `EF_COPIER` (the relocated copier), `EF_TBL_RAM` (the chunk table,
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
3. **FLD + line crunch** — `HARD_Y` iterations of `increment_vic_ctrl_y`, always totalling 25 raster lines.
   Sprites in the crunch area take a shorter 44-cycle path.
4. **VSP** — the self-modified nop field lands the badline on the right cycle.
   Guarded by `!if (>IRQ) != (>*) { !error }`:
   the critical code must not cross a page, which is why `IRQ` is `!align 255, 0`.
5. **Soft scroll**, then **sprite multiplexing** — see _Sprites_ below. The AGSP region is always 25 raster lines and
   **ends on line `AGSP_END` = 75** — measured, see _Measuring the AGSP band_ under _Testing_; it does not move with
   `HARD_Y`. The soft scroll is released at `SPRITE_MULTIPLEX_START` = `FIRST_BADLINE+SCREEN_ROWS+8+1` = 82, a **full
   text row past the band**, and that row of apparent slack is load-bearing: the release writes YSCROLL, and a write
   landing inside the row still being fetched can assert the bad line condition a second time in that row, so it is
   re-fetched from a shifted `VC` and the map's first 0-7 lines come out corrupt. Tried releasing at 76 to win six lines
   of sprite travel; it shows as a ragged partial row under the panel. It is scroll-offset dependent, so **a full-screen
   screenshot at one scroll position does not clear a change here** — crop the strip under the panel and compare it
   across several autopilot stops.
6. **`last_irq`** — the "off-screen" budget: `JOYSTICK`, `COPY_TILES`, `PLAY_SONG`, the panel row, an insertion-sort
   pass over `SPRITE_ORDER` by `SPRITE_Y`, and the sprite scheduling for the next frame.

`HARD_X`/`HARD_Y`/`SOFT_X`/`SOFT_Y` are not variables but `*+1` labels pointing at immediate operands inside the IRQ —
self-modifying code is the norm here, not an exception.

### Scrolling — `scroll.acme`

All four of `SCROLL_U`/`SCROLL_D`/`SCROLL_L`/`SCROLL_R` are generated from one
`+scroll_axis .vertical, .direction` macro; they differ only in which axis they walk and in the sign of every step.
They advance `SOFT_*` by `SCROLL_SPEED` and, on wrap, `HARD_*`.
`INCREMENT_HARD_Y`/`DECREMENT_HARD_Y` handle the AGSP coupling where a Y wrap shifts `HARD_X` by 16.
At the halfway point of a soft scroll they seed `COL_COPY`/`ROW_COPY` and step the
`{COL,ROW}_{MAP,SCREEN,PIXEL,COLOR}_POS_*` pointer sets,
which are the source (map) and destination (screen/bitmap/color) cursors for tile copying.

**The horizontal axis runs backwards.** `SOFT_X` and `HARD_X` step _against_ the map cursor, so `SCROLL_L`
(`.direction = -1`) increments both — the VSP delay in `raster.acme` is `39-HARD_X`, which is where the inversion comes
from. The macro carries `.soft_direction` (`= .direction` vertically, `= -.direction` horizontally) for exactly this:
anything reading or stepping `SOFT_*`/`HARD_X` keys off `.soft_direction`, everything else off `.direction`. Getting
that wrong swaps the copy trigger between the two horizontal directions and is invisible in a screenshot.

`SCROLL_SPRITES_U`/`_D`/`_L`/`_R` keep the sprites pinned to the map: `SPRITE_X`/`SPRITE_Y` are screen
coordinates, so a camera step has to move every sprite the other way. **All `SPRITES` world sprites scroll, with no
exclusions** — the panel row is a disjoint set that `last_irq` writes straight into the hardware, so nothing here has to
keep clear of it. What the world sprites must not do is come up past the line the multiplexer can first reach, and that
is what the `SPRITE_WRAP_TOP` bound enforces. `SPRITE_X` is half resolution (`last_irq` does an `asl`), so it only steps
on every second pixel of camera travel.

**Recycling a sprite must reposition it in `SPRITE_ORDER` by hand.** Shifting every sprite by the same amount leaves the
sorted order intact, but a sprite that wraps travels from one end of the Y range to the other and has to travel the
whole length of `SPRITE_ORDER` with it. Left to the insertion sort in `last_irq` that is its O(n²) case, and it cost
**~26 of the 47 raster lines** of off-screen budget for a single wrap — measured, not estimated. So the wrap moves the
entry in `SPRITE_ORDER` directly and the sort then finds nothing to do. `SPRITE_WRAP_MARGIN` exists because the order
read there is the one sorted at the end of the _previous_ frame, so a wrap can be noticed a frame or two late.

`SPRITE_WRAP_MARGIN` is what sets the top edge: a sprite is recycled at `SPRITE_MULTIPLEX_START + SPRITE_WRAP_MARGIN`,
so the margin is exactly the band below the panel row where a sprite is gone instead of sliding out of view. It was 4 on
the theory that the four slots fill in sequence and the last one needs room; that turns out not to be the binding
constraint (see the sprite-placement measurement under _Testing_), and it is now `3 * SCROLL_SPEED`. What stops it going
lower is the off-screen budget, not placement: at 2 the frozen autopilot frames at stops 60 and 90 sit right on the
limit — they jam with the `SPRITE_DROPPED` tracking compiled in and pass without it. One raster line is not worth being
unable to instrument the frame, so 3 it is. So `SPRITE_WRAP_TOP` is `SPRITE_MULTIPLEX_START + 3*SCROLL_SPEED` — 85 at
speed 1, 88 at speed 2. It is a pop,
not a slide, and it stays one: the sprite is 21 rows tall, so its body covers the top of the map whatever its top row is
doing. Hiding it needs the mask below, and lowering it further needs `SPRITE_MULTIPLEX_START` to move, which it cannot —
see stage 5 of the IRQ chain.

The tunable constraints that used to be comments are now `!error` assertions at the top of the file:
`(SCROLL_ROWS-1) % TILE_ROWS` and `(SCROLL_COLS-1) % TILE_COLS` must be zero, because the direction-reversal cursor
jump is expressed in tiles and ACME's division truncates.

### The map is one area — and the camera

**The map is a single Zelda-style area of `AREA_COLS`×`AREA_ROWS` = 32×32 tiles**, which at 24×16 pixels a tile is about
2.4 by 2.6 screens.
That is the whole world model: there is no larger address space the area sits inside, and no world dimension other than
`AREA_COLS`/`AREA_ROWS`.
Several areas, and moving between them, is a later problem — nothing in the tree knows about more than this one.

`map.bin` **is** the map: `AREA_COLS*AREA_ROWS` = 1024 bytes at `TILE_MAP`, row major with an `AREA_COLS` byte
stride, so a tile index lives at `TILE_MAP + row*AREA_COLS + col`.
`engine.acme` asserts the file's size against `AREA_COLS*AREA_ROWS`, because a map of the wrong shape assembles happily
and then scrolls garbage.
It also asserts that the map is a power-of-two number of whole pages, which is what lets `wrap_add`/`wrap_sub` confine a
cursor to it with a single `and` — see below.

Two consequences worth having in mind before touching the copy or scroll code:

- **The map cursor is a plain 16-bit offset**, not a (row, column) byte pair. `COL_MAP_POS_LO`/`_HI` and
  `ROW_MAP_POS_LO`/`_HI` hold `row*AREA_COLS + col`, and `init_ptrs` adds `TILE_MAP` to produce the absolute address the
  copy loop self-modifies into `.map_loop`. Because `TILE_MAP` is page-aligned and the offset is under 1024, that add is
  still just `adc #>TILE_MAP` on the high byte.
- **A tile step is not an `inc`.** Along the map that is ±1 with a carry, down it is ±`AREA_COLS` with a carry.
  `scroll.acme` does it with `wrap_add`/`wrap_sub` and a `MAP_PAGES` mask, so a cursor physically cannot address outside
  the map; `tiles.acme`'s `+step_map_ptr` does it unmasked inside a single copy, which is safe because the camera clamp
  below bounds how far a copy can walk. Verified: instrument `MAP_POS_HI_TMP` against `TILE_MAP .. TILE_MAP+MAP_PAGES`
  in the copy epilogue and it never fires, over the autopilot and over ~9000 frames of constant down+right and up+left.

**An area _is_ four files**: `map.bin` plus the tileset it indexes into — `colors.bin`, `screen.bin`, `pixels.bin`.
They are authored assets, checked in, with no generator behind them and no other representation anywhere:
what is in the repo is what the engine loads.
There is exactly one area, the demo one, and it uses 95 of the `TILES` = 128 slots.

The `.bin` files were originally cut out of a larger world atlas by a throwaway script, and both are gone: keeping a
one-shot authoring artifact in the tree made it read like a live pipeline, which is worse than not having it.
If a second area ever needs cutting, `git log -- map-world.bin tools/mkarea.py` has the atlas and the script.

**The tileset is per area, not global.** That is what lets `TILES` be 128: an area only references its own tiles, so
their indices are dense `0..n-1` and each plane is `TILES` bytes wide regardless of how many are actually drawn.
A megabyte of flash makes a tileset per area free, and areas that share a look can share one.
One thing follows: **a map index means nothing outside its own area**, so nothing may compare an index in one area's
`map.bin` against another's.

**The camera is real state**: `CAMERA_X_*`/`CAMERA_Y_*` in `lib/mem.acme`, 16-bit, in pixels into the map. It only
exists to clamp the scroll — `JOYSTICK` guards each of its four `SCROLL_*` calls with `+scroll_towards_max` /
`+scroll_towards_zero`, which skip the scroll at the bound and otherwise step the camera by `SCROLL_SPEED`.

**The clamp is now the only thing keeping reads inside the map**, since there is nothing outside it — walk past the edge
and you read whatever follows `TILE_MAP`. It is exact rather than approximate, which is why that works: at
`CAMERA_X_MAX` the window covers chars 53-92 of the map's 96, and `COPY_TILES`' one-tile read-ahead reaches char 95, the
map's last. The vertical bound lands on the last row the same way. Four things about it that are not obvious:

- **`init_screen` deliberately bypasses it**, calling `SCROLL_L` directly. The startup fill scrolls a whole
  screen width and must not be clamped; `CAMERA_*_INIT` is then written after the fill to match where it left the
  camera.
- **The bounds deduct a whole tile** beyond the screen size, because `COPY_TILES` works one tile ahead of the window.
  Without that the trailing edge shows the tile past the map — a sliver a few pixels wide at the very edge of the
  screen, easy to miss.
- **`CAMERA_*_INIT` is measured, not derived**, and `MAP_INIT_COL`/`MAP_INIT_ROW` do not give it to you: the
  sub-tile offsets `TILE_COL`/`TILE_ROW` come into it too. To re-check a bound, replace `map.bin` with a uniform one,
  force one stick direction the way _Measuring the off-screen budget_ describes, run to the bound and screenshot.
  Tile 1 is solid (all `%11`), which makes any intruding tile obvious:

  ```bash
  python3 -c "open('map.bin','wb').write(bytes([1])*1024)"   # and git checkout map.bin afterwards
  ```

  Anything other than the fill tile means the bound is too generous and the read-ahead left the map; an early stop means
  it is too tight. All four directions, since the horizontal and vertical read-ahead differ.
- **`MAP_INIT_*` is what the camera is calibrated against.** Moving the initial cursor invalidates `CAMERA_*_INIT`, so
  re-measure both together.

### Sprites

Two disjoint sets share the eight hardware sprites, and the split is what keeps the crunch band's timing honest.

`PANEL_SPRITES` (8) all share one Y — `PANEL_Y` = `SPRITES_TOP_Y` = **54** — one hardware sprite each, single colour,
meant for hitpoints, weapons, text. `last_irq` writes them straight out and they take no part in the sort or the
multiplexer. **Sharing one Y is mandatory**: the
44-cycle crunch path is `63-19`, i.e. all eight sprites DMA-active across the whole band, so staggering them would need
the FLD/crunch loop to carry a per-line cycle count.
`PANEL_Y` is a compile-time constant rather than a table byte, which is what makes staggering them impossible rather
than merely wrong — and saves the `lda` a cycle, since an immediate is 2 and an absolute load 4.
**The X positions are a compile-time list, not a table.** `+panel_x_row` in `engine.acme` names one 9-bit X per sprite
and the assembler splits each into the `$d000+2i` immediate and its bit of the `$d010` msb byte — the same
asl-and-take-the-carry split the multiplexer does for `SPRITE_X`, except `SPRITE_X` moves every frame and the panel does
not, so there is no reason to pay for the shift eight times a frame. Doing it at runtime instead would cost **+48
cycles**, because accumulating the carries needs a `rol` into a zero-page byte per sprite. It also removes the second
table: nothing can now disagree with `PANEL_X_MSB`, and a position outside 9 bits is an `!error`.

`PANEL_FRAME` is the only panel table in zero page, because it is the only one that is live content — the icon or glyph
each slot shows — so `last_irq` has to read all eight every frame; `panel_frame_init` seeds it the way `sprite_y_init`
seeds `SPRITE_Y`.

The whole panel block is **214 cycles**, 3.4 raster lines of the off-screen budget, so it is the biggest single item
there after `COPY_TILES`. It was 242 before `PANEL_Y` became an immediate (−2), `PANEL_FRAME` moved to zero page (−8) and
the X list stopped being a table (−18). `PANEL_COLOR` is the only one left; folding it in the same way is worth ~16 more
once the panel's two configurations are fixed.

**The panel fills the visible part of the band exactly, and only one Y does that.** A sprite at `y` displays
`y+1 .. y+21`, so:

| derivation                            | value | what breaks one line off it                                            |
| ------------------------------------- | ----- | ---------------------------------------------------------------------- |
| `AGSP_END - SPRITE_HEIGHT`            | 54    | higher: band lines with no sprites that the 44-cycle path times as full |
| `VERTICAL_BORDER_TOP - 1`             | 54    | lower: the top of the panel is eaten by the border                     |

Both give 54 because the band's visible part — `VERTICAL_BORDER_TOP` (55) through `AGSP_END` (75) — is 21 lines and a
sprite is 21 lines: it fits with no margin either side. `engine.acme` asserts the equality, guarded on RSEL, because the
alignment is the intent and would drift silently otherwise; the debug build runs RSEL set, opens the border four lines
earlier and lines up with nothing.

The panel used to sit at 60, where its bottom six rows hung over the first lines of the map. Moving it up costs no
world-sprite travel: `SPRITE_FLOOR` = `SPRITES_TOP_Y + SPRITE_HEIGHT + 1` is where the panel gives the hardware back, and
at 54 that is **76** — but the multiplexer cannot start before `SPRITE_MULTIPLEX_START` = 82 whatever the panel does, and
that line cannot move (stage 5 of the IRQ chain). So lines 76-81 show map with no sprites on them either way.
Verified: moving the panel changes nothing below the band, pixel for pixel — the removed sprite steal on 76-81 does not
reach the VSP or the soft-scroll release, which polls for a fixed line rather than counting cycles.

The assertion `SPRITE_FLOOR > AGSP_END` is the one that guards correctness rather than screen area: a world sprite
going DMA-active _inside_ the band would make the per-line steal vary and mistime the whole AGSP.

`SPRITES` (16) are the world sprites below that, two hardware sprites each — a hires overlay over a multicolour one —
multiplexed over `SPRITE_SLOTS` (4) pairs. `VIC_SPRITE_MULTICOLOR` is flipped between the two: `last_irq` clears it for
the panel row, the multiplexer sets `%10101010` when it takes over (safe, because the panel row ends at `AGSP_END`, well
above the soft-scroll release line).

Which half of a pair is which follows from that `%10101010` and from sprite priority, and it is what the otherwise
opaque `SPRITE_COLOR_A`/`SPRITE_COLOR_B` naming rests on. Pair _r_ owns hardware sprites `2r` and `2r+1`:

|       | hardware sprite | mode        | frame              | colour                       |
| ----- | --------------- | ----------- | ------------------ | ---------------------------- |
| back  | `2r+1` (odd)    | multicolour | `SPRITE_FRAME`     | `SPRITE_COLOR_A` → its `%10` |
| front | `2r` (even)     | hires       | `SPRITE_FRAME + 1` | `SPRITE_COLOR_B`             |

The even sprite is in front because lower sprite numbers win priority, so the hires half overlays the multicolour one.
The multicolour `%01` and `%11` colours are not per sprite — they are `VIC_SPRITE_MULTICOLOR_01`/`_11`, written once at
startup (brown and grey).

**Scheduling is decided in `last_irq`, before the frame is drawn.** A slot is busy for `SPRITE_HEIGHT` lines, so
sprite _n_ of the display list can only use slot `n % SPRITE_SLOTS` if it is that far below sprite `n-SPRITE_SLOTS`.
The old code discovered this the hard way and dropped whatever it could not place — sprites blinking out at random
whenever they clustered in Y. Now the list is thinned until it fits:

| zones | shown per frame      | each sprite appears |
| ----- | -------------------- | ------------------- |
| 4     | all 16               | every frame         |
| 2     | every 2nd in Y order | every 2nd frame     |
| 1     | every 4th in Y order | every 4th frame     |

Thinning **in Y order, not by sprite id**, is the point: it halves the density of a cluster instead of leaving its
members to collide. One zone is always feasible — `SPRITE_SLOTS` sprites over `SPRITE_SLOTS` slots — so the chain
terminates and nothing ever vanishes; it just degrades to a steady, controlled flicker. `SPRITES_SHOWN` is how many
entries of `SPRITE_QUEUE` the multiplexer walks, `SPRITE_PHASE` picks the phase.

Because the phase advances in `last_irq`, a clustered layout would keep the screen changing after the autopilot has
frozen `JOYSTICK`, which would break the reproducibility `make regress` depends on — hence `AUTOPILOT_FROZEN`, which
stops the phase too.

The invariant worth re-checking after any change here is that the multiplexer places _every_ scheduled sprite, i.e.
the `.last_irq` "too late" path is now unreachable. Verified by stashing X at that exit and comparing it against
`SPRITES_SHOWN` in `last_irq`, over Y spacings from 8 down to 0.

The _other_ "too late" exit — the one in `.display_sprite`, which skips a single sprite and carries on — is reachable
by design, and how far down the screen it reaches is what decides the top edge. Measured: nowhere that shows.
See _Measuring sprite placement_ under _Testing_.

### The band can hide sprites — `$d01b` over invalid mode

Not used yet, but established and worth not re-deriving, because it is the mechanism for a genuinely smooth top edge.

A sprite cannot be started mid-image (`Cr(MCBASE)` reaches only non-row-multiple values and needs a cycle-15 write per
line), so partial visibility needs either pre-shifted frame data or a mask. **The band is already a usable mask.**

- `vic-ii.txt` §3.7.3.9: in **idle state** the g-access reads `$3fff`, or **`$39ff` when ECM is set**, and repeats
  that byte across the line. Bank 3 → **`$f9ff`**, currently the unused 64th byte of `SPRITE_FRAMES` block 87.
- §3.7.3.8: in **invalid bitmap mode 2** (`ECM/BMM/MCM = 1/1/1`, which `CTRL_Y_INVALID` + `CTRL_X` already
  select for the band) every bit pair renders black, but `10` and `11` count as **foreground**.
- §3.8.2 spells the trick out: "by setting the sprites to appear behind the foreground graphics, the foreground
  graphics will actually become visible as black pixels overlaying the sprite pixels." Foreground/background is
  decided by **MCM in `$d016` alone**, "independently of ... the BMM and ECM bits", and that "is also valid for the
  graphics generated in idle state."

So `$f9ff = $ff` makes the band black _and_ foreground: any sprite with its `$d01b` bit set is hidden behind it, while
the panel sprites keep theirs clear and stay on top.

Both halves were verified with a standalone test program rather than by surgery on the band (`x64sc` and `x64` agree):
in invalid bitmap mode 2 a `MxDP=1` sprite is masked while a `MxDP=0` control sprite beside it stays fully visible,
and flipping `$d01b` mid-frame cuts a sprite horizontally at exactly the line of the write — so **`MxDP` is sampled
per pixel, not latched per sprite.** Isolating it in ~60 lines of ACME was far cheaper than instrumenting the
cycle-exact loop, and is the right move for any similar "does the VIC really do X" question.

Two caveats before building on it:

- **Crunch lines are not idle.** §3.14.4: a crunched line stays in display state, so there the mask comes from real
  bitmap data and leaks wherever the art has `00`/`01` pairs. The band's bottom `HARD_Y` lines are the crunch ones.
- **Inside a closed border there is no mask at all** — §3.8.2, last paragraph: when the vertical border flag is set
  the graphics sequencer output is turned off entirely. So the mask spans `VERTICAL_BORDER_TOP` down, and opening the
  border _extends_ it upward rather than destroying it.

The remaining blocker for using it is not the mask but the hardware: sprites still cannot be displayed above
`SPRITE_FLOOR`, so the panel would have to move up into the border region, which means opening the vertical border and
teaching the band loop to tolerate a varying number of active sprites.

### Tile copying — `tiles.acme`

Copying a whole column or row of tiles doesn't fit in one frame's raster budget, so it's split across
`COPY_COL_FRAMES`/`COPY_ROW_FRAMES` frames. `COPY_TILES` (called once per frame from `last_irq`) dispatches on the
`COL_COPY`/`ROW_COPY` counters into `copy_col_tiles1/2` and `copy_row_tiles1/2`, which set `ITERATIONS` and fall into
one shared `copy_*_tiles` body. The `copy_tile_charN` routines are macro-generated, one per position within a tile
(`TILE_COLS`×`TILE_ROWS` = 3×2); because they all come from the same macro they are equal-sized, and
`+jsr_copy_tile_char` addresses one arithmetically instead of running a char index down a `cmp`/`bne` chain.

The per-frame loop is **unrolled by the tile cycle and specialised on the fixed coordinate**: along a column copy the
tile row is fixed and the sub-column cycles, along a row copy the reverse. That makes the sub-char a compile-time
constant per slot, and lets the map byte be fetched once per tile rather than once per char. A frame boundary can
fall anywhere in the cycle, so the loop is entered at the slot the previous frame stopped on and each slot has an exit
recording where to resume; the invariant is that the saved map pointer addresses the tile holding the _next_ slot,
which is why the slot-0 exit (meaning "tile finished") steps it on. Slot, exit and variant bodies must stay
equal-sized so they can be reached by `base + n*SIZE` — all three are asserted.

**`TILES` = 128 is a timing constant, not just a capacity.**
`copy_tile_char` reads ten planes with `abs,x` indexed by the tile, and `abs,x` costs an extra cycle when `base_lo + X` crosses a page — so with the old `TILES` = 185 the planes sat at arbitrary offsets and most of those reads paid it.
Every plane base being a multiple of a power-of-two `TILES` ≤ 128 makes the crossing impossible instead of merely unlikely.
Measured, sustained diagonal, `SCROLL_SPEED` 2: the frame ended on raster line **46 before and 44 after**, i.e. two of the three lines of headroom that now exist.
`engine.acme` asserts the alignment per plane, because getting it wrong costs cycles silently in code whose `; N` comments still look right.

Keep an eye on the code segment. It runs `$0885-$1bf5` against `SONG_DATA` at `$2000` — about 1k of headroom — and
unrolling here eats that margin fast: expanding the loop per entry point instead of sharing it cost ~900 bytes. ACME
only _warns_ when the next segment starts inside this one, so an overflow silently gets the tail of the code overwritten
by the song binary and shows up as a dead engine, not a build failure — `engine.acme` now turns that into an `!error`.
`acme -v2` prints every segment's extent, which is the quickest way to re-check the margin.

`init_screen` in `engine.acme` fills the initial screen by calling `SCROLL_L` + `COPY_TILES` in a loop rather
than duplicating the copy logic. It only exercises the _row_ path, which makes it a good first check after touching
`tiles.acme`: if the row copy is broken the screen comes up empty.

### The sprite pointers sit in the screen ring — `RING_PHASE`

Screen memory is a **1024 byte ring** — `tiles.acme` masks a cursor's high byte with `%11111011`, and the VIC's `VC` is
a 10 bit counter — and the VIC reads the sprite pointers from `SCREEN+$3f8`, which is inside it.
So ring offsets **1016-1023 hold the eight sprite pointers instead of screen codes**, and the char cells that map there
take their `%01`/`%10` colours from bytes the multiplexer rewrites every frame.
That is the blinking cells in the map, and the README's "give priority to colour `%11`" note is the art side of the
same problem.

Which cells they are is a free parameter, and the geometry is worth knowing before touching any of it:

- **The mapping is forced, not chosen**: char `(mc, mr)` of the area lives at ring offset
  `(RING_PHASE + mc + SCREEN_COLS*mr) mod 1024`, with `+1` per column and `+40` per row, because the VIC's `VC` counts
  up as it scans. There is no sign freedom to get wrong.
- **The spoiled cells are fixed map cells**, not screen positions — they do not move with the camera, so a given cell
  is spoiled at every camera position that shows it.
- They land in **runs of up to 8 consecutive chars within one map row**, in clusters of two or three adjacent rows, and
  the clusters repeat **every 26 rows**: `26*SCREEN_COLS = 1040 = 1024 + 16`, the same 16 chars `INCREMENT_HARD_Y`
  corrects `HARD_X` by on a Y wrap.
- Only **one cluster fits** in the frame of the area the camera clamp and the AGSP band never show, because the clamp
  hides rows 0-1 and 60-63 and the clusters are 26 rows apart. So **32 cells stay visible whatever the phase** — the
  phase cannot fix this alone, it can only halve it. Getting below 32 needs the art (`%00`/`%11` only) or a real fix
  such as the `$d01b` mask.
- The total number of cells varies with the phase (32-64), because the area's 96 char columns do not tile the ring
  evenly and a run can fall off the row.

`RING_PHASE` is **544**: 32 visible, chosen on geometry alone so it holds for any map, and tie-broken on the current
area's art (23 of the 32 land on chars that use `%01`/`%10`). The plain pairing — screen cursor 0 at `MAP_INIT` — is
phase **741** and leaves **57 of 59** visible, which is what the blinking used to be. `tools/ringphase.py` enumerates
all 1024, with `--art` for the tie-break.

The **exact cells of the configured phase are tabulated in `README.md`** — seven runs of eight, of which rows 61-63 are
the ones nothing can show. `tools/ringphase.py --phase 544 --art` prints that table in the shape the README carries it,
so regenerate rather than hand-edit it.

**Rotating the phase means moving the write cursors and the AGSP origin together.** `RING_INIT`, `PIXEL_INIT`,
`HARD_X_INIT` and `HARD_Y_INIT` all derive from `RING_PHASE` in `engine.acme`, because the display starts at ring offset
`SCREEN_COLS*HARD_Y - HARD_X` while the cursors decide where the tiles are written: change one without the other and the
picture comes up shifted by whole cells, permanently, since both then step in lockstep. The derivation is asserted to
stay in `HARD_X` 0-39 and `HARD_Y` 0-25.

To check a change here, **compare a screenshot against a render of the area** — a spoiled cell mismatches the render,
so the spoiled set can be read off directly; see _Measuring the visible window_. Diffing two frames also finds them, but
only the ones whose pointer byte happened to change between the two.

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
- **`VIC_CTRL_Y` must be left with RSEL set**, the way the KERNAL leaves `$1b`.
  The engine rewrites `$d011` several times per frame and always with RSEL clear, so this looks like it cannot
  matter — and under `x64sc` it does not. Under `x64` booting with RSEL clear produces a **25-row display window**:
  four extra raster lines top and bottom, showing the FLD band above and one row too much map below, which reads as
  the bottom border wobbling as the AGSP shifts. Booting from disk this never showed, because the KERNAL had already
  put `$1b` here.
  DEN stays clear, and `victiming.pdf` says why that reliably hides the copy rather than merely happening to:
  DEN is sampled **only in cycle 1 of raster line `$30`**, and what it sets there — the D-flag — is the condition on
  clearing the vertical border flag at the top of the window.
  Boot with DEN clear and the border never opens for that whole frame, whatever else touches `$d011` later.
- **The whole VIC register file must be initialised, `VIC_CTRL_X` above all.**
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

`SCROLL_SPEED` (1 or 2), `SPRITES`, `PANEL_SPRITES`, `SPRITE_SLOTS`, `TILE_COLS`/`TILE_ROWS`, `SPRITES_MAX_Y`, `TILES`,
`COPY_*_FRAMES`. These feed `!if`/`!for` conditionals throughout `raster.acme` and `tiles.acme` that generate
structurally different code — e.g. `SPRITES = 0` inlines `increment_vic_ctrl_y` as a macro, otherwise it becomes a
`jsr`-able routine with different cycle budgets.

`SPRITES_TOP_Y` is **not** in that list any more: it is `AGSP_END - SPRITE_HEIGHT`, the only value that fills the band's
visible part, and `PANEL_Y` is an alias for it — see _Sprites_.

`RING_PHASE` looks like a free constant and is one, but it is not independent: `RING_INIT`, `PIXEL_INIT` and the
`HARD_X`/`HARD_Y` start values all derive from it and have to stay derived — see _The sprite pointers sit in the screen
ring_.

`TILES` is the least free of the lot despite looking like a pure size:
it is the plane stride of the tile bins, so changing it means re-striding all three of them by hand — the sizes are asserted, so the build stops you rather than the screen.
It also wants to stay a power of two with `TILE_COLOR`/`TILE_SCREEN`/`TILE_PIXELS` aligned to it; see _Tile copying_ for the two raster lines that hangs on.

The sprite three are less free than they look, and the assertions in `engine.acme` say so: `SPRITES` must be **0 or
exactly `4 * SPRITE_SLOTS`** (so 16 today) because the 4/2/1 thinning chain assumes `SPRITE_ZONES_MAX` is 4, and
`PANEL_SPRITES` must be exactly `2 * SPRITE_SLOTS`, i.e. cover all eight hardware sprites. `SPRITES = 4` assembles as
far as the `SPRITE_ZONES_MAX` check and then fails there — that is the assertion doing its job, not a bug.

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

`tools/regress.sh` builds `engine.acme` with `-DAUTOPILOT=1 -DAUTOPILOT_FRAMES=n` at eight stop frames, runs each
headless with `-jamaction 5` so a `jam` quits the emulator, and reports failures. `AUTOPILOT_TBL` in `joystick.acme`
is the scripted stick: each direction alone, both diagonals, and three direction-reversal patterns — reversals matter
because they re-seed the copy counter and jump the cursor to the opposite edge while a copy is still in flight.

**The autopilot freezes `JOYSTICK` completely once it has replayed `AUTOPILOT_FRAMES` frames** — no scroll, no colour
cycling. That is not cosmetic: with the engine still animating, the exit screenshot depends on which cycle the emulator
happens to be stopped on and the same binary produces different images run to run. Don't remove the freeze.

Two things this has already established, so don't re-derive them: rapid direction reversal and diagonal scrolling are
clean at both `SCROLL_SPEED` values, and the copies overrunning their nominal frame budget on a diagonal (they
serialise — `COPY_TILES` finishes `COL_COPY` before touching `ROW_COPY`) is absorbed by the spare rows/columns
`SCROLL_ROWS = SCREEN_ROWS-2` leaves.

### Measuring the off-screen budget

`make regress` only tells you whether the budget was blown. To measure how much is left, temporarily parameterise the
`-DDEVELOP` overrun check's `cmp #LINE_0-1`, force the stick (`sed` the `lda CIA1_DATA_PORT_A` in `joystick.acme`), and
bisect the threshold over a long run: the lowest value that does _not_ jam is the raster line `last_irq` finishes on.
`LINE_0-1 = 47` is the limit.

Do this over **thousands** of frames, not over the autopilot — the worst case is rare. Measuring the diagonal phase of
one `AUTOPILOT_TBL` pass reported line 18 for a build whose true worst case was 36.

Two ways to get a confidently wrong answer here, both learned the hard way:

- **A constant direction no longer works — the camera clamp stops it.**
  `lda #$f5` (down+right) runs into the bound after ~19 tiles and then scrolls nothing at all, so the rest of the run measures a static screen:
  a build whose real answer is 46 read as "finishes before line 5".
  Alternate instead, e.g. `inc $3400` / `lda $3400` / `and #$40` to choose between `#$f5` (down+right) and `#$fa` (up+left) every 64 frames.
  That is a sustained diagonal with a direction reversal thrown in, and it keeps copying forever inside the clamp.
  Give the inserted code named labels rather than ACME's anonymous `+`/`-`, or it captures the surrounding branches.
- **A jam does not suppress the exit screenshot**, so presence of the `.png` is not a pass.
  `tools/regress.sh` greps the run log for `Main CPU: JAM`, and anything bisecting the budget has to do the same.
  Detecting by screenshot makes every threshold "pass", so the bisect bottoms out at whatever floor it was given — which looks exactly like a build with enormous headroom.

**The reading depends on `SCROLL_SPEED`**, and heavily: doubling it halves `COPY_*_FRAMES`, so every copy does twice the
chars per frame. Reference points, all diagonal:

| build                                      | `SCROLL_SPEED` | frame ends on |
| ------------------------------------------ | -------------- | ------------- |
| before world-fixed sprites                 | 1              | < line 6      |
| sprites, wrap left to the sort             | 1              | line 36       |
| sprites, wrap fixing `SPRITE_ORDER` itself | 1              | line 20       |
| 16 world + 8 panel, scheduled              | 1              | line 12       |
| the same build                             | 2              | ~line 40      |
| the map as one flat 32×32 area             | 2              | ~line 43      |
| ... re-measured with the alternating stick  | 2              | line 46       |
| `TILES` 185 → 128, planes page-aligned     | 2              | line 44       |

The last two rows are one build apart and were each confirmed by a repeat pass, so they also calibrate the two workloads against each other:
the alternating stick is the harsher of the two, and the old ~43 reading was optimistic.

So at `SCROLL_SPEED` 2 there are **three raster lines of headroom left**, and the flat-map cursor arithmetic
(`+step_map_ptr`, a 16-bit `+AREA_COLS` per tile instead of an `inc` of a row byte) accounts for roughly three of the
lines that went. Anything else added to `last_irq` at this speed needs measuring, not guessing.

Beware a **spurious jam**: one sweep of this reported line 40 for a build whose real worst case is 12, and a rerun of
the identical tree gave 10. Confirm any surprising reading with a repeat before acting on it — and note the readings can
be *non-monotonic*, which is the giveaway: a sweep that passes at threshold 16 and jams at 20 cannot both be true, since
a higher threshold is strictly more permissive. That happened while measuring the row above; the repeat jammed at 16
too.

The same technique works for any other invariant that should hold every frame — stash the value in a spare zero-page
byte inside the cycle-exact code (there is documented slack before the soft-scroll wait), then compare and `jam` in
`last_irq` where timing is free. That is how the AGSP end line, the soft-scroll wait target, RSEL and `SPRITE_ORDER`'s
permutation invariant were all checked.

### Measuring the AGSP band

`AGSP_MARK` (`lib/mem.acme`) plus `-DAGSP_LIMIT=n` bisects the raster line the AGSP region ends on. The stash sits in
the slack between the VSP and the soft-scroll wait — free, because that wait polls for a fixed line — and `last_irq`
jams once the stashed line reaches the limit.

```bash
acme -DSYSTEM=64 -DDEVELOP=1 -DAGSP_LIMIT=76 -f cbm -o ap.prg engine.acme
```

The answer is **75**, constant over a long vertical-scrolling run, as "always 25 raster lines" requires. It is now a
literal dependency rather than a documented one — `SPRITES_TOP_Y` is `AGSP_END - SPRITE_HEIGHT`, so the panel row, and
with it `PANEL_Y` and `SPRITE_FLOOR`, moves if this number does. Re-measure with the recipe above if the band's line
count ever changes.

### Measuring sprite placement

`SPRITE_DROPPED` (`lib/mem.acme`) plus `-DSPRITE_DROP_LIMIT=n` is the same bisect applied to the multiplexer's
`.display_sprite` "too late" exit, which skips one sprite and continues.
The skip path keeps the largest Y it ever skipped;
`last_irq` jams once that reaches `SPRITE_DROP_LIMIT`, so the lowest limit that does _not_ jam is the largest Y ever
skipped, plus one.

```bash
acme -DSYSTEM=64 -DDEVELOP=1 -DAUTOPILOT=1 -DAUTOPILOT_FRAMES=240 -DSPRITE_DROP_LIMIT=43 -f cbm -o ap.prg engine.acme
```

The answer, over the whole autopilot and over 5000 frames of constant down+right, is **42** — thirteen lines above
the first visible line, and forty above the top of the map.
Unchanged from `SPRITE_WRAP_MARGIN` 4 down to 2.
So the multiplexer places every sprite that could be seen, and the top edge is set by the wrap threshold alone;
`SPRITE_WRAP_MARGIN` is the knob, not the placement code.

It is opt-in rather than part of `-DDEVELOP` for a reason worth remembering:
the tracking costs a handful of cycles on a path the budget has no room for, and compiling it in is by itself enough
to push `SPRITE_WRAP_MARGIN = 2` from passing to jamming.
Which is also the warning — **this harness perturbs what it measures.**
Confirm any budget-adjacent result with the tracking compiled out.

### Measuring the visible window

`RING_PHASE`'s whole value comes from the frame of the area that can never be shown, so those bounds are measured rather
than derived from `SCREEN_ROWS` and the border constants.
The result, in chars relative to the camera:

| visible          | from            | to               |
| ---------------- | --------------- | ---------------- |
| rows             | camera + 2.125  | camera + 22.625  |
| columns          | camera + 2.875  | camera + 40.75   |

The AGSP band eats the first 25 raster lines of the display window and pushes the last rows of screen matrix past the
bottom border, which is where the missing 4.4 rows go; 38 column mode accounts for the sides.
With the clamp at 53 columns and 37 rows that makes **map rows 0-1 and 60-63, and columns 0-1 and 94-95, permanently
invisible** — six rows and four columns of the area that nothing can ever show.

The recipe, which works for any question of the form "what is actually on screen":

1. Force a stick direction (`sed` the `lda CIA1_DATA_PORT_A` in `joystick.acme`) and run until the camera **parks at a
   clamp**. The position is then exact and frame timing stops mattering, which is what makes this reproducible where
   `-exitscreenshot` normally is not.
2. Render the whole area from `map.bin` plus the tileset, quantise both images to palette indices, and slide the render
   over the screenshot. The correct alignment scores **1.0** — anything less means the model of the data is wrong, not
   that the alignment is approximate.
3. Read the visible extent off the per-row and per-column agreement profile.

Three traps, each of which produced a wrong answer first:

- **The black band matches any dark part of the render.** A row inside the band scores high wherever the map happens to
  be mostly `%00`, which reported the visible area as starting five rows above the camera. Require the render row to be
  less than ~60% black before believing a match.
- **The art repeats, so a small patch matches in several places.** A 100x18 patch had five perfect matches, one of them
  nonsense that looked plausible. Use a patch of 50+ rows and check whether the best score is a tie.
- **`CAMERA_X_INIT` is not pixel exact** — the true initial view sits 2 px off it. That is sub-char and well inside the
  one-tile clamp margin, but it will make a cell-by-cell comparison against a render fail everywhere if the alignment is
  assumed from the camera rather than measured.

### What headless screenshots cannot tell you

**A whole-image mismatch usually means VICE had not finished autostarting.** `make regress` gives the `.prg` a fixed
`-limitcycles` to load and run under true drive emulation, and that occasionally is not enough: the capture then shows
the light blue BASIC border instead of the engine's black one, every row differs, and it reads like a total rendering
change. Seen three stops out of eight fail this way on a tree whose next two runs were both 8/8. Check a failing
capture's border colour before believing it — `7385ff` in the border means the engine never started. Re-run first; only
a *stable* mismatch across runs is a real one.

`-exitscreenshot` stops the emulator at a cycle count, not at a frame boundary, and the capture is **not reproducible
at frame granularity** — the same binary at the same `-limitcycles` has been observed to produce a 24-row and a 25-row
window on different runs. Roughly one capture in 30 shows a display area 4 lines taller at each end. This happens on
old commits too, at the same rate. It is a capture artifact; do not go hunting for it in the engine.

That is why the autopilot freezes the screen before the screenshot is taken, and why anything frame-by-frame has to be
measured from inside the program with a `jam`, not from images.

**Test the cartridge under `x64`, not just the `.prg` under `x64sc`.** The cartridge payload is byte-identical to the
`.prg`, so anything that reproduces on one and not the other is boot state, not engine code — that is exactly how the
`VIC_CTRL_Y` RSEL bug above was found, after a long detour chasing it in the scroll code. The four combinations
are cheap to run and disagreeing pairs localise the fault immediately:

```bash
acme -DSYSTEM=64 -DAUTOPILOT=1 -DAUTOPILOT_FRAMES=n -f cbm -o ap.prg engine.acme  # the object is the .prg
tools/mkcart.py --engine ap.prg --boot efboot.bin --eapi eapi/eapi-am29f040-14 \
                --name c64engine --skip 0xc000:0xe400 -o ap.crt                   # same payload, boxed
x64   -warp -sounddev dummy +easyflashcrtwrite -limitcycles 22000000 -exitscreenshot a.png -cartcrt ap.crt
x64sc -warp -sounddev dummy -autostartprgmode 1 -limitcycles 22000000 -exitscreenshot b.png -autostart ap.prg
```

## Debugging

`-DDEBUG=1` (part of `make dev`'s default `DEV_FLAGS`) turns on:

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

Comparing that against the same run on the bare payload (`cp engine.obj x.prg`, then `-autostartprgmode 1
+drive8truedrive -autostart x.prg`) isolates cartridge-boot bugs from engine bugs: the two should render the same frame
apart from sprite animation phase.

## The assembler's own manual — `/usr/share/doc/acme/`

Plain text, installed with the `acme` package, and release 0.97 ("Zem", 11 Jul 2025) — the same release as the
installed binary, so it describes the assembler that actually builds this tree.
`QuickRef.txt` is the entry point and `Help.txt` indexes the rest;
`Help.txt` also advertises a `cputypes/` directory, which this package does not ship.

| file                                                | content                                                                                                     |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `QuickRef.txt`                                      | syntax, the four kinds of symbol, the complete CLI switch list, and the operator/precedence table           |
| `AllPOs.txt`                                        | every pseudo opcode with call syntax, aliases and examples — grep this before writing any new `!` directive |
| `AddrModes.txt`                                     | how ACME picks zp vs absolute, and the two ways to override it                                              |
| `Illegals.txt`                                      | the illegal opcodes `!cpu 6510` unlocks, with opcode bytes, semantics and which ones are unstable           |
| `Errors.txt`                                        | every warning and error message spelled out — look the message up here instead of guessing                  |
| `Floats.txt`                                        | when arithmetic goes floating point and when it stays integer                                               |
| `Upgrade.txt`, `Changes.txt`                        | behaviour changes between releases and which `--dialect` restores the old one                               |
| `Lib.txt`                                           | the `<...>` include library and how its path is resolved                                                    |
| `65816.txt`, `Example.txt`, `Source.txt`, `joe.txt` | irrelevant here: other CPU, shipped samples, building ACME, JOE syntax file                                 |

What in there actually bears on this engine:

- **An oversized addressing mode is a stolen cycle.**
  If ACME cannot resolve a symbol in the first pass it assumes 16-bit addressing;
  when a later pass finds the value fits in a byte it only _warns_ ("Using oversized addressing mode").
  In `raster.acme` that silently turns a 3-cycle `lda zp` into a 4-cycle `lda abs` and invalidates the `; N` comments
  around it, so never dismiss that warning.
  It is avoided by defining zero-page symbols before use, which is what `!source "lib/mem.acme"` first in
  `engine.acme` achieves.
  To force the mode, postfix the mnemonic — `lda+1` is 8-bit, `lda+2` 16-bit;
  leading zeros in a symbol's value (`$00fa`) do the same, and `<`/`>` force their result to 8 bits.
  Forcing the _larger_ mode on purpose is legitimate here: it buys a cycle without spending a byte on a `nop`.
- **Segment overlap is only a warning** — `Errors.txt`, "Segment reached another one, overwriting it" and "Segment
  starts inside another one, overwriting it".
  That is exactly the silent failure the code-segment-vs-`SONG_DATA` `!error` in `engine.acme` was written to catch.
  `--strict-segments` promotes both to errors globally;
  `engine.acme` and `easyflash.acme` both assemble cleanly with it today, so it is available if that hand-written
  check ever needs replacing.
- **`!align 255, 0` pads with `$ea`**, not with zero — the default fill is the NOP opcode (verified).
  That is what the padding before `IRQ` in `raster.acme` and before the table in `joystick.acme` is made of, and what
  `-DDEBUG` counts as wasted bytes.
- **`/` truncates because it is integer division**, unless one operand is a float (`Floats.txt`: `1/2*2` is 0,
  `1.0/2*2` is 1; `DIV` is always integer).
  That is the truncation the `!error` assertions at the top of `scroll.acme` guard against.
- **`&` un-does `!pseudopc`.**
  Inside the `!pseudopc EF_COPIER { }` block in `easyflash.acme` a label evaluates to its _run_ address in RAM;
  `&label` gives the address it is actually stored at in the cartridge, which is how you'd compute the copier's
  source range from labels rather than by hand.
- **Macro scoping is why `+scroll_axis` can be instantiated four times**:
  each macro _call_ gets its own scope for `.local` symbols, and anonymous `+`/`-` labels work inside macros too.
  Macros may also be overloaded on parameter count, and `~param` passes by reference.
- **Two label files, and only one of them is for VICE.**
  `!sl "labels.l"` in `engine.acme` writes ACME source (`SYMBOL = $xxxx`), which is loadable back into another
  assembly with `!source` but means nothing to the emulator.
  VICE's monitor `ll` wants `al C:xxxx .name`, which only the `--vicelabels FILE` CLI switch emits;
  the `Makefile` passes it as `$(VICE_LABELS)` on every `engine.acme` build, so `ll "labels.vice"` in the monitor
  gets you symbols.
- **`acme -v2` prints every segment's start, end and size**, and `-r FILE` writes a listing with the address and the
  emitted bytes next to each source line.
  Both are cheaper than the `-DDEBUG` `!warn`s when the question is just how much room is left in a segment.
- `<...>` includes need the library path, which acme reads from the **`ACME` environment variable** (or `--libpath`).
  Nothing here uses them, but the name is a trap:
  `make regress` has to hand the assembler's path to `tools/regress.sh`, and calling that variable `ACME` would
  export it straight into acme's own environment as a library path pointing at the executable.
  It is called `ACME_BIN` for that reason — the `ACME` in `config.default` is a make variable and is never exported.

## External references — `submodules/`

Three references, checked out as submodules:
the two _All About Your …_ HTML sets and `c64docs`.
They are hardware/ROM documentation, not build inputs — nothing in the `Makefile` reads them.

The _All About Your …_ sets and `c64docs/cbm64mem.html` are HTML with no plain-text copy, so read them with the tags
stripped and search them with `grep`:

```bash
cd submodules/aay64
sed -e 's/<[^>]*>//g' VIC17.HTM      # one page, readable
grep -ril badline *.HTM              # find the page first
```

`INDEX.HTM` / `INDEXLST.HTM` are the hand-written entry points, but the filenames are systematic enough to jump
straight in.

### `submodules/c64docs` — VIC-II internals, a cycle chart, and a one-page memory map

`vic-ii.txt` is Christian Bauer's _The MOS 6567/6569 video controller (VIC-II) and its application in the Commodore 64_
(1996).
This is the reference `raster.acme` was missing:
section 3.14 describes every technique the engine is built on, by name and in terms of the VIC's internal counters.

It is UTF-8 with Unix line endings, so it reads and greps directly.
(It was converted from the shipped Latin-1/CRLF original, which `grep` classified as binary and returned no hits for.)

| section              | content                                                                                                                                                                          |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 3.5                  | the Bad Line Condition, stated literally — the rule every stage of the IRQ chain plays against                                                                                   |
| 3.6.3                | cycle-by-cycle timing of a raster line: `BA`/`AEC`, VIC vs 6510 access per clock phase, X coordinate per cycle. The 6569 diagrams are the sprite-less ones; sprites are in 3.8.1 |
| 3.7.2                | `VC`/`RC` — the counters that make linecrunch and DMA delay shift the display at all                                                                                             |
| 3.8.1                | sprite DMA: p-/s-accesses in statically assigned cycles, `BA` low three cycles ahead, the Y-expansion flip flop. The cycle numbers here _are_ 6569                               |
| 3.9                  | the border unit's comparators, i.e. how the borders are opened                                                                                                                   |
| 3.14.2/3.14.4/3.14.6 | FLD, Linecrunch, and DMA delay — the last is what this repo calls VSP                                                                                                            |
| 3.14.1/3/5/7         | Hyperscreen, FLI, doubled text lines, sprite stretching — the neighbouring tricks                                                                                                |

3.14.6 closes by naming the combination the engine _is_:
DMA delay plus FLD plus Linecrunch scrolls a whole graphics screen in all directions without moving bytes — AGSP.
It also explains a symptom worth recognising when the VSP misfires:
the first three c-accesses after the late bad line read `$ff` as character pointers and the low nibble of the opcode
following the `$d011` write as colour, because `AEC` trails `BA` by three cycles.

`victiming.pdf` is Linus Åkesson's _VIC 6569/8565 Timing Chart_, one landscape A4 page
(<http://www.linusakesson.net/programming/vic-timing/>).
Where `vic-ii.txt` explains the chip in prose, this is the same state machine as a lookup table:
rows are the 63 cycles of a raster line, columns are the conditions — border wide/narrow, graphics idle vs display vs
display+badline with `RC = 7` or `RC < 7`, per-sprite DMA and Y-expansion — and each cell is what the VIC does then.
Two smaller tables at the bottom give the per-raster-line border-flag actions and the sprite crunch function.

It reads well as text; render it only if you want the actual grid:

```bash
pdftotext -layout victiming.pdf -                       # keeps the columns aligned
pdftoppm -r 130 -png -singlefile victiming.pdf /tmp/vt  # the chart as an image
```

What it answers at a glance, and the prose does not:

- **Which cycle each badline consequence lands in** — `VCBASE -> VC` in 11-13, clear `RC` in 14, the c-access in
  15-16, `VC -> VCBASE` plus "go idle or increment `RC`" in 58.
  That is the timeline `raster.acme` is steering every time it moves a badline.
- **The sprite cycle steal, per sprite** — sprite 0 fetches in cycle 58, 1 in 60-61, 2 in 62-63, and 3-7 in cycles
  1-10, so sprites 0-2 are paid for out of the _previous_ line;
  the footnote adds that the CPU stalls three cycles before each fetch.
  This is the accounting behind the crunch band's `63-19 = 44` cycle path.
- **The border flip-flops**, which is the reference for anything touching the bottom border:
  the vertical flag is cleared on line `$33` and set on `$fb` when RSEL is set, `$37`/`$f7` when it is clear, and the
  main border switches in cycles 17/57 (CSEL set) or 18/56 (clear).
  The same table shows `DEN` being sampled in cycle 1 of line `$30` only — the D-flag that gates every later badline.
- **The sprite crunch function `Cr(MCBASE)`** — the from/to/deviation table for what `MCBASE` becomes when `$d017`
  is written in cycle 15. Nothing here does that yet.

`cbm64mem.html` is a single-page `$0000-$ffff` map — zero-page/KERNAL variables, then every VIC, SID and CIA register
with its bit fields and power-up default.
Faster to grep than aay64's one-page-per-register when you just want a bit meaning.
Its defaults `$d011 = $1b` and `$d016 = $c8` are the KERNAL's `$9b`/`$08` from _Cartridge boot_ above, minus the
read-only raster MSB and plus `$d016`'s unused high bits, which always read as set.

### `submodules/aay64` — the C64

| files                                       | content                                                                                                                                                                                |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `VICnn.HTM`                                 | one page per VIC register, `nn` = **decimal** index — `VIC17.HTM` is `$d011`. Bit fields, power-up default, and the KERNAL addresses that read/write it                                |
| `ROMECB9.HTM`                               | the KERNAL's _Video Chip Setup Table_: the defaults `$d000-$d02e` get, copied by `ROME5A0.HTM`                                                                                         |
| `ROMFDA3.HTM`                               | KERNAL `IOINIT` disassembled — CIA1/CIA2 ICR, CRA/CRB, DDRs, `$00`/`$01`                                                                                                               |
| `ROMFF5B.HTM`, `ROME518.HTM`, `ROME5A0.HTM` | `CINT` → I/O defaults → the table copy                                                                                                                                                 |
| `CIA1n.HTM`, `CIA2n.HTM`, `SIDn.HTM`        | CIA and SID registers, same layout as the VIC pages                                                                                                                                    |
| `MEMCFG.HTM`                                | the `$01` truth table, including how /CharEn, /LoRam and /HiRam derive it                                                                                                              |
| `B*.HTM`                                    | one page per opcode: bytes and cycles per addressing mode, **illegal opcodes included** (`BLAX` = `lax`, `BSAX`, `BDCP`, `BISB`, `BSLO`, `BSRE`, `BSHX/Y/A/S`, `BSBX`, `BLAE`, `BJAM`) |
| `ADDR*.HTM`, `CPUBUGS.HTM`                  | addressing modes with timings, CPU quirks                                                                                                                                              |
| `VICTYPES.HTM`, `VICTBL*.HTM`               | 6569 vs 6567: lines, cycles per line, vblank range, X coordinate per cycle                                                                                                             |
| `CARTMAIN.HTM`, `MMC*.HTM`                  | expansion port and cartridge basics — the EasyFlash ProgRef stays authoritative for this build                                                                                         |
| `GFX*.HTM`                                  | picture _file formats_ (Koala, Art Studio, FLI variants), not techniques                                                                                                               |
| `ROMxxxx.HTM`                               | commented BASIC/KERNAL disassembly, named by address                                                                                                                                   |

The boot-stub rules in _Cartridge boot_ above are all checkable here: `ROMFDA3.HTM` is where `DDRA = $3f` comes from,
and `ROMECB9.HTM` gives the `$d011 = $9b` / `$d016 = $08` the KERNAL would have left behind.
What it does **not** cover is the demo-coding side — there is no page on FLD, VSP, line crunch, AGSP or badline timing,
so `raster.acme` has no reference here beyond the raw register semantics.
That is what `c64docs/vic-ii.txt` is for.

### `submodules/aay1541` — the drive

1541 ROM disassembly (`RO41*.HTM`), drive zero page and RAM (`RA41*.HTM`), VIA registers (`VIA*.HTM`), job and error
codes.
Nothing the current build touches — it becomes relevant only if disk loading or a fastloader is ever added.
