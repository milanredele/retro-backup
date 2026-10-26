#!/bin/sh
# shellcheck disable=SC2016 # probes are expanded by the guest shell
# screenshot-tour.sh - walk through the whole UI in QEMU and save PNG screenshots for the README
# (docs/screenshots/). Needs out/retro-backup.img, out/vmlinuz, out/retro.gz and out/victim.img.
# Run 1 boots the stick through syslinux for the boot menu shot; run 2 boots the kernel directly
# with a serial console on the side, which the script uses to detect the UI's state, while the
# VGA output shows the dialog screens.
#   test/screenshot-tour.sh [OUTDIR]        (default docs/screenshots)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd); OUT=${OUT:-$ROOT/out}
DEST=${1:-$ROOT/docs/screenshots}; mkdir -p "$DEST"
QEMU=$(command -v qemu-system-i386 2>/dev/null || echo /opt/homebrew/bin/qemu-system-i386)
PORT=$(( 41000 + $$ % 20000 ))
WORK=$(mktemp -d "${TMPDIR:-/tmp}/retro-tour.XXXXXX")
QPID=
cleanup() { [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
mon() { printf '%s\n' "$1" | nc -w 2 127.0.0.1 "$PORT" >/dev/null 2>&1 || true; }
shot() { mon "screendump $DEST/$1.png -f png"; echo "  $1.png"; }
key() { mon "sendkey $1"; sleep "${2:-1}"; }

echo "tour: run 1, syslinux boot menu"
cp "$OUT/retro-backup.img" "$WORK/stick.img"
"$QEMU" -cpu pentium3 -m 256 -M pc -vga std -display none -monitor telnet:127.0.0.1:$PORT,server,nowait \
    -drive file="$WORK/stick.img",format=raw,if=ide,index=0 -boot order=c >/dev/null 2>&1 &
QPID=$!; sleep 4; shot 01-boot-menu; kill "$QPID"; QPID=; sleep 1

echo "tour: run 2, the UI"
cp "$OUT/retro-backup.img" "$WORK/stick.img"; truncate -s 2G "$WORK/stick.img"
FIFO=$WORK/in; mkfifo "$FIFO"; LOG=$WORK/serial.log; : >"$LOG"
"$QEMU" -cpu pentium3 -m 256 -M pc -vga std -display none -monitor telnet:127.0.0.1:$PORT,server,nowait \
    -drive file="$WORK/stick.img",format=raw,if=ide,index=0 \
    -drive file="$OUT/victim.img",format=raw,if=ide,index=1,snapshot=on \
    -kernel "$OUT/vmlinuz" -initrd "$OUT/retro.gz" \
    -append "quiet console=tty0 console=ttyS0,115200 nomodeset vga=788 vt.default_utf8=1 norestore noswap nodhcp base rootfstype=ramfs retro.boot=usb" \
    -serial stdio <"$FIFO" >"$LOG" 2>&1 &
QPID=$!; exec 3>"$FIFO"
send() { printf '%s\r' "$1" >&3; }
seen() { grep -a -q -- "$1" "$LOG"; }
# wait_for TAG GUEST-TEST: poll the guest over serial until the test succeeds.
# wait_dialog TAG PATTERN: until the dialog on tty1 has PATTERN in its command line (its --title
# and box type identify the screen); wait_proc TAG NAME: until a process NAME runs (mc).
wait_for() {
    _i=0
    while :; do
        send "$2 && echo TOUR-$1-\$((20+2))"   # the guest does the arithmetic, so the echoed command never matches
        sleep 2; _i=$((_i + 2))
        seen "TOUR-$1-22" && return 0
        [ $_i -ge 120 ] && { shot "99-timeout-$1"; echo "tour: timeout waiting for $1" >&2; return 1; }
    done
}
wait_dialog() { wait_for "$1" "cat /proc/\$(pidof dialog 2>/dev/null || echo 0)/cmdline 2>/dev/null | tr \"\\\\0\" \" \" | grep -q \"$2\""; }
wait_proc() { wait_for "$1" "pidof $2 >/dev/null"; }
i=0; while ! seen 'Please press Enter'; do sleep 1; i=$((i+1)); [ $i -gt 120 ] && exit 1; done
send ''; sleep 1
wait_dialog scan "Looking for your files"; sleep 3; shot 02-scanning
wait_dialog list "Select what to copy"; sleep 2; shot 03-checklist
key tab; key tab; key ret; wait_dialog menu "title Menu"; sleep 1; shot 04-menu
key down; key down; key ret; wait_dialog dest "Where should the files go"; sleep 1; shot 05-destination
key ret; wait_dialog hint "Copy by hand"; sleep 1; shot 06-browse-hint
key ret; wait_proc mc mc; sleep 3; shot 07-midnight-commander
key f10; wait_dialog list2 "Select what to copy"; sleep 2; shot 08-checklist-after-browse
key ret; wait_dialog dest2 "Where should the files go"; key ret; wait_dialog confirm "yes-label"; sleep 1; shot 09-confirm
key ret; wait_dialog copying "title Copying"; sleep 1; shot 10-copying
wait_dialog summary "title Done"; sleep 1; shot 11-summary
send "poweroff"
echo "tour: done, screenshots in $DEST"
