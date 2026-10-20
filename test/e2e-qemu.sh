#!/bin/sh
# shellcheck disable=SC2016,SC2329 # probes are expanded by the guest shell; cleanup runs via trap
# e2e-qemu.sh - end-to-end run in QEMU: boot the build with the stick image and the victim disk,
# let retro-main.sh (tty1) discover and scan the victim, then from the serial console select
# every group, copy to RETRODATA, verify every manifest md5 on the destination, and check on the
# host that the victim image is byte-identical afterwards (sources are never written).
#
#   test/e2e-qemu.sh [--cpu pentium3] [--mem 256] [--timeout 600] [VICTIM.img]
#   Exit 0 on success. Serial log: out/e2e-qemu.log
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT=${OUT:-$ROOT/out}
CPU=pentium3; MEM=256; TIMEOUT=600; VICTIM=$OUT/victim.img
while [ $# -gt 0 ]; do
    case $1 in
    --cpu) CPU=$2; shift 2 ;; --mem) MEM=$2; shift 2 ;; --timeout) TIMEOUT=$2; shift 2 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;; *) VICTIM=$1; shift ;;
    esac
done
QEMU=$(command -v qemu-system-i386 2>/dev/null || echo /opt/homebrew/bin/qemu-system-i386)
[ -x "$QEMU" ] || { echo "qemu-system-i386 not found" >&2; exit 77; }
for f in "$OUT/retro-backup.img" "$OUT/vmlinuz" "$OUT/retro.gz" "$VICTIM"; do
    [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done
md5() { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }
VICTIM_MD5_BEFORE=$(md5 "$VICTIM")

APPEND="console=ttyS0,115200 nomodeset norestore noswap nodhcp base rootfstype=ramfs retro.boot=usb retro.debug=1"
LOG=$OUT/e2e-qemu.log
WORK=$(mktemp -d "${TMPDIR:-/tmp}/retro-e2e.XXXXXX")
FIFO=$WORK/in; mkfifo "$FIFO"; : >"$LOG"
# Stick: persistent copy so the copied files survive for inspection; victim: written through
# (no snapshot) so a stray write would show up in the hash check.
cp "$OUT/retro-backup.img" "$WORK/stick.img"
"$QEMU" -cpu "$CPU" -m "$MEM" -M pc \
    -drive file="$WORK/stick.img",format=raw,if=ide,index=0 \
    -drive file="$VICTIM",format=raw,if=ide,index=1 \
    -kernel "$OUT/vmlinuz" -initrd "$OUT/retro.gz" -append "$APPEND" \
    -nographic -monitor none -serial stdio <"$FIFO" >"$LOG" 2>&1 &
QPID=$!
exec 3>"$FIFO"
cleanup() { exec 3>&- 2>/dev/null || true; kill "$QPID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
send() { printf '%s\r' "$1" >&3; }
seen() { grep -a -q -- "$1" "$LOG"; }

# Guest-side check script (kept in one heredoc; sent line by line through the console).
GUEST_CHECKS='
R=/run/retro
i=0; while [ ! -s $R/scan.tsv ] || ! grep -q "^ALL" $R/scan.progress 2>/dev/null; do i=$((i+1)); [ $i -gt 120 ] && break; sleep 1; done
echo "=== volumes.tsv"; cat $R/volumes.tsv
echo "=== scan.tsv ($(wc -l < $R/scan.tsv) groups)"; cat $R/scan.tsv
chk() { if [ "$2" = "$3" ]; then echo "CHECK $1 OK"; else echo "CHECK $1 FAIL (got $2 want $3)"; fi; }
chk volumes "$(wc -l < $R/volumes.tsv)" 4
chk os_hints "$(cut -f6 $R/volumes.tsv | sort | tr "\n" ,)" "data,linux,win7,winxp,"
chk fs_ntfs "$(cut -f2 $R/volumes.tsv | grep -c ntfs)" 2
chk fotok "$(awk -F"\t" "\$7==\"Fotók 2007\"{print \$8}" $R/scan.tsv)" 60
chk dcim "$(awk -F"\t" "\$7 ~ /DCIM/{s+=\$8} END{print s+0}" $R/scan.tsv)" 53
chk oe "$(awk -F"\t" "\$4==\"email\" && \$7 ~ /Outlook Express/{print \$8}" $R/scan.tsv)" 5
chk tb7 "$(awk -F"\t" "\$4==\"email\" && \$7 ~ /Roaming\/Thunderbird/{print \$8}" $R/scan.tsv)" 5
chk maildir "$(awk -F"\t" "\$4==\"email\" && \$7 ~ /Maildir/{print \$8}" $R/scan.tsv)" 4
chk no_windows "$(awk -F"\t" "\$7 ~ /^(WINDOWS|Windows|Program Files|RECYCLER|usr)(\/|\$)/" $R/scan.tsv | wc -l)" 0
mkdir -p /mnt/dst && mount -t exfat -o rw /dev/sda2 /mnt/dst && echo "CHECK mount_dst OK" || echo "CHECK mount_dst FAIL"
cut -f1 $R/scan.tsv > $R/selection.txt
printf "type=usb\npath=/mnt/dst\ndev=/dev/sda2\n" > $R/dest.conf
sh /opt/retro/40-copy.sh > $R/copy.out 2>&1; echo "copy exit=$?"; tail -n 5 $R/copy.out; echo "=== copy.result"; cat $R/copy.result
mountpoint -q /mnt/dst || mount -t exfat -o ro /dev/sda2 /mnt/dst
fails=0; oks=0
for m in /mnt/dst/BACKUP/*/*/MANIFEST.tsv; do
  d=$(dirname "$m"); n=$(awk -F"\t" "{print \$4\"  \"\$1}" "$m" | (cd "$d" && md5sum -c 2>&1) | grep -c ": OK"); t=$(wc -l < "$m"); oks=$((oks+n)); fails=$((fails + t - n))
