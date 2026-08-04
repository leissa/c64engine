#!/usr/bin/env python3
"""Pick the screen-ring phase that hides the most sprite-pointer cells.

Screen memory is a 1024 byte ring -- tiles.acme masks a cursor's high byte with %11111011 --
and SPRITE_PTR is SCREEN+$3f8, inside it.  So ring offsets 1016..1023 hold the eight sprite
pointers rather than screen codes, and whatever char cells map there take their %01 and %10
colours from pointer bytes the multiplexer rewrites every frame.  That is the blinking the
README's "give priority to colour %11" note is about.

Which cells those are is a free parameter.  A char cell (mc, mr) of the area lives at

    off(mc, mr) = (RING_PHASE + mc + SCREEN_COLS*mr) mod 1024

because a char column step is +-1 and a char row step is +-SCREEN_COLS, so rotating
RING_PHASE moves the spoiled cells around the map.  They always land in runs of up to 8
consecutive chars within a row, in clusters of 2-3 adjacent rows, and the clusters repeat
every 26 rows -- 26*SCREEN_COLS = 1040 = 1024 + 16, which is also where the "a Y wrap shifts
the AGSP origin by 16 chars" coupling in scroll.acme comes from.

The camera clamp and the AGSP band leave a frame of the area that can never be seen, and
parking runs there is worth more than any art trick because it holds for every map.  Both
bounds below are measured, not derived: force a stick direction, park at a clamp, and match
the screenshot against a render of the area (see "Measuring the visible window" in CLAUDE.md).

  tools/ringphase.py                # the ranking, art independent
  tools/ringphase.py --art          # ... and what the current area's art would hide on top
  tools/ringphase.py --phase 544    # the cells of one phase, as the table in README.md
"""
import argparse

AREA_COLS = AREA_ROWS = 32
TILE_COLS, TILE_ROWS = 3, 2
SCREEN_COLS, SCREEN_ROWS = 40, 25
TILES = 128
RING = 1024
BAD = range(1016, 1024)                      # SPRITE_PTR = SCREEN+$3f8 .. +7

MAP_W, MAP_H = AREA_COLS * TILE_COLS, AREA_ROWS * TILE_ROWS

# Camera clamp, in chars: CAMERA_*_MAX / 8.
CAM_C_MAX = AREA_COLS * TILE_COLS - SCREEN_COLS - TILE_COLS      # 53
CAM_R_MAX = AREA_ROWS * TILE_ROWS - SCREEN_ROWS - TILE_ROWS      # 37

# Where the visible picture sits relative to the camera, in chars.  Measured: the AGSP band
# eats the first 25 raster lines of the display window and pushes the last rows of screen
# matrix past the bottom border, and 38 column mode clips the sides.
WIN_ROW_FIRST, WIN_ROW_LAST = 2.125, 22.625
WIN_COL_FIRST, WIN_COL_LAST = 2.875, 40.75

# What init_ptrs pairs ring offset 0 with today: the map char the cursors start on.
PHASE_DEFAULT = -((27 * TILE_COLS + 2) + SCREEN_COLS * (2 * TILE_ROWS + 1)) % RING   # 741


def visible(mc, mr):
    """Can this char cell ever be seen, anywhere in the camera's range?"""
    col = (mc + 1 > WIN_COL_FIRST) and (mc < CAM_C_MAX + WIN_COL_LAST)
    row = (mr + 1 > WIN_ROW_FIRST) and (mr < CAM_R_MAX + WIN_ROW_LAST)
    return col and row


def bad_cells(phase):
    out = []
    for mr in range(MAP_H):
        base = (phase + SCREEN_COLS * mr) % RING
        for mc in range(MAP_W):
            if (base + mc) % RING in BAD:
                out.append((mc, mr))
    return out


def immunity():
    """Per tile and char: does the art use only %00 and %11, so a wrong screen byte cannot show?"""
    px = open("pixels.bin", "rb").read()
    out = []
    for t in range(TILES):
        chars = []
        for c in range(TILE_COLS * TILE_ROWS):
            ok = True
            for r in range(8):
                b = px[c * 8 * TILES + r * TILES + t]
                for s in (0, 2, 4, 6):
                    ok = ok and ((b >> s) & 3) not in (1, 2)
            chars.append(ok)
        out.append(chars)
    return out


