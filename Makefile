# ============================================================================
# Analogue Pocket openFPGA build environment
# ----------------------------------------------------------------------------
# Everything runs through Docker: the Quartus toolchain lives in the image,
# your source lives here. Typical porting session:
#
#   make image                     once
#   make doctor                    is the toolchain sane for the Pocket device?
#   make new CORE=mygame AUTHOR=me PLATFORM=nes
#   make build CORE=mygame         quartus_sh --flow compile + rbf_r
#   make package CORE=mygame       -> build/sd/<core>/{Cores,Platforms,Assets} + zip
#   make check-build CORE=mygame   audit the Quartus reports for dead logic / bad clocks
#   make sim | sim-write | sim-rom | sim-soc | sim-top | sim-iv | sim-reset  simulate (Silice image)
#   make pocket-translate          .si -> cores/aw/src/fpga/core/aw_pocket_build.v
#
# Variables (override on the command line or in config.mk):
#   CORE              core under cores/ to work on        (default core-template)
#   AUTHOR            author id used by 'make new'
#   IMAGE             derived build image tag
#   JOBS              parallelism for Quartus (default: all cpus)
#   QUARTUS_ARGS      extra args handed to 'quartus_sh --flow compile'
#   ALLOW_TIMING_FAIL set to 1 to keep going when STA reports negative slack
#
# There is a second, separate workstream in this repo: ports/another-world
# (the a5k / Silice port). It has its own image and its own targets at the
# bottom of this file - 'make help' lists them. Silice translates .si to
# Verilog; only then does the Quartus flow above apply to it.
# ============================================================================

CORE         ?= core-template
AUTHOR       ?= author
BASE_IMAGE   ?= didiermalenfant/quartus:22.1-apple-silicon
IMAGE        ?= local/ap-pocket:quartus22.1
SILICE_IMAGE ?= local/ap-silice:latest
AW           := ports/another-world
CORE_DIR    := cores/$(CORE)
BUILD       := build/$(CORE)
OUT_DIR     := /work/build          # same folder, seen from inside the container
# Per core, deliberately: the packager merges into this directory and zips whatever
# is in it, and a shared build/sd meant that packaging aw shipped Developer.CoreTemplate
# and Platforms/ex_platform.json - 12 files belonging to other cores - inside aw's zip.
SD          := build/sd/$(CORE)
-include config.mk

