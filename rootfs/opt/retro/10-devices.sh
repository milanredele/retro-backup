#!/bin/sh
# 10-devices.sh: find the internal disks, leave the boot stick alone, assemble md RAID and
# LVM, mount every file system read-only under $RETRO_SRC_ROOT and write volumes.tsv
# (CONTRACTS.md section 2). Never runs fsck, never mounts anything read-write; source block
# devices are additionally flagged read-only with blockdev --setro before mounting.
# Also writes smart.tsv (dev, PASSED|FAILED|unknown) and devices.notes (lines for the UI).
# Safe to run again: volumes that are already mounted are kept.
# shellcheck source=lib/common.sh
. "${RETRO_HOME:-/opt/retro}/lib/common.sh"

SYS_BLOCK=${RETRO_SYS_BLOCK:-/sys/block}
NOTES=$RETRO_RUN/devices.notes

note() {
	printf '%s\n' "$*" >>"$NOTES"
}

# blk_value DEV TAG: blkid tag value (TYPE, LABEL) without using the blkid cache.
blk_value() {
	blkid -c /dev/null -o value -s "$2" "$1" 2>/dev/null | head -n 1
}

# disk_names: candidate whole disks, names starting with RETRO_DISK_PREFIXES (default
# "sd hd nvme mmcblk vd"), sorted. The tests use "loop".
disk_names() {
	for _pre in ${RETRO_DISK_PREFIXES:-sd hd nvme mmcblk vd}; do
		for _d in "$SYS_BLOCK/$_pre"*; do
			[ -e "$_d" ] && printf '%s\n' "$_d"
		done
	done | while IFS= read -r _d; do
		_n=${_d##*/}
		case $_n in
		mmcblk*boot* | mmcblk*rpmb) continue ;;
		esac
		printf '%s\n' "$_n"
	done | LC_ALL=C sort
}

# is_optical DISK: removable optical drive (SCSI type 5 or IDE media cdrom).
is_optical() {
	[ "$(cat "$SYS_BLOCK/$1/device/type" 2>/dev/null)" = 5 ] && return 0
	[ "$(cat "$SYS_BLOCK/$1/device/media" 2>/dev/null)" = cdrom ] && return 0
	return 1
}

# parts_of DISK: partition names of DISK, or DISK itself when it has no partition table
# (superfloppy: cameras, some USB sticks).
parts_of() {
	for _p in "$SYS_BLOCK/$1/$1"*; do
		[ -f "$_p/partition" ] || continue
		printf '%s\n' "${_p##*/}"
		_found=1
	done | LC_ALL=C sort >"$RETRO_RUN/parts.$$"
	if [ -s "$RETRO_RUN/parts.$$" ]; then
		cat "$RETRO_RUN/parts.$$"
	else
		printf '%s\n' "$1"
	fi
	rm -f "$RETRO_RUN/parts.$$"
}

# is_boot_disk DISK: DISK holds a RETROBOOT or RETRODATA file system (our own stick).
is_boot_disk() {
	for _bp in $(parts_of "$1"); do
		case $(blk_value "/dev/$_bp" LABEL) in
		RETROBOOT | RETRODATA) return 0 ;;
		esac
	done
	return 1
}

# mounted_at MP: print the file system type mounted at MP, fail if nothing is.
mounted_at() {
	awk -v m="$1" '$2 == m { t = $3 } END { if (t == "") exit 1; print t }' /proc/mounts
}

# set_ro DEV: ask the block layer to refuse writes to DEV.
set_ro() {
	have blockdev && blockdev --setro "$1" 2>/dev/null
	return 0
}

