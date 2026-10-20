#!/bin/sh
# screenshot-qemu.sh - boot the stick image through its syslinux menu (default entry, VESA
# framebuffer console) with the victim disk attached and save PNG screenshots of the VGA
# output. Used to eyeball the console mode, font and dialog layout.
#   test/screenshot-qemu.sh [--entry retro|safe] [--delay 40] [VICTIM.img]   -> out/shot-*.png
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd); OUT=${OUT:-$ROOT/out}
DELAY=40; ENTRY=retro; VICTIM=$OUT/victim.img
while [ $# -gt 0 ]; do
    case $1 in --delay) DELAY=$2; shift 2 ;; --entry) ENTRY=$2; shift 2 ;; -*) echo "unknown option $1" >&2; exit 2 ;; *) VICTIM=$1; shift ;; esac
done
QEMU=$(command -v qemu-system-i386 2>/dev/null || echo /opt/homebrew/bin/qemu-system-i386)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/retro-shot.XXXXXX")
cp "$OUT/retro-backup.img" "$WORK/stick.img"; truncate -s 2G "$WORK/stick.img"
PORT=$(( 40000 + $$ % 20000 ))
"$QEMU" -cpu pentium3 -m 256 -M pc -vga std -display none \
    -drive file="$WORK/stick.img",format=raw,if=ide,index=0 \
    -drive file="$VICTIM",format=raw,if=ide,index=1,snapshot=on \
    -monitor telnet:127.0.0.1:$PORT,server,nowait -boot order=c >"$WORK/qemu.log" 2>&1 &
QPID=$!
cleanup() { kill "$QPID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
mon() { printf '%s\n' "$1" | nc -w 2 127.0.0.1 "$PORT" >/dev/null 2>&1 || true; }
sleep 3
# syslinux menu: choose the entry with its hotkey (r = retro, s = safe), then Enter.
case $ENTRY in safe) mon 'sendkey s' ;; *) mon 'sendkey r' ;; esac
sleep 1; mon 'sendkey ret'
i=0
while [ $i -lt "$DELAY" ]; do sleep 5; i=$((i+5)); mon "screendump $OUT/shot-$ENTRY-$i.png -f png"; done
# press Tab/space to show the dialog with a highlighted row, then one more shot
mon 'sendkey down'; sleep 1; mon "screendump $OUT/shot-$ENTRY-final.png -f png"
echo "screenshots:"; ls -1 "$OUT"/shot-"$ENTRY"-*.png
