#!/bin/sh
# devices-test.sh: 10-devices.sh against real block devices (loop devices), in a
# --privileged container (test/run-tests.sh starts it). Builds a "victim" disk (FAT32 camera
# card + ext4 Linux root) and a fake retro-backup stick (RETROBOOT + RETRODATA), then checks
# that only the victim is mounted, read-only, with the right drivers and os_hint, that the
# block devices are flagged read-only, and that a second run (respawn) keeps the mounts.
set -u
SRC=/src
export RETRO_HOME=$SRC/rootfs/opt/retro
T=$(mktemp -d /tmp/retro-dev.XXXXXX)
RETRO_RUN="$T/run" RETRO_SRC_ROOT="$T/mnt" RETRO_LOG_TTY='' RETRO_CMDLINE=/dev/null RETRO_DISK_PREFIXES=loop
export RETRO_RUN RETRO_SRC_ROOT RETRO_LOG_TTY RETRO_CMDLINE RETRO_DISK_PREFIXES
mkdir -p "$RETRO_RUN"
PASS=0
FAIL=0
LOOPS=
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi; }
cleanup() {
	grep " $T/" /proc/mounts | awk '{ print $2 }' | sort -r | while read -r m; do umount "$m"; done
	for l in $LOOPS; do
		blockdev --setrw "$l" 2>/dev/null
		losetup -d "$l" 2>/dev/null
	done
	rm -rf "$T"
}
trap cleanup EXIT