def tabulate(phase, with_art):
    """One phase, cell by cell, in the shape README.md documents."""
    m = immune = None
    if with_art:
        m, immune = open("map.bin", "rb").read(), immunity()

    per = {}
    for mc, mr in bad_cells(phase):
        per.setdefault(mr, []).append(mc)

    print(f"phase {phase}: {sum(len(v) for v in per.values())} cells in {len(per)} runs, "
          f"{sum(visible(mc, mr) for mr in per for mc in per[mr])} of them ever visible")
    head = ("| char row | char cols | tile row | tile sub-row | tile cols touched | ever visible |"
            + (" art safe |" if with_art else ""))
    print(f"\n{head}\n{'|---' * (6 + with_art)}|")
    for mr in sorted(per):
        cs = sorted(per[mr])
        seen = "yes" if any(visible(mc, mr) for mc in cs) else "never"
        row = (f"| {mr} | {cs[0]}-{cs[-1]} | {mr // TILE_ROWS} | {mr % TILE_ROWS} | "
               f"{cs[0] // TILE_COLS}-{cs[-1] // TILE_COLS} | {seen} |")
        if with_art:
            safe = sum(immune[m[(mr // TILE_ROWS) * AREA_COLS + mc // TILE_COLS]]
                       [(mr % TILE_ROWS) * TILE_COLS + (mc % TILE_COLS)] for mc in cs)
            row += f" {safe}/{len(cs)} |"
        print(row)
    print(f"\nWithin a run the cells are hardware sprites 0..{len(BAD) - 1} left to right: ring offset "
          f"{BAD[0]}+n is sprite n's pointer, its high nibble is the cell's %01 colour and its low nibble %10.")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--art", action="store_true",
                   help="also score against map.bin/pixels.bin: cells on %%00/%%11 only art cannot show")
    p.add_argument("--top", type=int, default=10, help="how many phases to list")
    p.add_argument("--phase", type=int, default=None,
                   help="skip the ranking and just tabulate this phase's cells")
    a = p.parse_args()

    if a.phase is not None:
        tabulate(a.phase, a.art)
        return

    m = immune = None
    if a.art:
        m, immune = open("map.bin", "rb").read(), immunity()

    def art_spoiled(cells):
        n = 0
        for mc, mr in cells:
            t = m[(mr // TILE_ROWS) * AREA_COLS + mc // TILE_COLS]
            c = (mr % TILE_ROWS) * TILE_COLS + (mc % TILE_COLS)
            n += visible(mc, mr) and not immune[t][c]
        return n

    rows = []
    for phase in range(RING):
        cells = bad_cells(phase)
        vis = sum(visible(mc, mr) for mc, mr in cells)
        rows.append((vis, art_spoiled(cells) if a.art else 0, phase, len(cells)))
    rows.sort()

    best = rows[0][0]
    print(f"cells on a sprite pointer: {min(r[3] for r in rows)}-{max(r[3] for r in rows)} "
          f"depending on phase; of those, {best}-{rows[-1][0]} can be seen")
    hdr = "  phase  cells  visible" + ("  spoiled(art)" if a.art else "")
    print(f"\nbest {a.top} phases:\n{hdr}")
    for vis, art, phase, tot in rows[:a.top]:
        print(f"  {phase:5}  {tot:5}  {vis:7}" + (f"  {art:13}" if a.art else ""))

    cur = [r for r in rows if r[2] == PHASE_DEFAULT][0]
    print(f"\ndefault pairing (screen cursor 0 at MAP_INIT) is phase {PHASE_DEFAULT}: "
          f"{cur[3]} cells, {cur[0]} visible" + (f", {cur[1]} spoiled" if a.art else ""))
    print(f"worst phase {rows[-1][2]}: {rows[-1][0]} visible")

    tied = [r for r in rows if r[0] == best]
    print(f"\n{len(tied)} phases reach the minimum {best}.")
    if a.art:
        tied.sort(key=lambda r: (r[1], r[2]))
        print("of those, fewest spoiled on the current area's art:")
        for vis, art, phase, tot in tied[:a.top]:
            print(f"  phase {phase:4}: {vis} visible, {art} spoiled")

    show = tied[0][2]
    print(f"\nphase {show}, cell by cell:")
    per = {}
    for mc, mr in bad_cells(show):
        per.setdefault(mr, []).append(mc)
    for mr in sorted(per):
        cs = sorted(per[mr])
        tag = "".join("X" if visible(mc, mr) else "-" for mc in cs)
        print(f"  map row {mr:2}, cols {cs[0]:2}-{cs[-1]:2}: {tag}")
    print("  (X can be seen, - never: outside the camera's reach or behind the AGSP band)")


if __name__ == "__main__":
    main()
