#!/bin/sh
#
# Headless regression run for the engine.
#
# Builds engine.acme with -DAUTOPILOT (see joystick.acme) at a series of stop
# frames, runs each one in VICE with no display, and reports:
#
#   * any `jam`, which under -DDEVELOP means the frame's work ran past LINE_0-1,
#     i.e. the raster budget was blown -- this is the check that matters most and
#     it needs no reference data;
#   * optionally, a screenshot diff against a directory captured earlier, for
#     refactors that are supposed to leave rendering untouched.
#
# The autopilot freezes the engine once it has replayed its pattern, so the
# screen is static by the time the screenshot is taken.  Without that the exit
# screenshot depends on which cycle the emulator happens to stop on and is not
# reproducible -- do not "simplify" it away.
#
# ACME_BIN and X64SC come from the environment; 'make regress' passes them
# through from config.default, which is Makefile syntax and cannot be sourced
# here.  The assembler's path is *not* passed as ACME: acme reads that variable
# as its <...> include library path, so exporting it would point the library at
# the executable.
#
# usage: tools/regress.sh <outdir> [reference-dir]

set -e

OUT=${1:?usage: tools/regress.sh <outdir> [reference-dir]}
REF=$2

ACME_BIN=${ACME_BIN:-acme}
X64SC=${X64SC:-x64sc}

# spread over the phases of AUTOPILOT_TBL: each direction alone, the diagonal, and
# the three reversal patterns
STOPS=${STOPS:-"30 60 90 120 150 180 210 240"}

# well past the ~256 frames the pattern takes, so the screen has gone static
CYCLES=${CYCLES:-12000000}

mkdir -p "$OUT"
fail=0

for n in $STOPS; do
    $ACME_BIN -DSYSTEM=64 -DDEVELOP=1 -DAUTOPILOT=1 -DAUTOPILOT_FRAMES="$n" \
          -f cbm -o "$OUT/ap$n.prg" engine.acme > "$OUT/build$n.log" 2>&1 || {
        echo "FAIL build (stop=$n)"; cat "$OUT/build$n.log"; exit 1; }

    $X64SC -default -warp -sounddev dummy -jamaction 5 \
           -autostartprgmode 1 +drive8truedrive -limitcycles "$CYCLES" \
           -exitscreenshot "$OUT/n$n.png" -autostart "$OUT/ap$n.prg" \
           > "$OUT/run$n.log" 2>&1 || true

    if grep -q "Main CPU: JAM" "$OUT/run$n.log"; then
        echo "FAIL stop=$n: raster budget blown ($(grep -o 'JAM at \$[0-9A-F]*' "$OUT/run$n.log" | head -1))"
        fail=1
        continue
    fi
    if [ ! -s "$OUT/n$n.png" ]; then
        echo "FAIL stop=$n: no screenshot written"; fail=1; continue
    fi
    if [ -n "$REF" ]; then
        if [ ! -f "$REF/n$n.png" ]; then
            echo "warn stop=$n: no reference image"
        elif cmp -s "$REF/n$n.png" "$OUT/n$n.png"; then
            echo "ok   stop=$n (matches reference)"
        else
            echo "FAIL stop=$n: rendering differs from reference"; fail=1
        fi
    else
        echo "ok   stop=$n"
    fi
done

[ "$fail" = 0 ] && echo "all good" || echo "regressions found"
exit $fail
