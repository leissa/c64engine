CONFIG ?= config.default
-include $(CONFIG)

OUT       ?= engine
D64       ?= $(OUT).d64
KRILL     ?= ./krill
KRILL_URL ?= "https://krill.e2m.io/loader-v184.zip"
INC       ?= $(KRILL)/loader/build/loadersymbols-c64.inc
CC1541    ?= $(KRILL)/loader/tools/cc1541/cc1541
EXO       ?= $(KRILL)/loader/tools/exomizer-3/src/exomizer
TC        ?= $(KRILL)/loader/tools/tinycrunch_v1.2/tc_encode.py

ENGINE_ACME := engine.acme
ENGINE_OBJ := $(filter %.obj, $(ENGINE_ACME:.acme=.obj))
ENGINE_EXO := $(filter %.exo, $(ENGINE_OBJ:.obj=.exo))

ENGINE_BIN := $(wildcard *.bin)
ENGINE_PRG := $(filter %.prg, $(ENGINE_BIN:.bin=.prg))
ENGINE_TC  := $(filter %.tc,  $(ENGINE_PRG:.prg=.tc))

map.bin.addr    := '\x00\x30'
colors.bin.addr := '\x00\x90'
screen.bin.addr := '\x00\x96'
pixels.bin.addr := '\x00\x9c'

# use 'make Q=' to get a verbose output of all commands
Q ?= @

all: $(D64)

$(INC):
	@echo '===> INSTALL KRILL LOADER'
	$(Q)$(WGET)  $(KRILL_URL) -O krill.zip
	$(Q)$(MKDIR) $(KRILL)
	$(Q)$(UNZIP) krill.zip -d $(KRILL)
	$(Q)$(MAKE)  -C $(KRILL)/loader

$(CC1541): $(INC)
	@echo '===> INSTALL CC1541'
	$(Q)$(MAKE)  -C $(KRILL)/loader/tools/cc1541

$(EXO): $(INC)
	@echo '===> INSTALL EXOMIZER'
	$(Q)$(MAKE)  -C $(KRILL)/loader/tools/exomizer-3/src

%.obj: %.acme $(INC)
	@echo '===> ACME $<'
	$(Q)$(ACME) -f cbm -DSYSTEM=64 -o $@ $<

%.exo: %.obj $(EXO)
	@echo '===> EXO $<'
	$(EXO) sfx sys $< -B -x1 -o $@

%.prg: %.bin
	@echo '===> BIN to PRG $<'
	$(Q)printf $($(<).addr) | cat - $< > $@

%.tc: %.prg $(INC)
	@echo '===> TC $<'
	$(Q)$(TC) -i $< $@

$(D64): $(CC1541) $(ENGINE_TC) $(ENGINE_EXO)
	@echo '===> CC1541 $@'
	$(Q)$(CC1541) -n $(OUT) -f "$(OUT)#a0,8,1" -w $(ENGINE_EXO) -f map -w map.tc -f colors -w colors.tc -f screen -w screen.tc -f pixels -w pixels.tc $(D64)

clean:
	@echo '===> CLEAN'
	$(Q)rm -f $(D64) $(ENGINE_EXO) $(ENGINE_TC) krill.zip

distclean: clean
	@echo '===> DISTCLEAN'
	$(Q)rm -rf $(KRILL)

run: $(D64)
	@echo '===> RUN $<'
	$(Q)$(X64) -device8 0 +iecdevice8 -truedrive -8 $(D64)
