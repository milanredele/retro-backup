#!/bin/sh
# shellcheck disable=SC2016,SC2329 # probes are expanded by the guest shell; cleanup runs via trap
# test-qemu.sh - boot the retro-backup build in qemu-system-i386 (host side, macOS or Linux).
#
#   build/test-qemu.sh [--cpu pentium3] [--mem 256] [--timeout 180] [--persist] [VICTIM.img]
#       Automated check: boots out/vmlinuz + out/retro.gz directly with a serial console, the
#       stick image attached as the first IDE disk (snapshot, unless --persist), presses Enter on
#       the ttyS0 console, runs a few probes and powers off. Exit 0 on success, 1 on failure or
#       timeout. Serial log: out/test-qemu.log.
#       --append "ARGS" adds kernel parameters (e.g. rootfstype=ramfs).
#   build/test-qemu.sh --image [--cpu ..] [--mem ..] [VICTIM.img]
#       Manual: boot the stick image through its syslinux menu (VGA window; serial on this
#       terminal; pick the "serial" entry to get the console here).
#   build/test-qemu.sh --pxe        placeholder
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT=${OUT:-$ROOT/out}
CPU=pentium3
MEM=256
TIMEOUT=180
MODE=auto
PERSIST=
VICTIM=
EXTRA_APPEND=

usage() { sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case $1 in
    --cpu) CPU=$2; shift 2 ;;
    --cpu=*) CPU=${1#*=}; shift ;;
    --mem) MEM=$2; shift 2 ;;
    --mem=*) MEM=${1#*=}; shift ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --append) EXTRA_APPEND=$2; shift 2 ;;
    --image) MODE=image; shift ;;
    --persist) PERSIST=1; shift ;;
    --pxe) echo "test-qemu: --pxe not implemented yet"; exit 0 ;;
    -h | --help) usage 0 ;;
    -*) echo "test-qemu: unknown option $1" >&2; usage 2 ;;
    *) VICTIM=$1; shift ;;
    esac
done

QEMU=$(command -v qemu-system-i386 2>/dev/null || true)
[ -n "$QEMU" ] || [ ! -x /opt/homebrew/bin/qemu-system-i386 ] || QEMU=/opt/homebrew/bin/qemu-system-i386
[ -n "$QEMU" ] || [ ! -x /usr/local/bin/qemu-system-i386 ] || QEMU=/usr/local/bin/qemu-system-i386
if [ -z "$QEMU" ]; then
    echo "test-qemu: qemu-system-i386 not found; skipping" >&2
    exit 77
fi

IMG=$OUT/retro-backup.img
for f in "$IMG" "$OUT/vmlinuz" "$OUT/retro.gz"; do
    [ -f "$f" ] || { echo "test-qemu: missing $f (run make all)" >&2; exit 1; }
done

fmt_of() { case $1 in *.qcow2) echo qcow2 ;; *) echo raw ;; esac; }

set -- -M pc -cpu "$CPU" -m "$MEM" -no-reboot
if [ "$MODE" = auto ] && [ -z "$PERSIST" ]; then
    set -- "$@" -drive "file=$IMG,format=raw,if=ide,index=0,snapshot=on"
else
    set -- "$@" -drive "file=$IMG,format=raw,if=ide,index=0"
fi
if [ -n "$VICTIM" ]; then
    [ -f "$VICTIM" ] || { echo "test-qemu: no such file $VICTIM" >&2; exit 1; }
    set -- "$@" -drive "file=$VICTIM,format=$(fmt_of "$VICTIM"),if=ide,index=1"
fi

if [ "$MODE" = image ]; then
    echo "test-qemu: booting $IMG via syslinux; choose 'serial' in the menu for a console here"
    exec "$QEMU" "$@" -boot c -serial mon:stdio
fi

