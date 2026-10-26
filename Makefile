# retro-backup build pipeline. See PLAN.md section 7 and CONTRACTS.md.
# Docker steps run as root in a linux/amd64 Debian container with the repo mounted at /src.

IMAGE    ?= retro-backup-builder
PLATFORM ?= linux/amd64
DOCKER   ?= docker
DRUN      = $(DOCKER) run --rm --platform $(PLATFORM) --user 0:0 -v "$(CURDIR)":/src -w /src $(IMAGE)

.PHONY: all builder fetch remaster image test-qemu clean

all: fetch remaster image

builder:
	$(DOCKER) build --platform $(PLATFORM) -t $(IMAGE) build/

# Plain sh + curl; runs on the host (macOS or Linux).
fetch:
	sh build/fetch.sh

remaster: builder
	$(DRUN) sh build/remaster.sh

image: builder
	$(DRUN) sh build/image.sh

test-qemu:
	sh build/test-qemu.sh $(QEMU_ARGS)

clean:
	rm -rf out/retro.gz out/retro.gz.tmp out/vmlinuz out/retro-backup.img out/retro.iso out/test-qemu.log

# ---- helper (Go PXE server + receiver) -------------------------------------------------
# Copies the boot payload into helper/bootfiles/ (embedded by go:embed) and cross-compiles.
HELPER_BOOT = helper/bootfiles

.PHONY: helper-bootfiles helper test victim

helper-bootfiles: builder
	@test -f out/vmlinuz -a -f out/retro.gz || { echo "run 'make all' first (out/vmlinuz, out/retro.gz missing)"; exit 1; }
	mkdir -p $(HELPER_BOOT)
	cp out/vmlinuz out/retro.gz $(HELPER_BOOT)/
	$(DRUN) sh -c 'cp /usr/lib/PXELINUX/lpxelinux.0 /usr/lib/PXELINUX/pxelinux.0 $(HELPER_BOOT)/ && cp /usr/lib/syslinux/modules/bios/ldlinux.c32 /usr/lib/syslinux/modules/bios/libcom32.c32 /usr/lib/syslinux/modules/bios/libutil.c32 /usr/lib/syslinux/modules/bios/menu.c32 $(HELPER_BOOT)/'
	ls -la $(HELPER_BOOT)

helper: helper-bootfiles
	cd helper && ./build-all.sh

# Host-side tests that need neither QEMU nor x86 emulation.
test:
	cd helper && go vet ./... && go test ./...
	sh test/run-tests.sh

# Victim disk for the end-to-end QEMU run (needs Docker with /dev/fuse).
victim:
	rm -rf out/fixtures && mkdir -p out/fixtures
	$(DOCKER) build -q -t retro-client-test -f test/Dockerfile.client test >/dev/null
	$(DOCKER) run --rm -v "$(CURDIR)/test:/t:ro" -v "$(CURDIR)/out/fixtures:/fix" retro-client-test sh /t/fixtures/make-fixtures.sh /fix > out/fixtures-expect.txt
	sh test/victim/make-victim.sh out/fixtures out/victim.img

test-e2e:
	sh test/e2e-qemu.sh $(QEMU_ARGS)

# Screenshots of the UI on the VESA console (QEMU, out/shot-*.png).
screenshot:
	sh test/screenshot-qemu.sh $(QEMU_ARGS)

# Walk through the UI in QEMU and save the README screenshots (docs/screenshots/).
screenshot-tour:
	sh test/screenshot-tour.sh