# attach IMAGE: loop device with partitions; creates the /dev nodes (no udev in a container).
attach() {
	_l=$(losetup -f --show -P "$1") || return 1
	_n=${_l##*/}
	for _p in /sys/block/"$_n"/"$_n"p*; do
		[ -e "$_p/dev" ] || continue
		[ -b "/dev/${_p##*/}" ] || mknod "/dev/${_p##*/}" b "$(cut -d: -f1 "$_p/dev")" "$(cut -d: -f2 "$_p/dev")"
	done
	echo "$_l"
}

printf '\n== devices (loop devices, privileged)\n'
if ! losetup -f >/dev/null 2>&1; then
	echo "  SKIP no loop devices available"
	exit 0
fi
HAVE_VFAT=0
grep -qw vfat /proc/filesystems && HAVE_VFAT=1
truncate -s 128M "$T/victim.img"
printf 'label: dos\n,32M,c\n,48M,83\n,,83\n' | sfdisk -q "$T/victim.img"
V=$(attach "$T/victim.img") || { fail "losetup victim"; exit 1; }
LOOPS="$LOOPS $V"
mkfs.vfat -F 32 -n CAMERA "${V}p1" >/dev/null 2>&1 || fail "mkfs.vfat"
mkfs.ext4 -q -L linuxroot "${V}p2" || fail "mkfs.ext4"
mkfs.ext4 -q -L "Adat lemez" "${V}p3" || fail "mkfs.ext4"
mkdir -p "$T/w"
if [ $HAVE_VFAT = 1 ]; then
	if mount -t vfat -o utf8 "${V}p1" "$T/w"; then
		mkdir -p "$T/w/DCIM/100CANON"
		echo jpeg >"$T/w/DCIM/100CANON/Fotó 1.JPG"
		umount "$T/w"
	else
		fail "populate vfat"
	fi
fi
if mount "${V}p2" "$T/w"; then
	mkdir -p "$T/w/etc" "$T/w/home/anna/Documents"
	echo hi >"$T/w/home/anna/Documents/levél.txt"
	umount "$T/w"
else
	fail "populate ext4"
fi
if mount "${V}p3" "$T/w"; then
	mkdir -p "$T/w/Fotók 2009"
	echo jpeg >"$T/w/Fotók 2009/Balaton.jpg"
	umount "$T/w"
else
	fail "populate ext4 data"
fi
truncate -s 64M "$T/stick.img"
printf 'label: dos\n,16M,c,*\n,,7\n' | sfdisk -q "$T/stick.img"
K=$(attach "$T/stick.img") || { fail "losetup stick"; exit 1; }
LOOPS="$LOOPS $K"
# Loop devices are shared by the whole Docker VM: look at ours only.
RETRO_DISK_PREFIXES="${V##*/} ${K##*/}"
mkfs.vfat -F 32 -n RETROBOOT "${K}p1" >/dev/null 2>&1
if mkfs.exfat -L RETRODATA "${K}p2" >/dev/null 2>&1; then :; else mkfs.vfat -n RETRODATA "${K}p2" >/dev/null 2>&1; fi

sh "$RETRO_HOME/10-devices.sh" >"$T/dev.out" 2>&1
eq "10-devices.sh exit status" "$?" 0
VOL=$RETRO_RUN/volumes.tsv
N=${V##*/}
if [ $HAVE_VFAT = 1 ]; then
	eq "three source volumes" "$(grep -c '' "$VOL")" 3
	eq "FAT32 card line" "$(awk -F '\t' -v d="${V}p1" '$1 == d { print $2, $3, $5, $6 }' "$VOL")" "vfat CAMERA $RETRO_SRC_ROOT/${N}p1 data"
	eq "size_bytes from sysfs" "$(awk -F '\t' -v d="${V}p1" '$1 == d { print $4 }' "$VOL")" 33554432
	eq "FAT card mounted read-only" "$(awk -v m="$RETRO_SRC_ROOT/${N}p1" '$2 == m { split($4, o, ","); print o[1] }' /proc/mounts)" ro
	eq "UTF-8 names on FAT (utf8 option)" "$(ls "$RETRO_SRC_ROOT/${N}p1/DCIM/100CANON")" "Fotó 1.JPG"
else
	echo "  (this kernel has no vfat: the FAT card checks the mount-failure path instead)"
	eq "two source volumes" "$(grep -c '' "$VOL")" 2
	if grep -q "could not mount ${V}p1 (vfat) read-only" "$RETRO_RUN/retro-backup.log"; then ok "mount failure logged"; else fail "mount failure not logged"; fi
	if grep -q "${V}p1 (vfat CAMERA)" "$RETRO_RUN/devices.notes"; then ok "mount failure noted for the UI"; else fail "no note for the UI"; fi
	eq "no empty mountpoint left behind" "$(ls -d "$RETRO_SRC_ROOT/${N}p1" 2>/dev/null)" ""
fi
eq "ext4 root line" "$(awk -F '\t' -v d="${V}p2" '$1 == d { print $2, $3, $5, $6 }' "$VOL")" "ext4 linuxroot $RETRO_SRC_ROOT/${N}p2 linux"
eq "ext4 data line (label with a space)" "$(awk -F '\t' -v d="${V}p3" '$1 == d { print $2, $3, $6 }' "$VOL")" "ext4 Adat lemez data"
eq "size_bytes from sysfs" "$(awk -F '\t' -v d="${V}p2" '$1 == d { print $4 }' "$VOL")" 50331648
eq "UTF-8 names" "$(ls "$RETRO_SRC_ROOT/${N}p3" | grep -v lost+found)" "Fotók 2009"
eq "the stick is never a source" "$(grep -c "${K##*/}" "$VOL")" 0
eq "the stick is recognised" "$(cat "$RETRO_RUN/boot.disks")" "${K##*/}"
eq "ext4 mounted read-only without journal replay" "$(awk -v m="$RETRO_SRC_ROOT/${N}p2" '$2 == m { print ($4 ~ /^ro,/ && $4 ~ /norecovery|noload/) }' /proc/mounts)" 1
eq "partitions flagged read-only in the block layer" "$(blockdev --getro "${V}p2") $(blockdev --getro "${V}p3") $(blockdev --getro "$V")" "1 1 1"
if touch "$RETRO_SRC_ROOT/${N}p2/x" 2>/dev/null; then fail "source is writable"; else ok "writing to a source fails"; fi
if grep -q 'RETROBOOT/RETRODATA), never a source' "$RETRO_RUN/retro-backup.log"; then ok "stick skip logged"; else fail "stick skip not logged"; fi
cp "$VOL" "$T/vol1"
sh "$RETRO_HOME/10-devices.sh" >"$T/dev2.out" 2>&1
eq "second run (respawn) exit status" "$?" 0
if cmp -s "$VOL" "$T/vol1"; then ok "second run: same volumes.tsv"; else fail "second run changed volumes.tsv"; fi
eq "second run keeps the mounts" "$(grep -c 'already mounted' "$RETRO_RUN/retro-backup.log")" "$((HAVE_VFAT + 2))"
eq "mounted once only" "$(grep -c " $RETRO_SRC_ROOT/${N}p2 " /proc/mounts)" 1
sh "$RETRO_HOME/20-scan.sh" >/dev/null 2>&1
W=
[ $HAVE_VFAT = 1 ] && W="${V}p1 B DCIM 1|"
eq "scan of the mounted volumes" "$(cut -f2,3,7,8 "$RETRO_RUN/scan.tsv" | tr '\t' ' ' | tr '\n' '|')" "$W${V}p2 A home/anna 1|${V}p2 A home/anna/Documents 1|${V}p3 B Fotók 2009 1|"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
