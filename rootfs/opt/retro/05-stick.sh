#!/bin/sh
# 05-stick.sh: first-boot growth of the RETRODATA partition to the end of the pendrive.
# The image is 1 GiB; a stick is usually much bigger. When partition 2 of the disk that
# carries RETROBOOT is still followed by unpartitioned space and the exFAT volume on it is
# empty, grow the partition with sfdisk and re-create the filesystem. Nothing happens when the
# partition already fills the stick, when it holds data, or with retro.nogrow=1 on the kernel
# command line. Exit status is 0 in every case; problems are logged. Never touches any other disk.
# shellcheck source=lib/common.sh
. "${RETRO_HOME:-/opt/retro}/lib/common.sh"

SYS=${RETRO_SYS:-/sys}
MIN_FREE_SECTORS=131072 # 64 MiB: below that growing is not worth a reformat

[ "$(retro_param retro.nogrow 0)" = 1 ] && { log INFO "stick: growth disabled (retro.nogrow)"; exit 0; }
if ! command -v sfdisk >/dev/null 2>&1 || ! command -v mkfs.exfat >/dev/null 2>&1; then
	log WARN "stick: sfdisk or mkfs.exfat missing, not growing"
	exit 0
fi

P2=$(blkid -L RETRODATA 2>/dev/null) || P2=
P1=$(blkid -L RETROBOOT 2>/dev/null) || P1=
if [ -z "$P2" ] || [ -z "$P1" ]; then
	log DEBUG "stick: RETROBOOT/RETRODATA not found, nothing to grow"
	exit 0
fi
n2=${P2#/dev/}; n1=${P1#/dev/}
disk2=$(basename "$(readlink -f "$SYS/class/block/$n2/..")")
disk1=$(basename "$(readlink -f "$SYS/class/block/$n1/..")")
[ "$disk1" = "$disk2" ] || { log WARN "stick: RETROBOOT ($P1) and RETRODATA ($P2) on different disks, not growing"; exit 0; }
[ "$(cat "$SYS/class/block/$n2/partition" 2>/dev/null)" = 2 ] || { log WARN "stick: $P2 is not partition 2, not growing"; exit 0; }
DISK=/dev/$disk2
free=$(awk -v d="$(cat "$SYS/block/$disk2/size")" -v s="$(cat "$SYS/class/block/$n2/start")" -v z="$(cat "$SYS/class/block/$n2/size")" 'BEGIN { printf "%d", d - s - z }')
if [ "$free" -lt "$MIN_FREE_SECTORS" ]; then
	log DEBUG "stick: RETRODATA already fills $DISK (free sectors: $free)"
	exit 0
fi
if grep -q "^$P1 \|^$P2 " /proc/mounts; then
	log WARN "stick: $P1 or $P2 is mounted, not growing"
	exit 0
fi
# Only an empty volume is reformatted (Windows may have added "System Volume Information").
M=$RETRO_RUN/stick.mnt
mkdir -p "$M"
if ! mount -t exfat -o ro "$P2" "$M" 2>/dev/null; then
	log WARN "stick: cannot mount $P2 to check that it is empty, not growing"
	exit 0
fi
entries=
for _e in "$M"/* "$M"/.[!.]* "$M"/..?*; do
	[ -e "$_e" ] || continue
	[ "$(basename "$_e")" = "System Volume Information" ] && continue
	entries=$(basename "$_e")
	break
done
umount "$M"
if [ -n "$entries" ]; then
	log WARN "stick: RETRODATA holds data ($entries), not growing; back it up and reformat to use the whole stick"
	exit 0
fi
before=$(cat "$SYS/class/block/$n2/size")
log INFO "stick: growing RETRODATA on $DISK by $(human_bytes $((free * 512)) 2>/dev/null || echo "$free sectors")"
if ! echo ', +' | sfdisk -q --no-reread -N 2 "$DISK" 2>>"$RETRO_LOG"; then
	log ERROR "stick: sfdisk failed, RETRODATA unchanged"
	exit 0
fi
partx -u "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null
after=$(cat "$SYS/class/block/$n2/size")
if [ "$after" -le "$before" ]; then
	log ERROR "stick: kernel still sees the old size of $P2 ($after sectors); reboot and retry"
	exit 0
fi
if ! mkfs.exfat -n RETRODATA "$P2" >>"$RETRO_LOG" 2>&1; then
	log ERROR "stick: mkfs.exfat failed on $P2 after growing; run mkfs.exfat -n RETRODATA $P2 from the shell"
	exit 0
fi
sync
log INFO "stick: RETRODATA is now $((after / 2048)) MiB (was $((before / 2048)) MiB)"
exit 0
