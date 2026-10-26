#!/bin/sh
# dirty-stick.sh - put the files macOS and Windows drop onto a freshly mounted exFAT volume into
# the RETRODATA partition of a stick image (host side, Docker with /dev/fuse). Used by the
# end-to-end test to prove the first-boot growth still happens after the stick was plugged into a
# Mac or a Windows PC between flashing and booting.
#   test/victim/dirty-stick.sh <stick.img>
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
docker build -q -t retro-backup-victim "$HERE" >/dev/null
docker run --rm --privileged -v "$(dirname "$IMG"):/w" --entrypoint sh retro-backup-victim -c '
set -e
IMG=/w/'"$(basename "$IMG")"'
# partition 2 offset from the MBR table
START=$(sfdisk -d "$IMG" | awk "/img2 :/ { for (i=1;i<=NF;i++) if (\$i==\"start=\") { sub(\",\",\"\",\$(i+1)); print \$(i+1) } }")
[ -n "$START" ] || { echo "no partition 2 in $IMG" >&2; exit 1; }
SIZE=$(sfdisk -d "$IMG" | awk "/img2 :/ { for (i=1;i<=NF;i++) if (\$i==\"size=\") { sub(\",\",\"\",\$(i+1)); print \$(i+1) } }")
# fuse-exfat wants a block device and has no offset option: a loop device over partition 2
LOOP=$(losetup -f --show -o $((START * 512)) --sizelimit $((SIZE * 512)) "$IMG")
mkdir -p /m
mount.exfat-fuse "$LOOP" /m
mkdir -p "/m/.fseventsd" "/m/.Spotlight-V100/Store-V2" "/m/.Trashes" "/m/System Volume Information"
echo x > /m/.fseventsd/fseventsd-uuid
echo x > "/m/.Spotlight-V100/Store-V2/index"
echo x > "/m/System Volume Information/IndexerVolumeGuid"
echo x > /m/._.Trashes
ls -A /m
umount /m
losetup -d "$LOOP"
'
