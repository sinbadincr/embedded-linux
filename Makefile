# Top-level entry point. The docker-* targets run on the host; every other
# target runs inside the build container (make docker-shell) and is forwarded
# to Buildroot with this repo as BR2_EXTERNAL and output/<board>/ as O=.

ROOT_DIR      := $(CURDIR)
BUILDROOT_DIR := $(ROOT_DIR)/buildroot
DL_DIR        := $(ROOT_DIR)/dl
BOARDS        := $(patsubst configs/%_defconfig,%,$(wildcard configs/*_defconfig))

# BOARD=<name>, written by <board>_defconfig; `make BOARD=x ...` overrides it
-include .current_board

br = $(MAKE) -C $(BUILDROOT_DIR) BR2_EXTERNAL=$(ROOT_DIR) BR2_DL_DIR=$(DL_DIR) \
	O=$(ROOT_DIR)/output/$(1)

USER_ID           := $(shell id -u)
GROUP_ID          := $(shell id -g)
DOCKER_IMAGE_NAME ?= ota-build-env:latest

check_env = @test -f /.dockerenv || { \
		echo "Buildroot targets run in the build container: 'make docker-shell' first." >&2; exit 1; }; \
	test -f $(BUILDROOT_DIR)/Makefile || { \
		echo "No Buildroot tree: 'git submodule update --init' first." >&2; exit 1; }
check_board = @test -n "$(BOARD)" || { \
		echo "No board selected: 'make <board>_defconfig' first (boards: $(BOARDS))." >&2; exit 1; }

.PHONY: help list-boards build check docker-build docker-check docker-shell
.NOTPARALLEL:

help:
	@echo "Host:"
	@echo "  make docker-build         - build the build-environment image ($(DOCKER_IMAGE_NAME))"
	@echo "  make docker-shell         - open a shell in the build container"
	@echo "  make docker-check         - docker-build, then 'make check' in the container (what CI runs)"
	@echo "In the container:"
	@echo "  make <board>_defconfig    - select a board (output in output/<board>/)"
	@echo "  make build                - build the selected board"
	@echo "  make <target>             - any Buildroot target, e.g. menuconfig, linux-menuconfig,"
	@echo "                              savedefconfig, <pkg>-rebuild, clean"
	@echo "  make list-boards          - list boards in configs/"
	@echo "  make check                - static checks: shell lint, defconfig round-trip, image layout"
	@echo "Current board: $(or $(BOARD),<none>)"

list-boards:
	@printf '%s\n' $(BOARDS)

docker-build:
	docker build --build-arg UID=$(USER_ID) --build-arg GID=$(GROUP_ID) -t $(DOCKER_IMAGE_NAME) .

docker-shell:
	docker run --rm -it \
		-v $(ROOT_DIR):/workspace \
		-w /workspace \
		-u $(USER_ID):$(GROUP_ID) \
		$(DOCKER_IMAGE_NAME) /bin/bash

docker-check:
	@command -v docker >/dev/null || { \
		echo "docker not found: install Docker to run 'make docker-check'." >&2; exit 1; }
	$(MAKE) docker-build
	docker run --rm \
		-v $(ROOT_DIR):/workspace \
		-w /workspace \
		-u $(USER_ID):$(GROUP_ID) \
		$(DOCKER_IMAGE_NAME) make check

check:
	$(check_env)
	@sh scripts/check.sh

%_defconfig:
	$(check_env)
	@echo "BOARD=$*" > .current_board
	$(call br,$*) $@

build:
	$(check_env)
	$(check_board)
	$(call br,$(BOARD))

# Keep the catch-all below from trying to remake these
Makefile .current_board: ;

%:
	$(check_env)
	$(check_board)
	$(call br,$(BOARD)) $@
