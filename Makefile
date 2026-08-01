CONFIG ?= config.default
-include $(CONFIG)

# clean/distclean need no external tools, everything else does
ifeq ($(filter clean distclean,$(MAKECMDGOALS)),)
ifeq ($(wildcard $(CONFIG)),)
$(error $(CONFIG) not found -- run 'cp config.default.template $(CONFIG)' and edit it)
endif
endif

OUT       ?= engine
D64       ?= $(OUT).d64
KRILL     ?= ./krill
KRILL_URL ?= "http://csdb.dk/getinternalfile.php/196649/loader-v184.zip"
INC       ?= $(KRILL)/loader/build/loadersymbols-c64.inc
CC1541    ?= $(KRILL)/loader/tools/cc1541/cc1541
EXO       ?= $(KRILL)/loader/tools/exomizer-3/src/exomizer
TC        ?= $(KRILL)/loader/tools/tinycrunch_v1.2/tc_encode.py

ENGINE_ACME := engine.acme
ENGINE_OBJ := $(filter %.obj, $(ENGINE_ACME:.acme=.obj))
ENGINE_EXO := $(filter %.exo, $(ENGINE_OBJ:.obj=.exo))

ENGINE_BIN := $(sort $(wildcard *.bin))
ENGINE_PRG := $(filter %.prg, $(ENGINE_BIN:.bin=.prg))
ENGINE_TC  := $(filter %.tc,  $(ENGINE_PRG:.prg=.tc))

# everything engine.acme pulls in via !source and !bin
ENGINE_SRC  := $(sort $(wildcard *.acme) $(wildcard lib/*.acme))
ENGINE_DATA := $(sort $(wildcard snd/*.bin) $(wildcard spr/*.raw))

# keep the on-disk order in sync with the loadcompd calls in engine.acme so the
# drive head only ever moves forward; anything not listed is appended
DISK_ORDER := map.tc colors.tc screen.tc pixels.tc
ENGINE_TC  := $(filter $(ENGINE_TC),$(DISK_ORDER)) $(filter-out $(DISK_ORDER),$(ENGINE_TC))

# disk file names are the .bin base names, as expected by loadcompd in engine.acme
CC1541_FILES = $(foreach f,$(ENGINE_TC),-f $(basename $(f)) -w $(f))

map.bin.addr    := '\x00\x30'
colors.bin.addr := '\x00\x90'
screen.bin.addr := '\x00\x96'
pixels.bin.addr := '\x00\x9c'

# use 'make Q=' to get a verbose output of all commands
Q ?= @

# never leave a half-written file behind: make would treat it as up to date
.DELETE_ON_ERROR:

.PHONY: all clean distclean run dev prg

all: $(D64)

$(INC):
	@echo '===> INSTALL KRILL LOADER'
	$(Q)$(WGET) $(KRILL_URL) -O krill.zip
	$(Q)$(MKDIR) -p $(KRILL)
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

# engine.acme !sources/!bins these, so they belong in the .obj dependencies.
# naming .obj/.prg in an explicit rule would cost them their intermediate
# status, so declare it back: they are rebuilt on demand and cleaned up after.
$(ENGINE_OBJ): $(ENGINE_SRC) $(ENGINE_DATA)
.INTERMEDIATE: $(ENGINE_OBJ) $(ENGINE_PRG)

%.exo: %.obj $(EXO)
	@echo '===> EXO $<'
	$(Q)$(EXO) sfx sys $< -B -x1 -o $@

%.prg: %.bin
	@echo '===> BIN to PRG $<'
	$(Q)$(if $($(<).addr),,$(error no load address for $< -- define '$(<).addr' in the Makefile, matching lib/mem.acme))
	$(Q)printf $($(<).addr) | cat - $< > $@

# $(INC) doubles as the marker for "krill is unpacked", which is where $(TC) lives
%.tc: %.prg $(INC)
	@echo '===> TC $<'
	$(Q)$(PYTHON) $(TC) -i $< $@

$(D64): $(CC1541) $(ENGINE_TC) $(ENGINE_EXO)
	@echo '===> CC1541 $@'
	$(Q)$(CC1541) -n $(OUT) -f "$(OUT)#a0,8,1" -w $(ENGINE_EXO) $(CC1541_FILES) $(D64)

clean:
	@echo '===> CLEAN'
	$(Q)rm -f $(D64) $(ENGINE_EXO) $(ENGINE_OBJ) $(ENGINE_TC) $(ENGINE_PRG)
	$(Q)rm -f $(OUT).prg labels.l krill.zip

distclean: clean
	@echo '===> DISTCLEAN'
	$(Q)rm -rf $(KRILL)

run: $(D64)
	@echo '===> RUN $<'
	$(Q)$(X64) $(D64)

# dev and prg write the same engine.prg with different flags, so they always
# rebuild instead of tracking dependencies
dev:
	@echo '===> DEV'
	$(Q)rm -f $(OUT).prg
	$(Q)$(ACME) -DSYSTEM=64 -DDEVELOP=1 -DDEBUG=1 $(ENGINE_ACME)

prg:
	@echo '===> PRG'
	$(Q)rm -f $(OUT).prg
	$(Q)$(ACME) -DSYSTEM=64 -DDEVELOP=1 $(ENGINE_ACME)
