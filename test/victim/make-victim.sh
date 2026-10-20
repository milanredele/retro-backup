#!/bin/sh
# Host-side wrapper: builds the victim disk image used by build/test-qemu.sh.
# Usage: test/victim/make-victim.sh <fixtures dir> <out.img>
# The fixtures dir holds plain directory trees named xp, win7, camera, linux (see
# test/fixtures/make-fixtures.sh). Needs Docker with /dev/fuse (Docker Desktop is fine).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIX=$(cd "$1" && pwd); OUT=$2
OUTDIR=$(cd "$(dirname "$OUT")" && pwd); OUTNAME=$(basename "$OUT")
docker build -q -t retro-backup-victim "$HERE" >/dev/null
docker run --rm --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor:unconfined \
    -v "$FIX:/fix:ro" -v "$OUTDIR:/out" retro-backup-victim /fix "/out/$OUTNAME"
