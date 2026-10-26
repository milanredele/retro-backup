#!/bin/sh
# 05-stick.sh: first-boot growth of the RETRODATA partition to the end of the pendrive.
# The image is 1 GiB; a stick is usually much bigger. When partition 2 of the disk that
# carries RETROBOOT is still followed by unpartitioned space and the exFAT volume on it holds
# nothing but operating-system droppings (macOS .fseventsd/.Spotlight-V100/.Trashes, Windows
# System Volume Information, ...), grow the partition with sfdisk and re-create the filesystem.
# With --force the content check is skipped (the UI asks the user first). Nothing happens when
# the partition already fills the stick or with retro.nogrow=1 on the kernel command line.
# Exit status is 0 in every case; the outcome goes to the log and to $RETRO_RUN/stick.status:
#   grown OLD_MIB NEW_MIB | full | skipped-data PART_MIB DISK_MIB ENTRIES | skipped-mounted |
#   error TEXT | disabled | none
# shellcheck source=lib/common.sh
. "${RETRO_HOME:-/opt/retro}/lib/common.sh"

SYS=${RETRO_SYS:-/sys}
MIN_FREE_SECTORS=131072 # 64 MiB: below that growing is not worth a reformat
FORCE=0
[ "${1:-}" = --force ] && FORCE=1
STATUS=$RETRO_RUN/stick.status

status() {
	printf '%s\n' "$*" >"$STATUS"
}

# ignorable NAME: entries an OS creates on its own when it mounts a blank volume.
ignorable() {
	case $1 in
	"System Volume Information" | "\$RECYCLE.BIN" | desktop.ini | Thumbs.db | autorun.inf) return 0 ;;
	.fseventsd | .Spotlight-V100 | .Trashes | .TemporaryItems | .DS_Store | .VolumeIcon.icns | ._*) return 0 ;;
	.Trash-* | lost+found | .metadata_never_index | .apdisk) return 0 ;;
	esac
	return 1
}

mkdir -p "$RETRO_RUN"
if [ "$(retro_param retro.nogrow 0)" = 1 ]; then
	log INFO "stick: growth disabled (retro.nogrow)"
	status disabled
	exit 0
fi
if ! command -v sfdisk >/dev/null 2>&1 || ! command -v mkfs.exfat >/dev/null 2>&1; then
	log WARN "stick: sfdisk or mkfs.exfat missing, not growing"
	status "error sfdisk or mkfs.exfat missing"
	exit 0
fi

P2=$(blkid -L RETRODATA 2>/dev/null) || P2=
P1=$(blkid -L RETROBOOT 2>/dev/null) || P1=
if [ -z "$P2" ] || [ -z "$P1" ]; then
	log DEBUG "stick: RETROBOOT/RETRODATA not found, nothing to grow"
	status none
	exit 0
fi
n2=${P2#/dev/}
n1=${P1#/dev/}
disk2=$(basename "$(readlink -f "$SYS/class/block/$n2/..")")
disk1=$(basename "$(readlink -f "$SYS/class/block/$n1/..")")
if [ "$disk1" != "$disk2" ]; then
	log WARN "stick: RETROBOOT ($P1) and RETRODATA ($P2) on different disks, not growing"
	status "error RETROBOOT and RETRODATA are on different disks"
	exit 0
fi
if [ "$(cat "$SYS/class/block/$n2/partition" 2>/dev/null)" != 2 ]; then
	log WARN "stick: $P2 is not partition 2, not growing"
	status "error $P2 is not partition 2"
	exit 0
fi
DISK=/dev/$disk2
disk_sectors=$(cat "$SYS/block/$disk2/size")
part_start=$(cat "$SYS/class/block/$n2/start")
before=$(cat "$SYS/class/block/$n2/size")
free=$(awk -v d="$disk_sectors" -v s="$part_start" -v z="$before" 'BEGIN { printf "%d", d - s - z }')
part_mib=$((before / 2048))
disk_mib=$(awk -v d="$disk_sectors" 'BEGIN { printf "%d", d / 2048 }')
if [ "$free" -lt "$MIN_FREE_SECTORS" ]; then
	log DEBUG "stick: RETRODATA already fills $DISK (free sectors: $free)"
	status full
	exit 0
fi
if grep -q "^$P1 \|^$P2 " /proc/mounts; then
	log WARN "stick: $P1 or $P2 is mounted, not growing"
	status skipped-mounted
	exit 0
fi

if [ "$FORCE" = 0 ]; then
	# Only a volume without user data is reformatted; OS droppings do not count.
	M=$RETRO_RUN/stick.mnt
	mkdir -p "$M"
	if ! mount -t exfat -o ro "$P2" "$M" 2>/dev/null; then
		log WARN "stick: cannot mount $P2 to check its content, not growing"
		status "error cannot mount $P2 to check its content"
		exit 0
	fi
	entries=
	ignored=
	n=0
	for _e in "$M"/* "$M"/.[!.]* "$M"/..?*; do
		[ -e "$_e" ] || continue
		_b=$(basename "$_e")
		if ignorable "$_b"; then
			ignored="${ignored:+$ignored, }$_b"
			continue
		fi
		n=$((n + 1))
		[ $n -le 5 ] && entries="${entries:+$entries,}$_b"
	done
	umount "$M"
	log INFO "stick: content check of $P2: $n user entries, OS entries ignored: ${ignored:-none}"
	if [ "$n" -gt 0 ]; then
		log WARN "stick: RETRODATA ($part_mib MiB of $disk_mib MiB) holds data ($entries), not growing; the UI offers to extend it"
		status "skipped-data $part_mib $disk_mib $entries"
		exit 0
	fi
fi

log INFO "stick: growing RETRODATA on $DISK from $part_mib MiB towards $disk_mib MiB$([ "$FORCE" = 1 ] && echo " (forced)")"
if ! echo ', +' | sfdisk -q --no-reread -N 2 "$DISK" 2>>"$RETRO_LOG"; then
	log ERROR "stick: sfdisk failed, RETRODATA unchanged"
	status "error sfdisk failed"
	exit 0
fi
partx -u "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null
after=$(cat "$SYS/class/block/$n2/size")
if [ "$after" -le "$before" ]; then
	log ERROR "stick: kernel still sees the old size of $P2 ($after sectors); reboot and retry"
	status "error the kernel did not pick up the new partition size; reboot and retry"
	exit 0
fi
if ! mkfs.exfat -n RETRODATA "$P2" >>"$RETRO_LOG" 2>&1; then
	log ERROR "stick: mkfs.exfat failed on $P2 after growing; run mkfs.exfat -n RETRODATA $P2 from the shell"
	status "error mkfs.exfat failed after growing"
	exit 0
fi
sync
log INFO "stick: RETRODATA is now $((after / 2048)) MiB (was $part_mib MiB)"
status "grown $part_mib $((after / 2048))"
exit 0
