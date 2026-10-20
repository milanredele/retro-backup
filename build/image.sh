#!/bin/sh
# image.sh - assemble out/retro-backup.img (1 GiB pendrive image) and out/retro.iso from
# out/vmlinuz + out/retro.gz, without loop devices. Runs inside the builder container.
# Layout: CONTRACTS.md section 6, PLAN.md section 5.
set -eu

SRC=${SRC:-$(cd "$(dirname "$0")/.." && pwd)}
CACHE=${CACHE:-$SRC/build/cache}
OUT=${OUT:-$SRC/out}
TMP=${TMP:-/tmp/retro-image}
IMG_MIB=${IMG_MIB:-1024}
P1_START=2048         # sectors (1 MiB)
P1_MIB=256
CMDLINE="quiet nomodeset vga=normal norestore noswap nodhcp base rootfstype=ramfs"

say() { printf '%s\n' "image: $*" >&2; }
die() { say "ERROR: $*"; exit 1; }

findfile() { # first existing path among the arguments
    for f; do [ -f "$f" ] && { echo "$f"; return 0; }; done
    return 1
}

for f in vmlinuz retro.gz; do
    [ -f "$OUT/$f" ] || die "missing $OUT/$f; run 'make remaster' first"
done
MBR=$(findfile /usr/lib/syslinux/mbr/mbr.bin /usr/lib/SYSLINUX/mbr.bin /usr/share/syslinux/mbr.bin) ||
    die "mbr.bin not found"
MODDIR=/usr/lib/syslinux/modules/bios
[ -f "$MODDIR/ldlinux.c32" ] || MODDIR=/usr/share/syslinux
MEMDISK=$(findfile /usr/lib/syslinux/memdisk /usr/share/syslinux/memdisk) || MEMDISK=
ISOLINUX=$(findfile /usr/lib/ISOLINUX/isolinux.bin /usr/lib/syslinux/isolinux.bin) || die "isolinux.bin not found"
ISOHDPFX=$(findfile /usr/lib/ISOLINUX/isohdpfx.bin /usr/lib/syslinux/mbr/isohdpfx.bin) || die "isohdpfx.bin not found"

rm -rf "$TMP"
mkdir -p "$TMP/payload" "$OUT"
P=$TMP/payload

PLOP=
if [ -f "$CACHE/plop/plpbt.iso" ] && [ -n "$MEMDISK" ]; then
    PLOP=1
    cp "$CACHE/plop/plpbt.iso" "$P/plpbt.iso"
    cp "$MEMDISK" "$P/memdisk"
else
    say "WARNING: plpbt.iso or memdisk missing; no plop entry"
fi
cp "$OUT/vmlinuz" "$OUT/retro.gz" "$P/"
for m in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32; do
    cp "$MODDIR/$m" "$P/$m"
done

# ---------------------------------------------------------------------------------------------
# Boot menu (same for syslinux and isolinux, only retro.boot differs)
mkcfg() { # $1 = value of retro.boot
    cat <<EOF
UI menu.c32
PROMPT 0
TIMEOUT 30
DEFAULT retro
MENU TITLE retro-backup: copy user data off this PC

LABEL retro
  MENU LABEL ^retro-backup
  KERNEL vmlinuz
  APPEND initrd=retro.gz $CMDLINE retro.boot=$1

LABEL safe
  MENU LABEL retro-backup (^safe mode: no ACPI/APIC)
  KERNEL vmlinuz
  APPEND initrd=retro.gz $CMDLINE retro.boot=$1 acpi=off noapic nolapic

LABEL serial
  MENU LABEL retro-backup (seria^l console, debug)
  KERNEL vmlinuz
  APPEND initrd=retro.gz nomodeset vga=normal norestore noswap nodhcp base rootfstype=ramfs retro.boot=$1 console=tty0 console=ttyS0,115200 retro.debug=1
EOF
    if [ -n "$PLOP" ]; then
        cat <<EOF

LABEL plop
  MENU LABEL ^Plop Boot Manager (boot USB on old BIOSes)
  KERNEL memdisk
  INITRD plpbt.iso
  APPEND iso raw
EOF
    fi
}
mkcfg usb >"$P/syslinux.cfg"

# README for whoever plugs the stick into a modern machine (CRLF for Notepad).
sed 's/$/\r/' >"$P/README.txt" <<'EOF'
retro-backup boot stick
=======================

This stick boots an old PC (roughly 1998-2015, BIOS or UEFI-with-CSM) into a small
Linux system that finds the user's documents, photos, e-mail and other data on the
internal disks and copies them onto this stick. The internal disks are only ever
mounted read-only; nothing is written to them.

How to boot
-----------
1. Plug the stick in, switch the PC on and press the boot menu key right away.
   Common keys: F12 (Dell, Lenovo, Acer, Toshiba), F8 (ASUS), Esc (HP, some ASUS),
   F11 (MSI, ASRock, some Gigabyte), F9 (HP laptops). If there is no boot menu, enter
   the BIOS setup (Del, F2 or F1) and move "USB-HDD" / "Removable" first in the boot order.
