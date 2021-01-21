#!/bin/bash

ACME="./acme0.97mac/acme"

LOADER="./loader-v184/loader"
EXO="$LOADER/tools/exomizer-3/src/exomizer"
CC1541="$LOADER/tools/cc1541/cc1541"
TC="$LOADER/tools/tinycrunch_v1.2/tc_encode.py"

echo
echo "-----------------------------------------------------------------------------------------"
echo "make.sh depends on acme, exomizer, cc1541 and tinycrunch. Please update the paths in this"
echo "script accordingly. Note that exomizer, cc1541 and tinycrunch are included in the tools"
echo "folder of Krill's loader which can be found here: https://csdb.dk/release/?id=189130" 
echo "Before running c64engine.d64 in VICE, make sure 'True drive emulation' is enabled and" 
echo "'IEC-device' is -disabled-. Then select 'attach disk image' and point it to c64engine.d64" 
echo "-----------------------------------------------------------------------------------------"
echo

./clean.sh && \
$ACME -DSYSTEM=64 engine.acme && $EXO sfx sys engine.prg -B -x1 -o scroll.prg && \
printf '\000\060' | cat - map.bin > map.prg && $TC -i map.prg map_tc.prg && \
printf '\000\220' | cat - colors.bin > colors.prg && $TC -i colors.prg colors_tc.prg && \
printf '\000\226' | cat - screen.bin > screen.prg && $TC -i screen.prg screen_tc.prg && \
printf '\000\234' | cat - pixels.bin > pixels.prg && $TC -i pixels.prg pixels_tc.prg && \
$CC1541 -n c64engine -f map -w map_tc.prg -f colors -w colors_tc.prg -f screen -w \
  screen_tc.prg -f pixels -w pixels_tc.prg -f "scroll#a0,8,1" -w scroll.prg c64engine.d64