done
echo "manifest files verified: $oks, failed: $fails"; chk verify "$fails" 0
chk failed_copies "$(sed -n "s/^failed=//p" $R/copy.result)" 0
echo "=== log tail"; tail -n 8 /mnt/dst/BACKUP/*/retro-backup.log
umount /mnt/dst; sync
echo E2E-DONE-$((40+2))
'
echo "e2e: $QEMU -cpu $CPU -m $MEM, timeout ${TIMEOUT}s, log $LOG"
start=$(date +%s); state=boot; rc=1
while :; do
    el=$(( $(date +%s) - start ))
    kill -0 "$QPID" 2>/dev/null || { [ "$state" = finished ] && rc=0; [ "$state" = finished ] || echo "e2e: qemu exited early (state $state)" >&2; break; }
    [ "$el" -ge "$TIMEOUT" ] && { echo "e2e: TIMEOUT after ${el}s in state $state" >&2; break; }
    case $state in
    boot)
        if seen 'Please press Enter to activate this console'; then
            echo "e2e: console after ${el}s"; send ''; sleep 2
            printf '%s\n' "$GUEST_CHECKS" | while IFS= read -r line; do if [ -n "$line" ]; then send "$line"; fi; done
            state=run
        fi ;;
    run)
        if seen 'E2E-DONE-42'; then echo "e2e: guest run finished after ${el}s"; send 'poweroff'; state=finished; fi ;;
    finished) ;;
    esac
    sleep 1
done
[ "$rc" = 0 ] || { tail -n 40 "$LOG"; exit 1; }
echo "----- guest results -----"
grep -a -E '^CHECK |^copy exit=|^manifest files|^=== copy.result' "$LOG" | sed 's/^/  /'
grep -a -A12 '^=== copy.result' "$LOG" | sed -n '2,13p' | sed 's/^/  /'
VICTIM_MD5_AFTER=$(md5 "$VICTIM")
if [ "$VICTIM_MD5_BEFORE" = "$VICTIM_MD5_AFTER" ]; then echo "  CHECK victim_unchanged OK"; else echo "  CHECK victim_unchanged FAIL"; rc=1; fi
if grep -a -q '^CHECK .* FAIL' "$LOG"; then rc=1; fi
if [ "$rc" = 0 ]; then echo "e2e: PASS"; else echo "e2e: FAIL (see $LOG)"; exit 1; fi