# mount_ro DEV TYPE MP: mount read-only with the right driver; prints the driver used.
mount_ro() {
	_dev=$1 _t=$2 _mp=$3
	case $_t in
	ntfs)
		if mount -t ntfs3 -o ro,iocharset=utf8 "$_dev" "$_mp" 2>>"$RETRO_RUN/mount.err"; then
			echo ntfs3
			return 0
		fi
		log WARN "devices: ntfs3 refused $_dev (dirty or hibernated?), trying ntfs-3g read-only"
		if have ntfs-3g && ntfs-3g -o ro "$_dev" "$_mp" 2>>"$RETRO_RUN/mount.err"; then
			echo ntfs-3g
			return 0
		fi
		;;
	vfat | msdos)
		mount -t vfat -o ro,utf8,shortname=mixed "$_dev" "$_mp" 2>>"$RETRO_RUN/mount.err" &&
			{ echo vfat; return 0; }
		;;
	exfat)
		mount -t exfat -o ro,iocharset=utf8 "$_dev" "$_mp" 2>>"$RETRO_RUN/mount.err" &&
			{ echo exfat; return 0; }
		;;
	ext3 | ext4)
		# noload: do not replay the journal (that would write to the disk).
		mount -t "$_t" -o ro,noload "$_dev" "$_mp" 2>>"$RETRO_RUN/mount.err" &&
			{ echo "$_t"; return 0; }
		;;
	xfs)
		mount -t xfs -o ro,norecovery "$_dev" "$_mp" 2>>"$RETRO_RUN/mount.err" &&
			{ echo xfs; return 0; }
		;;
	btrfs)
		mount -t btrfs -o ro,rescue=nologreplay "$_dev" "$_mp" 2>>"$RETRO_RUN/mount.err" &&
			{ echo btrfs; return 0; }
		;;
	*)
		mount -t "$_t" -o ro "$_dev" "$_mp" 2>>"$RETRO_RUN/mount.err" &&
			{ echo "$_t"; return 0; }
		;;
	esac
	return 1
}

# try_volume DEV NAME: probe one block device and mount it; appends to volumes.tsv.tmp.
try_volume() {
	_dev=$1 _name=$2
	[ -b "$_dev" ] || { log DEBUG "devices: $_dev is not a block device"; return 0; }
	_type=$(blk_value "$_dev" TYPE)
	_label=$(blk_value "$_dev" LABEL)
	case $_type in
	"")
		log INFO "devices: $_dev: no file system, skipped"
		return 0
		;;
	swap | linux_raid_member | LVM2_member | ddf_raid_member | isw_raid_member | \
		promise_fasttrack_raid_member | silicon_medley_raid_member | nvidia_raid_member)
		log INFO "devices: $_dev: $_type, not a file system, skipped"
		return 0
		;;
	crypto_LUKS | BitLocker)
		log WARN "devices: $_dev: encrypted ($_type), cannot be read, skipped"
		note "$_dev ($_label): $T_DEV_ENCRYPTED ($_type)"
		return 0
		;;
	esac
	case $_label in
	RETROBOOT | RETRODATA)
		log INFO "devices: $_dev: our own $_label partition, skipped"
		return 0
		;;
	esac
	_mp=$RETRO_SRC_ROOT/$_name
	if _drv=$(mounted_at "$_mp"); then
		log INFO "devices: $_dev already mounted at $_mp ($_drv), kept"
	else
		mkdir -p "$_mp"
		set_ro "$_dev"
		if _drv=$(mount_ro "$_dev" "$_type" "$_mp"); then
			log INFO "devices: mounted $_dev ($_type, label '${_label:-}') read-only at $_mp with $_drv"
		else
			log ERROR "devices: could not mount $_dev ($_type) read-only: $(tail -n 1 "$RETRO_RUN/mount.err" 2>/dev/null)"
			note "$_dev ($_type ${_label:-}): $T_DEV_MOUNT_FAILED"
			rmdir "$_mp" 2>/dev/null
			return 0
		fi
	fi
	_bytes=$(awk '{ printf "%.0f", $1 * 512 }' "/sys/class/block/${_dev##*/}/size" 2>/dev/null)
	[ -n "$_bytes" ] || _bytes=0
	_os=$(detect_os_hint "$_mp")
	log INFO "devices: $_dev os_hint=$_os"
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_dev" "$_drv" "$(tsv_clean "$_label")" "$_bytes" "$_mp" \
		"$_os" >>"$RETRO_RUN/volumes.tsv.tmp"
}