2. On old BIOSes enable "USB legacy support" and, if offered, choose "USB-HDD" (not
   USB-ZIP / USB-FDD) as the emulation mode.
3. If the BIOS cannot boot from USB at all, burn retro.iso to a CD (or use the Plop
   entry / plpbt.iso on a CD): Plop Boot Manager then boots this stick even on
   machines without USB boot support.
4. In the menu choose "retro-backup". Use "safe mode" if the PC hangs during boot,
   and "low memory PC" on machines with less than 192 MB of RAM.

Where the backup goes
---------------------
Backups are written to the second partition of this stick, labelled RETRODATA (exFAT),
under BACKUP\<machine>\<volume>\..., with a log (retro-backup.log) and a checksum
manifest (MANIFEST.tsv) per volume. This first partition (RETROBOOT, FAT32) only holds
the boot files.

Windows before Windows 10 version 1703 shows only the first partition of a USB stick,
so on old Windows the RETRODATA partition is invisible. Read the backup on Windows 10/11,
macOS or Linux.

Other consoles while the backup runs: Alt+F2 root shell, Alt+F3 file manager (mc),
Alt+F4 log.
EOF

# ---------------------------------------------------------------------------------------------
# Partition 1: FAT32 RETROBOOT, built as a file, syslinux installed with the mtools variant.
P1=$TMP/p1.img
truncate -s "${P1_MIB}M" "$P1"
mkfs.vfat -F 32 -n RETROBOOT -h "$P1_START" -g 255/63 -i 52455452 "$P1" >/dev/null
for f in "$P"/*; do
    mcopy -i "$P1" -o "$f" ::/
done
syslinux --install "$P1"
mdir -a -i "$P1" ::/ >&2
fsck.vfat -n "$P1" >/dev/null || die "fsck.vfat failed on p1"

# ---------------------------------------------------------------------------------------------
# Whole image: partition table + MBR code, then the partition contents.
IMG=$OUT/retro-backup.img.tmp
rm -f "$IMG"
truncate -s "${IMG_MIB}M" "$IMG"
P1_SECTORS=$((P1_MIB * 2048))
P2_START=$((P1_START + P1_SECTORS))
P2_SECTORS=$((IMG_MIB * 2048 - P2_START))
sfdisk --no-reread --no-tell-kernel -q "$IMG" <<EOF
label: dos
unit: sectors

start=$P1_START, size=$P1_SECTORS, type=c, bootable
start=$P2_START, size=$P2_SECTORS, type=7
EOF
dd if="$MBR" of="$IMG" bs=440 count=1 conv=notrunc status=none
dd if="$P1" of="$IMG" bs=512 seek="$P1_START" conv=notrunc,sparse status=none

P2=$TMP/p2.img
truncate -s $((P2_SECTORS * 512)) "$P2"
mkfs.exfat -n RETRODATA "$P2" >/dev/null
fsck.exfat -n "$P2" >/dev/null || die "fsck.exfat failed on p2"
dd if="$P2" of="$IMG" bs=512 seek="$P2_START" conv=notrunc,sparse status=none
mv "$IMG" "$OUT/retro-backup.img"
IMG=$OUT/retro-backup.img

say "partition table:"
sfdisk -d "$IMG" >&2
file -s "$IMG" >&2
dd if="$IMG" bs=512 skip="$P1_START" count=1 status=none | file - >&2
dd if="$IMG" bs=512 skip="$P2_START" count=1 status=none | file - >&2
# Sanity: MBR code present and partition table intact
cmp -n 440 "$MBR" "$IMG" >/dev/null || die "mbr.bin not in place"
sfdisk -d "$IMG" | grep -q 'type=c, bootable' || die "p1 not bootable FAT32 LBA"

# ---------------------------------------------------------------------------------------------
# CD-only fallback: isolinux, isohybrid.
ISOD=$TMP/iso
mkdir -p "$ISOD/isolinux"
cp "$P"/* "$ISOD/isolinux/"
rm -f "$ISOD/isolinux/syslinux.cfg"
cp "$P/README.txt" "$ISOD/README.txt"
cp "$ISOLINUX" "$ISOD/isolinux/isolinux.bin"
mkcfg usb >"$ISOD/isolinux/isolinux.cfg"
xorriso -as mkisofs -quiet -o "$OUT/retro.iso.tmp" -V RETROBOOT -J -r \
    -isohybrid-mbr "$ISOHDPFX" \
    -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    "$ISOD"
mv "$OUT/retro.iso.tmp" "$OUT/retro.iso"
file "$OUT/retro.iso" >&2

rm -rf "$TMP"
say "retro-backup.img: $(wc -c <"$OUT/retro-backup.img" | tr -d ' ') bytes; retro.iso: $(wc -c <"$OUT/retro.iso" | tr -d ' ') bytes"
