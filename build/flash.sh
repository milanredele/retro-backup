#!/bin/sh
# flash.sh - write out/retro-backup.img to a USB stick (host side, macOS or Linux).
#
#   build/flash.sh /dev/diskN        (macOS; the whole disk, not diskNsM)
#   build/flash.sh /dev/sdX          (Linux; the whole disk, not sdX1)
#   IMG=path/to/other.img build/flash.sh /dev/...
#
# Shows the device name and size and asks for confirmation. Refuses the system disk, internal
# disks on macOS, and devices larger than 2 TB. On Linux the RETRODATA partition (p2) is then
# grown to the end of the stick (sfdisk + mkfs.exfat; it is empty at this point). On macOS p2 is
# left at the image size; see the message printed at the end.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
IMG=${IMG:-$HERE/../out/retro-backup.img}
MAX_BYTES=2000000000000

die() { printf 'flash: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'flash: %s\n' "$*"; }

[ $# -eq 1 ] || { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
DEV=$1
[ -f "$IMG" ] || die "image not found: $IMG (run make all)"
[ -b "$DEV" ] || [ -c "$DEV" ] || die "$DEV is not a device"

IMG_BYTES=$(wc -c <"$IMG" | tr -d ' ')
OS=$(uname -s)

case $OS in
Darwin)
    case $DEV in
    /dev/disk[0-9] | /dev/disk[0-9][0-9]) ;;
    *) die "give a whole disk like /dev/disk4 (see: diskutil list external)" ;;
    esac
    INFO=$(diskutil info "$DEV") || die "diskutil cannot see $DEV"
    field() { printf "%s\n" "$INFO" | sed -n "s|^ *$1: *||p" | head -n 1; }
    NAME=$(field 'Device / Media Name')
    LOCATION=$(field 'Device Location')
    PROTOCOL=$(field 'Protocol')
    BYTES=$(field 'Disk Size' | sed -n 's/.*(\([0-9]*\) Bytes).*/\1/p')
    WHOLE=$(field 'Part of Whole')
    [ "/dev/$WHOLE" = "$DEV" ] || die "$DEV is not a whole disk"
    # The system disk: whole disk of / and the physical store behind its APFS container.
    ROOTINFO=$(diskutil info /)
    for d in $(printf '%s\n' "$ROOTINFO" | sed -nE 's/^ *(Part of Whole|APFS Physical Store): *//p' | sed 's/s[0-9]*$//'); do
        [ "/dev/$d" = "$DEV" ] && die "$DEV holds the running system"
    done
    [ "$LOCATION" = Internal ] && die "$DEV is an internal disk ($NAME); refusing"
    RAW=/dev/r${DEV#/dev/}
    ;;
Linux)
    case $DEV in
    /dev/sd[a-z] | /dev/sd[a-z][a-z] | /dev/mmcblk[0-9] | /dev/nvme[0-9]n[0-9] | /dev/vd[a-z]) ;;
    *) die "give a whole disk like /dev/sdb" ;;
    esac
    K=${DEV#/dev/}
    [ -d "/sys/block/$K" ] || die "$DEV is not a whole disk"
    BYTES=$(($(cat "/sys/block/$K/size") * 512))
    NAME="$(cat "/sys/block/$K/device/vendor" 2>/dev/null || true) $(cat "/sys/block/$K/device/model" 2>/dev/null || true)"
    PROTOCOL=$(readlink -f "/sys/block/$K" | grep -q /usb && echo USB || echo non-USB)
    LOCATION=$([ "$(cat "/sys/block/$K/removable" 2>/dev/null || echo 0)" = 1 ] && echo removable || echo fixed)
    ROOTSRC=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    ROOTDISK=$(lsblk -n -o PKNAME "$ROOTSRC" 2>/dev/null | head -n 1 || true)
    [ -n "$ROOTDISK" ] && [ "$ROOTDISK" = "$K" ] && die "$DEV holds the running system"
    if command -v lsblk >/dev/null 2>&1; then
        for mp in $(lsblk -n -o MOUNTPOINT "$DEV" 2>/dev/null); do
            case $mp in / | /boot | /boot/efi | /home | /usr | /var | \[SWAP\]) die "$DEV has $mp mounted; refusing" ;; esac
        done
    fi
    RAW=$DEV
    ;;
*) die "unsupported OS $OS" ;;
esac

[ -n "$BYTES" ] && [ "$BYTES" -gt 0 ] || die "cannot determine the size of $DEV"
[ "$BYTES" -le "$MAX_BYTES" ] || die "$DEV is $((BYTES / 1000000000)) GB; refusing devices larger than 2 TB"
[ "$BYTES" -ge "$IMG_BYTES" ] || die "$DEV ($BYTES bytes) is smaller than the image ($IMG_BYTES bytes)"

echo
echo "  Device:   $DEV"
echo "  Name:     $NAME"
echo "  Size:     $((BYTES / 1000000)) MB ($BYTES bytes)"
echo "  Bus:      $PROTOCOL, $LOCATION"
echo "  Image:    $IMG ($((IMG_BYTES / 1048576)) MiB)"
echo
echo "  EVERYTHING ON $DEV WILL BE ERASED."
if [ "${FLASH_CONFIRMED:-}" != "$DEV" ]; then
    printf '  Type the device name (%s) to continue: ' "$DEV"
    read -r answer
    [ "$answer" = "$DEV" ] || die "aborted"
fi
if [ "$(id -u)" -ne 0 ]; then
    say "root privileges needed; re-running with sudo"
    exec sudo FLASH_CONFIRMED="$DEV" IMG="$IMG" sh "$0" "$DEV"
fi

case $OS in
Darwin)
    diskutil unmountDisk "$DEV" >/dev/null || die "cannot unmount $DEV"
    say "writing (dd bs=4m to $RAW)..."
    dd if="$IMG" of="$RAW" bs=4m
    sync
    say "done. The RETRODATA partition is $(((IMG_BYTES - 257 * 1048576) / 1048576)) MiB."
    say "macOS cannot resize it here. To use the whole stick either:"
    say "  - flash from Linux (this script grows it), or"
    say "  - on Linux: sudo sfdisk -N 2 /dev/sdX <<< ', +' && sudo mkfs.exfat -n RETRODATA /dev/sdX2"
    say "  - or let the client grow it on first boot (planned, PLAN.md section 5)"
    diskutil eject "$DEV" >/dev/null 2>&1 || true
    ;;
Linux)
    for p in $(lsblk -n -l -o NAME "$DEV" | tail -n +2); do
        umount "/dev/$p" 2>/dev/null || true
    done
    say "writing (dd bs=4M to $DEV)..."
    dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
    sync
    case $K in *[0-9]) P2=${DEV}p2 ;; *) P2=${DEV}2 ;; esac
    if command -v sfdisk >/dev/null 2>&1 && command -v mkfs.exfat >/dev/null 2>&1; then
        say "growing RETRODATA to the end of the stick"
        echo ', +' | sfdisk -q -N 2 "$DEV"
        if command -v partprobe >/dev/null 2>&1; then
            partprobe "$DEV" || true
        else
            blockdev --rereadpt "$DEV" 2>/dev/null || true
        fi
        if command -v udevadm >/dev/null 2>&1; then udevadm settle; else sleep 2; fi
        [ -b "$P2" ] || sleep 3
        mkfs.exfat -n RETRODATA "$P2" >/dev/null
        sync
        sfdisk -l "$DEV" | tail -n 3
    else
        say "sfdisk or mkfs.exfat (exfatprogs) missing; RETRODATA stays at image size"
    fi
    say "done; you can unplug $DEV"
    ;;
esac