AP       := ./docker/run.sh
SILICE   := ./docker/run-silice.sh
PY       ?= python3
CORES    := $(notdir $(wildcard cores/*))

.DEFAULT_GOAL := help
.PHONY: help image pull doctor smoke shell build clean-build rev package test \
        new report list size clean distclean prune \
        silice-image silice-shell silice a5k-translate upstream probe

help:
	@echo "Analogue Pocket openFPGA build env (CORE=$(CORE), image=$(IMAGE))"
	@echo "cores available: $(or $(CORES),none)"
	@echo
	@echo "  make image                 build the Docker env on top of $(BASE_IMAGE)"
	@echo "  make pull                  pull the pre-built Quartus base image"
	@echo "  make doctor                check Quartus / Cyclone V support / mounts"
	@echo "  make smoke                 throwaway compile that proves the device works"
	@echo "  make shell                 shell inside the container (/work = this repo)"
	@echo
	@echo "  make new CORE=x AUTHOR=y   scaffold cores/x from the core template"
	@echo "  make build [CORE=x]        quartus_sh --flow compile -> $(BUILD)/bitstream.rbf_r"
	@echo "  make clean-build [CORE=x]  same, after wiping Quartus databases"
	@echo "  make rev [CORE=x]          re-reverse an .rbf into bitstream.rbf_r"
	@echo "  make report [CORE=x]       show utilisation + timing of the last build"
	@echo "  make package [CORE=x]      assemble SD layout + zip in $(SD)"
	@echo "  make test                  end-to-end: build the template and package it"
	@echo
	@echo "  make list                  list cores and their Quartus projects"
	@echo "  make size                  disk used by builds"
	@echo
	@echo "  make clean [CORE=x]        remove Quartus DBs + build output for a core"
	@echo "  make distclean             remove all build output"
	@echo "  make prune                 docker image/layer cleanup for this project"
	@echo
	@echo "Another World (a5k / Silice) port - see docs/another-world/"
	@echo "  make upstream              fetch/refresh pinned upstream a5k sources"
	@echo "  make packs                 gamedata/ -> partN.bin packs (part1 = the intro)"
	@echo "  make sim-soc [PACK=f]      boot the design in simulation, capture frames"
	@echo "  make sim-top               whole core_top: idle screen, load, mux switch, APF video protocol"
	@echo "  make ref-sim               the same pack through the golden reference sim"
	@echo "  make silice-image          build the Silice toolchain image"
	@echo "  make a5k-translate         .si -> build.v (input for the Quartus flow)"
	@echo "  make silice-shell          shell in the Silice image"
	@echo "  make silice CMD='...'      run any Silice-image command"
	@echo "  make probe SCRIPT=...      run a feasibility probe in the Quartus image"
	@echo
	@echo "Debugging: make build QUARTUS_ARGS=--effort=standard, JOBS=8,"
	@echo "           ALLOW_TIMING_FAIL=1 to ignore STA failures."
	@echo "           'make build' on an unchanged tree is answered by Quartus'"
	@echo "           smart recompilation in seconds and re-prints the previous"
	@echo "           STA summary - use 'make clean-build' to force a real one."

# --------------------------------------------------------------- environment --
pull:
	docker pull $(BASE_IMAGE)

# PERMS=1 repairs the base image's root-only Quartus install (one-off ~4 min,
# ~1.1 GB) so builds can run as your uid. PERMS=0 skips that; then use
# AP_RUN_AS=root and the entrypoint chowns artifacts back to you.
PERMS ?= 1

image:
	docker build -f docker/Dockerfile \
		--build-arg BASE_IMAGE=$(BASE_IMAGE) \
		--build-arg FIX_PERMS=$(PERMS) \
		-t $(IMAGE) .

doctor:
	@$(AP) scripts/doctor.sh

smoke:
	@$(AP) scripts/doctor.sh --smoke

shell:
	@$(AP)

# --------------------------------------------------------------------- build --
build:
	@test -d $(CORE_DIR) || { echo "no such core: $(CORE_DIR)  (make list)"; exit 1; }
	@$(AP) scripts/build.sh $(CORE_DIR) --jobs $(or $(JOBS),$(shell nproc)) \
		--out $(OUT_DIR) $(if $(NO_SIGTAP),--no-sigtap,)

clean-build:
	@test -d $(CORE_DIR) || { echo "no such core: $(CORE_DIR)"; exit 1; }
	@$(AP) scripts/build.sh $(CORE_DIR) --clean --jobs $(or $(JOBS),$(shell nproc)) \
		--out $(OUT_DIR) $(if $(NO_SIGTAP),--no-sigtap,)

# note: runs inside the container, where the repo is /work and cwd is /work
rev:
	@$(AP) sh -c 'rbf=$$(ls -t $(BUILD)/*.rbf $(CORE_DIR)/src/fpga/output_files/*.rbf 2>/dev/null | head -1); test -n "$$rbf" || { echo "no .rbf for $(CORE); run make build first"; exit 1; }; scripts/reverse_bits.py --verify "$$rbf" $(BUILD)/bitstream.rbf_r'

report:
	@cat $(BUILD)/report.txt 2>/dev/null || { echo "no report yet for $(CORE)"; exit 1; }

# ------------------------------------------------------------------ verify ---
# Audit the Quartus reports rather than trusting the exit status: a design can
# build, place, route and close timing while a RAM has become a ROM or a register
# cannot change. Runs on the host - it only reads reports.
check-build:
	@$(PY) scripts/check_build.py --core-dir $(CORE_DIR) $(if $(CLOCK_MHZ),--expect-clock $(CLOCK_MHZ),)

# The worst failing paths, which the plain .sta.rpt summarises but never lists.
worst-path:
	@$(AP) sh -c 'cd $(CORE_DIR)/src/fpga && quartus_sta -t /work/scripts/worst_path.tcl'
	@sed -n '/Summary of Paths/,/^+---/p' $(BUILD)/aw_worst.txt 2>/dev/null \
		|| sed -n '/Summary of Paths/,/^+---/p' build/aw_worst.txt

# Simulation: the Silice image carries iverilog and verilator. sim-write is the
# two-second version of the ROM question; sim_rom is the whole 2 MB pack with every
# access pattern the VM uses; sim_soc boots the design and captures frames.
sim-audio:
	@$(SILICE) scripts/sim_audio.sh

sim-write:
	@$(SILICE) scripts/sim_write.sh

sim-rom:
	@$(SILICE) scripts/sim_rom.sh $(if $(PACK),$(PACK),)

# The paged-image directory: one upload carrying every part, a part chosen by an address write,
# and the plain-pack case that must fall back to identity. Needs its own sim because the part
# select is closed once the VM has taken a byte - see the header of tb_dir.sv.
sim-dir:
	@$(SILICE) scripts/sim_dir.sh $(if $(PACK),$(PACK),)

# The Pocket controller word -> vm.si jstick mapping, on its own. tb_soc drives the SoC's jstick
# port directly, so without this the whole cont1_key mapping had no coverage - which is how it
# stayed wrong (wrong Analogue bit numbers, fire/right swapped) while every sim was green.
sim-keys:
	@$(SILICE) scripts/sim_keys.sh

# Four-state DQ contention check under Icarus. The Verilator suite above is two-state
# and cannot see two drivers fighting on a bus, so this one exists to keep that class
# of bug (the 2026-10-12 red-screen suspect) failing in simulation.
sim-iv:
	@$(SILICE) scripts/sim_iv.sh

# Host-reset vs load-path ordering (aw_reset_gen). The OS streams the pack with
# `loadf` while still holding the core in reset - 2026-10-17 proved that gating the
# load path on ~reset_n discards every pack byte, so this keeps it failing in sim.
sim-reset:
	@$(SILICE) scripts/sim_reset.sh

sim-soc:
	@$(SILICE) scripts/sim_soc.sh $(if $(PACK),$(PACK),)

# Whole core_top from power-on: idle screen, pack load over the real bridge window,
# mux switch to game video, host commands, audio pins. The only bench that enforces
# the APF scaler protocol rules on the muxed output from cycle zero (apf_video_check)
# - the gap between "simulation passes" and "device works".
sim-dbg:
	@./docker/run-silice.sh scripts/sim_dbg.sh

sim-top:
	@$(SILICE) scripts/sim_top.sh

# Golden reference: the *upstream* a5k design, unmodified, simulated with one of our
# packs. This is what tells us what a pack is supposed to look like; without it every
# black screen is a mystery instead of an answer. PART=... SECS=... SHOTS=...
ref-setup:
	@SILICE_IMAGE=$(SILICE_IMAGE) ./docker/run-silice.sh scripts/setup_ref.sh

ref-sim:
	@SILICE_IMAGE=$(SILICE_IMAGE) ./docker/run-silice.sh scripts/ref_sim.sh

# sim-dbg used to be missing from this list. Its absence is the reason the boot banner printed
# "AW 1041a up" on builds 1040, 1041 and 1042: the bench that compares that line byte for byte had
# been red for two releases, and a bench nobody runs is a bench nobody fixes.
sim: sim-write sim-keys sim-rom sim-iv sim-reset sim-dbg sim-top sim-audio

# ------------------------------------------------------------------- package --
# The pack .bin files are game content, not build output: they live in
# ports/another-world/packs and must reach Assets/anotherworld/common/ on the
# card or the host has nothing to load into the data slot ("Total loadsize is 0",
# the core sits on a red screen reading back an empty chip - 2026-10-14). Stage
# them into dist/assets, which package_core.py merges into Assets/.
#
# The Chip32 VM loader (cores/<core>/support/loader.asm) is the other half of
# that story: the OS stages the file in host memory, but only the loader's
# `loadf` streams it across the bridge into the FPGA. Without it the load log
# says "Slot: load done" and nothing moves (measured 2026-10-15: wr_match=0).
loader:
	@bash scripts/build_loader.sh $(CORE)

package: loader
	@test -d $(CORE_DIR) || { echo "no such core: $(CORE_DIR)"; exit 1; }
	@if [ -d ports/another-world/packs ]; then \
	 mkdir -p $(CORE_DIR)/dist/assets/anotherworld/common && \
	 cp -f ports/another-world/packs/part*.bin $(CORE_DIR)/dist/assets/anotherworld/common/; \
	fi
	@bit=$(BUILD)/bitstream.rbf_r; \
	 test -f "$$bit" || { echo "$$bit missing - run make build first"; exit 1; }; \
	 $(PY) scripts/package_core.py --core-dir $(CORE_DIR) --bitstream "$$bit" \
		--out $(SD) $(if $(RELEASE),--release,) --zip

test:
	@$(MAKE) --no-print-directory image
	@$(MAKE) --no-print-directory doctor
	@$(MAKE) --no-print-directory build CORE=core-template
	@$(MAKE) --no-print-directory package CORE=core-template RELEASE=1

# ------------------------------------------------------------------------ new --
new:
	@test -n "$(CORE)" || { echo "usage: make new CORE=mygame AUTHOR=me [PLATFORM=nes]"; exit 1; }
	@./scripts/new_core.sh $(CORE) --author $(or $(AUTHOR),author) \
		$(if $(PLATFORM),--platform $(PLATFORM),) \
		$(if $(TITLE),--title "$(TITLE)",) \
		$(if $(YEAR),--year $(YEAR),) \
		$(if $(MANUFACTURER),--manufacturer "$(MANUFACTURER)",)

# --------------------------------------------------------------------- info --
list:
	@for d in cores/*/; do \
		c=$$(basename $$d); \
		q=$$(ls $$d/src/fpga/*.qpf $$d/*.qpf 2>/dev/null | head -1); \
		dev=""; [ -n "$$q" ] && dev=$$(sed -n 's/.*-name DEVICE  *\([^ ]*\).*/\1/p' \
			"$${q%.qpf}.qsf" 2>/dev/null | head -1); \
		printf '%-24s %s\n' "$$c" "$${q:-<no quartus project>} $${dev:+[$$dev]}"; \
	done

size:
	@du -sh build/* 2>/dev/null || echo "nothing built yet"
	@du -sh $$PWD/cores/*/src/fpga/db 2>/dev/null | grep -v 'No such' || true

clean:
	@test -d $(CORE_DIR) || exit 0
	rm -rf $(CORE_DIR)/src/fpga/db $(CORE_DIR)/src/fpga/incremental_db \
		$(CORE_DIR)/src/fpga/greybox_tmp $(CORE_DIR)/src/fpga/c5_pin_model_dump.txt
	rm -f $(CORE_DIR)/src/fpga/output_files/*.rbf $(CORE_DIR)/src/fpga/output_files/*.sof
	rm -rf $(BUILD)
	@echo "cleaned $(CORE_DIR) and $(BUILD)"

distclean:
	rm -rf build
	rm -f $(CORE_DIR)/src/fpga/*.ap-tool-bak
	@find cores -name '*.ap-tool-bak' -delete 2>/dev/null || true
	@echo "removed all build output"

prune:
	@echo "removing leftover build containers/images (keeps $(IMAGE))"
	@docker ps -aq --filter label=ap-tool=1 | xargs -r docker rm -f
	@docker image prune -f >/dev/null && echo "pruned dangling images"

# ------------------------------------------------ Another World (a5k) port --
# Silice is a different toolchain in a different image: a5k is written in .si,
# translated to Verilog, and only then does the Quartus flow above consume it.
# Everything runs through docker/run-silice.sh, which maps your uid so the
# generated BUILD_* trees stay deletable by you (a bare `docker run` leaves
# them root:root 755 and you need sudo to clean them up).

silice-image:
	docker build -f docker/Dockerfile.silice -t $(SILICE_IMAGE) .

silice-shell:
	@SILICE_IMAGE=$(SILICE_IMAGE) ./docker/run-silice.sh

silice:
	@test -n "$(CMD)" || { echo "usage: make silice CMD='silice --help'"; exit 1; }
	@SILICE_IMAGE=$(SILICE_IMAGE) ./docker/run-silice.sh $(CMD)

# regenerate upstream/hardware/BUILD_probe/build.v (gitignored output)
a5k-translate:
	@SILICE_IMAGE=$(SILICE_IMAGE) ./docker/run-silice.sh scripts/a5k_translate.sh

# Our SoC top + upstream vm.si -> cores/aw/src/fpga/core/aw_pocket_build.v, the file
# Quartus consumes. It is generated and gitignored: a fresh clone needs this before
# `make build`, and it needs the pinned upstream tree (make upstream).
pocket-translate:
	@SILICE_IMAGE=$(SILICE_IMAGE) ./docker/run-silice.sh scripts/pocket_translate.sh

# upstream a5k at the commit pinned in $(AW)/UPSTREAM_PIN; needs network
upstream:
	@./$(AW)/fetch_upstream.sh

# The user's own licensed gamedata/ -> ports/another-world/packs/partN.bin (gitignored, never
# committed). N is the extractor index, so part1.bin is the intro - the same N as upstream's
# `make simulN`. extract_packs.sh has advertised this target in its usage line since it was
# written, but no such rule existed: following the script's own help gave
# "make: *** No rule to make target 'packs'".
packs:
	@./docker/run-extract.sh scripts/extract_packs.sh

# feasibility probes expect to run inside the Quartus container:
#   make probe SCRIPT=probe/pll/run.sh
probe:
	@test -n "$(SCRIPT)" || { echo "usage: make probe SCRIPT=probe/pll/run.sh"; \
		echo "available:"; ls $(AW)/probe/*/*.sh 2>/dev/null | sed 's|$(AW)/||'; exit 1; }
	@t=$(AW)/$(SCRIPT); test -f "$$t" || { echo "no such probe: $$t"; exit 1; }; \
	 echo "[probe] $$t - inside the Quartus container; some run for many minutes"; \
	 $(AP) "$$t"
