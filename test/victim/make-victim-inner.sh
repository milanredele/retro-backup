#!/bin/sh
# shellcheck disable=SC2154  # f, t, s are assigned through eval
# Runs inside the container. Builds a raw disk image with up to four volumes from fixture
# directories, without loop devices: each partition is formatted as a file (NTFS via ntfs-3g
# FUSE, ext3 via mkfs.ext3 -d, FAT32 via mtools) and dd'ed into the disk image.
# Usage: make-victim-inner.sh <fixtures dir> <out.img>
# Fixture subdirectories (any may be missing): xp -> p1 NTFS "SYSTEM", win7 -> p2 NTFS "DATA",
# camera -> p3 FAT32 "CAMERA", linux -> p4 ext3 "linuxroot".
set -eu
FIX=$1; OUT=$2
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

size_mib() { # directory -> MiB needed with headroom (min 32)
    kb=$(du -sk "$1" | cut -f1)
    mib=$(( kb * 3 / 2048 + 24 ))
    [ "$mib" -lt 32 ] && mib=32
    echo "$mib"
}

mk_ntfs() { # dir label out
    truncate -s "$(size_mib "$1")M" "$3"
    mkfs.ntfs -F -q -L "$2" "$3" 2>/dev/null
    mkdir -p "$WORK/mnt"
    ntfs-3g "$3" "$WORK/mnt"
    cp -a "$1"/. "$WORK/mnt"/
    umount "$WORK/mnt"
}
mk_ext3() { # dir label out
    truncate -s "$(size_mib "$1")M" "$3"
    mkfs.ext3 -q -F -L "$2" -d "$1" "$3"
}
mk_fat32() { # dir label out
    mib=$(size_mib "$1"); [ "$mib" -lt 36 ] && mib=36   # FAT32 needs >= ~33 MiB
    truncate -s "${mib}M" "$3"
    mkfs.vfat -F 32 -n "$2" "$3" >/dev/null
    mcopy -i "$3" -s -Q "$1"/* ::/ 2>/dev/null || mcopy -i "$3" -s "$1"/* ::/
}

i=0; parts=""
add_part() { # file type
    i=$((i+1)); eval "P${i}_FILE=\$1; P${i}_TYPE=\$2"; parts="$parts $i"
}
[ -d "$FIX/xp" ]     && { mk_ntfs  "$FIX/xp"     SYSTEM    "$WORK/p_xp.img";     add_part "$WORK/p_xp.img" 07; }
[ -d "$FIX/win7" ]   && { mk_ntfs  "$FIX/win7"   DATA      "$WORK/p_win7.img";   add_part "$WORK/p_win7.img" 07; }
[ -d "$FIX/camera" ] && { mk_fat32 "$FIX/camera" CAMERA    "$WORK/p_cam.img";    add_part "$WORK/p_cam.img" 0c; }
[ -d "$FIX/linux" ]  && { mk_ext3  "$FIX/linux"  linuxroot "$WORK/p_linux.img";  add_part "$WORK/p_linux.img" 83; }
[ -z "$parts" ] && { echo "no fixture subdirectories found in $FIX" >&2; exit 1; }

start=2048; script=""; total=0
for n in $parts; do
    eval "f=\$P${n}_FILE; t=\$P${n}_TYPE"
    sectors=$(( $(stat -c %s "$f") / 512 ))
    script="$script
start=$start, size=$sectors, type=$t"
    eval "P${n}_START=$start"
    start=$(( start + sectors ))
    # keep 1 MiB alignment
    start=$(( (start + 2047) / 2048 * 2048 ))
done
total=$start
rm -f "$OUT"; truncate -s $(( (total + 2048) * 512 )) "$OUT"
printf 'label: dos\nunit: sectors\n%s\n' "$script" | sfdisk -q "$OUT"
for n in $parts; do
    eval "f=\$P${n}_FILE; s=\$P${n}_START"
    dd if="$f" of="$OUT" bs=512 seek="$s" conv=notrunc status=none
done
echo "victim disk: $OUT ($(( total / 2048 )) MiB)"; sfdisk -l "$OUT" | tail -n +8
