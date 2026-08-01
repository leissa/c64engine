CONFIG ?= config.default
-include $(CONFIG)

# clean/distclean need no external tools, everything else does
ifeq ($(filter clean distclean,$(MAKECMDGOALS)),)
ifeq ($(wildcard $(CONFIG)),)
$(error $(CONFIG) not found -- run 'cp config.default.template $(CONFIG)' and edit it)
endif
endif

OUT       ?= engine
CRT       ?= $(OUT).crt
CART_NAME ?= c64engine

MKCART    ?= tools/mkcart.py
REGRESS   ?= tools/regress.sh
X64SC     ?= x64sc
REGRESS_OUT ?= regress

# EAPI is not redistributed here.
# Fetch its sources at a pinned revision and assemble them with the acme we already depend on.
# Section references are to the EasyFlash Programmer's Guide;
# 5.1 asks for the Am29F040 build in particular, because that is the chip emulators implement.
EAPI_DIR  ?= ./eapi
EAPI      ?= $(EAPI_DIR)/eapi-am29f040-14
EAPI_REV  ?= 9c787d3b94697d247342a6146f2e27d69cf916e6
EAPI_URL  ?= https://raw.githubusercontent.com/luigidifraia/easyflash/$(EAPI_REV)/EasySDK/eapi
EAPI_SRC  := $(EAPI_DIR)/eapi-am29f040.s $(EAPI_DIR)/eapi_defs.s

ENGINE_ACME := engine.acme
ENGINE_OBJ  := $(ENGINE_ACME:.acme=.obj)
EFBOOT_ACME := easyflash.acme
EFBOOT_BIN  := efboot.bin

# Everything the sources pull in via !source and !bin.
# The two binaries have separate source lists so that editing one does not rebuild the other, and efboot.bin is
# filtered out because it is a build product, not tile data.
LIB_SRC     := $(sort $(wildcard lib/*.acme))
ENGINE_SRC  := $(sort $(filter-out $(EFBOOT_ACME),$(wildcard *.acme))) $(LIB_SRC)
ENGINE_DATA := $(sort $(filter-out $(EFBOOT_BIN),$(wildcard *.bin)) \
                     $(wildcard snd/*.bin) $(wildcard spr/*.raw))

# Memory the engine builds at runtime, so it does not have to travel in the cartridge:
# HIRES ($c000-$dfff) and SCREEN ($e000-$e3ff), both filled by init_screen.
# Keep in sync with lib/mem.acme.
CART_SKIP ?= 0xc000:0xe400

# use 'make Q=' to get a verbose output of all commands
Q ?= @

# never leave a half-written file behind:
# make would treat it as up to date
.DELETE_ON_ERROR:

.PHONY: all clean distclean run dev prg regress

all: $(CRT)

$(EAPI_DIR):
	$(Q)$(MKDIR) -p $@

$(EAPI_SRC): | $(EAPI_DIR)
	@echo '===> FETCH $(@F)'
	$(Q)$(WGET) -q $(EAPI_URL)/$(@F) -O $@

# acme resolves !source against the working directory, so build this in place
$(EAPI): $(EAPI_SRC)
	@echo '===> ACME $(@F)'
	$(Q)cd $(EAPI_DIR) && $(ACME) -o $(@F) eapi-am29f040.s

$(ENGINE_OBJ): $(ENGINE_ACME) $(ENGINE_SRC) $(ENGINE_DATA)
	@echo '===> ACME $<'
	$(Q)$(ACME) -f cbm -DSYSTEM=64 -o $@ $<

$(EFBOOT_BIN): $(EFBOOT_ACME) $(LIB_SRC)
	@echo '===> ACME $<'
	$(Q)$(ACME) -f plain -o $@ $<

$(CRT): $(ENGINE_OBJ) $(EFBOOT_BIN) $(EAPI) $(MKCART)
	@echo '===> MKCART $@'
	$(Q)$(PYTHON) $(MKCART) --engine $(ENGINE_OBJ) --boot $(EFBOOT_BIN) \
	    --eapi $(EAPI) --name "$(CART_NAME)" $(if $(Q),,-v) \
	    $(foreach r,$(CART_SKIP),--skip $(r)) -o $@

# Headless autopilot run; see tools/regress.sh and the AUTOPILOT block in
# joystick.acme.  Pass a previously captured directory to also diff rendering:
#   make regress REGRESS_REF=regress-before
regress:
	@echo '===> REGRESS'
	$(Q)X64SC='$(X64SC)' ACME='$(ACME)' $(REGRESS) $(REGRESS_OUT) $(REGRESS_REF)

clean:
	@echo '===> CLEAN'
	$(Q)rm -f $(CRT) $(ENGINE_OBJ) $(EFBOOT_BIN) $(OUT).prg labels.l
	$(Q)rm -rf $(REGRESS_OUT)

distclean: clean
	@echo '===> DISTCLEAN'
	$(Q)rm -rf $(EAPI_DIR)

# +easyflashcrtwrite matters:
# VICE writes the cartridge image back on exit by default, which rewrites the CRT name and (with its optimizer) drops
# every unused bank -- quietly replacing the build artifact with a 4 bank image.
run: $(CRT)
	@echo '===> RUN $<'
	$(Q)$(X64) +easyflashcrtwrite -cartcrt $(CRT)

# dev and prg write the same engine.prg with different flags, so they always rebuild instead of tracking dependencies
dev:
	@echo '===> DEV'
	$(Q)rm -f $(OUT).prg
	$(Q)$(ACME) -DSYSTEM=64 -DDEVELOP=1 -DDEBUG=1 $(ENGINE_ACME)

prg:
	@echo '===> PRG'
	$(Q)rm -f $(OUT).prg
	$(Q)$(ACME) -DSYSTEM=64 -DDEVELOP=1 $(ENGINE_ACME)