# ---------------------------------------------------------------------------------------------
# Automated: direct kernel boot, serial console on a pipe we drive.
APPEND="console=ttyS0,115200 nomodeset norestore noswap nodhcp base rootfstype=ramfs retro.boot=usb retro.debug=1${EXTRA_APPEND:+ $EXTRA_APPEND}"
LOG=$OUT/test-qemu.log
WORK=$(mktemp -d "${TMPDIR:-/tmp}/retro-qemu.XXXXXX")
FIFO=$WORK/in
mkfifo "$FIFO"
: >"$LOG"

"$QEMU" "$@" -kernel "$OUT/vmlinuz" -initrd "$OUT/retro.gz" -append "$APPEND" \
    -nographic -monitor none -serial stdio <"$FIFO" >"$LOG" 2>&1 &
QPID=$!
exec 3>"$FIFO"

cleanup() {
    exec 3>&- 2>/dev/null || true
    kill "$QPID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

send() { printf '%s\r' "$1" >&3; }
seen() { grep -a -q -- "$1" "$LOG"; }

echo "test-qemu: $QEMU -cpu $CPU -m $MEM, timeout ${TIMEOUT}s, log $LOG"
start=$(date +%s)
state=boot
rc=1
while :; do
    now=$(date +%s)
    el=$((now - start))
    if ! kill -0 "$QPID" 2>/dev/null; then
        [ "$state" = finished ] && rc=0
        [ "$state" = finished ] || echo "test-qemu: qemu exited early (state $state)" >&2
        break
    fi
    if [ "$el" -ge "$TIMEOUT" ]; then
        echo "test-qemu: TIMEOUT after ${el}s in state '$state'" >&2
        break
    fi
    case $state in
    boot)
        if seen 'Please press Enter to activate this console'; then
            echo "test-qemu: ttyS0 console offered after ${el}s"
            send ''
            sleep 2
            send 'echo RETRO-QEMU-$((40+2)); uname -r; grep -m1 "model name" /proc/cpuinfo; free -m | head -2'
            send 'ls /opt/retro; for c in rsync dialog mc ntfs-3g mount.ntfs-3g mkfs.exfat lvm mdadm photorec ddrescue pv ncdu gawk curl smartctl find; do command -v $c >/dev/null || echo MISS""ING:$c; done; id -un; hostname; ps | grep "[r]etro-"'
            send 'modprobe ntfs3 && modprobe exfat && modprobe reiserfs && modprobe dm-mod && echo MODULES-$((1+1))-OK; blkid; tail -n 3 /run/retro/debug.log 2>/dev/null; echo PROBES-$((2+2))-DONE'
            state=shell
        fi
        ;;
    shell)
        if seen 'PROBES-4-DONE'; then
            if seen 'RETRO-QEMU-42'; then
                echo "test-qemu: shell on ttyS0 works after ${el}s"
                send 'poweroff'
                state=finished
            fi
        fi
        ;;
    finished)
        # waiting for poweroff to stop qemu; stop waiting 20 s later
        [ -n "${done_at:-}" ] || done_at=$el
        [ $((el - done_at)) -lt 20 ] || break
        ;;
    esac
    sleep 2
done
[ "$state" = finished ] && rc=0

echo "----- last 30 lines of serial output -----"
tr -d '\r\033' <"$LOG" | tail -n 30
echo "------------------------------------------"
if grep -a -q 'MISSING:' "$LOG"; then
    echo "test-qemu: FAIL: missing tools: $(grep -a -o 'MISSING:[^[:space:]]*' "$LOG" | sort -u | tr '\n' ' ')"
    rc=1
fi
if [ "$state" = finished ] && ! seen 'MODULES-2-OK'; then
    echo "test-qemu: FAIL: module loading probe failed"
    rc=1
fi
if seen 'rootfs image is not initramfs' || seen 'Initramfs unpacking failed'; then
    echo "test-qemu: FAIL: initramfs did not unpack completely (not enough RAM for ${MEM} MB?)"
    rc=1
fi
if [ "$rc" -eq 0 ]; then
    echo "test-qemu: PASS ($CPU, ${MEM} MB)"
else
    echo "test-qemu: FAIL ($CPU, ${MEM} MB)"
fi
exit "$rc"