# smart_check DISK: smartctl -H, warn on failure, record the result.
smart_check() {
	have smartctl || return 0
	_out=$(smartctl -H "/dev/$1" 2>&1)
	_rc=$?
	if printf '%s' "$_out" | grep -q -i -e 'FAILED' -e 'FAILING' || [ $((_rc & 8)) -ne 0 ]; then
		log WARN "devices: SMART health check FAILED on /dev/$1: the disk may be dying, copy the most important data first"
		note "/dev/$1: $T_DEV_SMART_FAILED"
		printf '%s\tFAILED\n' "/dev/$1" >>"$RETRO_RUN/smart.tsv"
	elif printf '%s' "$_out" | grep -q -e PASSED -e 'Health Status: OK'; then
		log INFO "devices: SMART health of /dev/$1: PASSED"
		printf '%s\tPASSED\n' "/dev/$1" >>"$RETRO_RUN/smart.tsv"
	else
		log INFO "devices: SMART health of /dev/$1: not available"
		printf '%s\tunknown\n' "/dev/$1" >>"$RETRO_RUN/smart.tsv"
	fi
}

devices_main() {
	mkdir -p "$RETRO_SRC_ROOT" || die "cannot create $RETRO_SRC_ROOT"
	: >"$RETRO_RUN/volumes.tsv.tmp"
	: >"$RETRO_RUN/smart.tsv"
	: >"$NOTES"
	: >"$RETRO_RUN/boot.disks"
	log INFO "devices: start"
	have modprobe && for _m in ntfs3 exfat vfat reiserfs xfs jfs hfsplus hfs btrfs; do
		modprobe -q "$_m" 2>/dev/null
	done
	# Whole disks first: decide which are ours, flag the others read-only.
	for _disk in $(disk_names); do
		if [ "$(cat "$SYS_BLOCK/$_disk/size" 2>/dev/null || echo 0)" = 0 ]; then
			log INFO "devices: /dev/$_disk: no medium, skipped"
			continue
		fi
		if is_optical "$_disk"; then
			log INFO "devices: /dev/$_disk: optical drive, skipped"
			continue
		fi
		if is_boot_disk "$_disk"; then
			log INFO "devices: /dev/$_disk: the retro-backup stick (RETROBOOT/RETRODATA), never a source"
			printf '%s\n' "$_disk" >>"$RETRO_RUN/boot.disks"
			continue
		fi
		printf '%s\n' "$_disk" >>"$RETRO_RUN/volumes.disks.$$"
		set_ro "/dev/$_disk"
		smart_check "$_disk"
	done
	touch "$RETRO_RUN/volumes.disks.$$"
	# RAID and LVM on top of the source disks.
	if have mdadm; then
		log INFO "devices: mdadm --assemble --scan --readonly"
		mdadm --assemble --scan --readonly >>"$RETRO_RUN/mount.err" 2>&1 ||
			log DEBUG "devices: mdadm found nothing to assemble"
	fi
	if have vgchange; then
		log INFO "devices: vgchange -ay"
		vgchange -ay >>"$RETRO_RUN/mount.err" 2>&1 || log DEBUG "devices: vgchange found no volume groups"
	fi
	while IFS= read -r _disk; do
		for _part in $(parts_of "$_disk"); do
			try_volume "/dev/$_part" "$_part"
		done
	done <"$RETRO_RUN/volumes.disks.$$"
	rm -f "$RETRO_RUN/volumes.disks.$$"
	for _md in "$SYS_BLOCK"/md*; do
		[ -e "$_md" ] || continue
		_md=${_md##*/}
		set_ro "/dev/$_md"
		for _part in $(parts_of "$_md"); do
			try_volume "/dev/$_part" "$_part"
		done
	done
	for _dm in "$SYS_BLOCK"/dm-*; do
		[ -e "$_dm/dm/name" ] || continue
		_dmname=$(cat "$_dm/dm/name")
		case $(cat "$_dm/dm/uuid" 2>/dev/null) in
		LVM-*) ;;
		*) continue ;;
		esac
		set_ro "/dev/mapper/$_dmname"
		try_volume "/dev/mapper/$_dmname" "$_dmname"
	done
	mv -f "$RETRO_RUN/volumes.tsv.tmp" "$RETRO_RUN/volumes.tsv"
	log INFO "devices: $(grep -c '' "$RETRO_RUN/volumes.tsv") source volumes mounted read-only"
	return 0
}

# Run only when executed, not when sourced by another script or a test.
case ${0##*/} in
10-devices.sh) devices_main "$@" ;;
esac
