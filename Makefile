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
#   make package CORE=mygame       -> build/sd/{Cores,Platforms,Assets} + zip
#
# Variables (override on the command line or in config.mk):
#   CORE              core under cores/ to work on        (default core-template)
#   AUTHOR            author id used by 'make new'
#   IMAGE             derived build image tag
#   JOBS              parallelism for Quartus (default: all cpus)
#   QUARTUS_ARGS      extra args handed to 'quartus_sh --flow compile'
#   ALLOW_TIMING_FAIL set to 1 to keep going when STA reports negative slack
# ============================================================================

CORE        ?= core-template
AUTHOR      ?= author
BASE_IMAGE  ?= didiermalenfant/quartus:22.1-apple-silicon
IMAGE       ?= local/ap-pocket:quartus22.1
CORE_DIR    := cores/$(CORE)
BUILD       := build/$(CORE)
OUT_DIR     := /work/build          # same folder, seen from inside the container
SD          := build/sd
-include config.mk

AP       := ./docker/run.sh
PY       ?= python3
CORES    := $(notdir $(wildcard cores/*))

.DEFAULT_GOAL := help
.PHONY: help image pull doctor smoke shell build clean-build rev package test \
        new report list size clean distclean prune

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
	@echo "  make clean [CORE=x]        remove Quartus DBs + build output for a core"
	@echo "  make distclean             remove all build output"
	@echo "  make prune                 docker image/layer cleanup for this project"
	@echo
	@echo "Debugging: make build QUARTUS_ARGS=--effort=standard, JOBS=8,"
	@echo "           ALLOW_TIMING_FAIL=1 to ignore STA failures."

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

# ------------------------------------------------------------------- package --
package:
	@test -d $(CORE_DIR) || { echo "no such core: $(CORE_DIR)"; exit 1; }
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
