#!/bin/sh
# fetch.sh - download Tiny Core 16.x x86 kernel, core.gz and the tcz closure into build/cache/.
# Runs on the host (macOS or Linux) or in the builder container. Idempotent.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
CACHE=${CACHE:-$HERE/cache}
LIST=${LIST:-$HERE/tcz.list}
KVER=${KVER:-6.12.11-tinycore}
MIRRORS=${MIRRORS:-"http://tinycorelinux.net/16.x/x86 http://repo.tinycorelinux.net/16.x/x86"}
PLOP_URL=${PLOP_URL:-https://download.plop.at/files/bootmngr/plpbt-5.0.15.zip}

mkdir -p "$CACHE/tcz" "$CACHE/plop"

say() { printf '%s\n' "fetch: $*" >&2; }
die() { say "ERROR: $*"; exit 1; }

md5of() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | cut -d' ' -f1
    else
        md5 -q "$1"
    fi
}

# get REL OUT -> 0 ok, 2 not found on any mirror (404), 1 other failure
get() {
    g_rel=$1 g_out=$2 g_rc=1
    for m in $MIRRORS; do
        code=$(curl -sS -L --retry 3 --connect-timeout 20 -o "$g_out.part" -w '%{http_code}' "$m/$g_rel" || echo 000)
        if [ "$code" = 200 ]; then
            mv "$g_out.part" "$g_out"
            return 0
        fi
        rm -f "$g_out.part"
        [ "$code" = 404 ] && g_rc=2
    done
    return $g_rc
}

# checked REL OUT: download OUT and verify against REL.md5.txt
checked() {
    rel=$1 out=$2
    if [ -f "$out" ] && [ -f "$out.md5.txt" ] &&
        [ "$(md5of "$out")" = "$(cut -d' ' -f1 <"$out.md5.txt")" ]; then
        return 0
    fi
    get "$rel.md5.txt" "$out.md5.txt" || die "no checksum for $rel"
    want=$(cut -d' ' -f1 <"$out.md5.txt")
    for _try in 1 2; do
        say "downloading $rel"
        get "$rel" "$out" || die "download failed: $rel"
        [ "$(md5of "$out")" = "$want" ] && return 0
        say "md5 mismatch for $rel, retrying"
    done
    die "md5 mismatch for $rel"
}

# --- kernel and base initramfs ---
for f in vmlinuz core.gz; do
    checked "release/distribution_files/$f" "$CACHE/$f"
done

# --- tcz closure ---
queue=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$LIST" | grep -v '^$' || true)
done_list=" "
while [ -n "$queue" ]; do
    next=
    for t in $queue; do
        t=${t%.tcz}
        case "$done_list" in *" $t "*) continue ;; esac
        done_list="$done_list$t "
        checked "tcz/$t.tcz" "$CACHE/tcz/$t.tcz"
        dep=$CACHE/tcz/$t.tcz.dep
        if [ ! -f "$dep" ]; then
            if get "tcz/$t.tcz.dep" "$dep"; then :; else
                rc=$?
                [ $rc -eq 2 ] || die "failed to fetch $t.tcz.dep"
                : >"$dep" # 404 = no dependencies
            fi
        fi
        # shellcheck disable=SC2013 # extension names never contain spaces
        for d in $(sed -e "s/KERNEL/$KVER/g" -e 's/[[:space:]]//g' "$dep"); do
            next="$next ${d%.tcz}"
        done
    done
    queue=$next
done
# shellcheck disable=SC2086
printf '%s\n' $done_list >"$CACHE/tcz.closure"
say "tcz closure: $(wc -l <"$CACHE/tcz.closure" | tr -d ' ') extensions (list in $CACHE/tcz.closure)"

# --- Plop Boot Manager (optional) ---
if [ -f "$CACHE/plop/plpbt.iso" ] && [ -f "$CACHE/plop/plpbt.bin" ]; then
    :
elif command -v unzip >/dev/null 2>&1 || command -v bsdtar >/dev/null 2>&1; then
    zip=$CACHE/plop/plpbt.zip
    if curl -sSfL --retry 2 --connect-timeout 20 -o "$zip.part" "$PLOP_URL"; then
        mv "$zip.part" "$zip"
        tmp=$CACHE/plop/x
        rm -rf "$tmp" && mkdir -p "$tmp"
        if command -v unzip >/dev/null 2>&1; then
            unzip -q -o "$zip" -d "$tmp" || true
        else
            bsdtar -xf "$zip" -C "$tmp" || true
        fi
        for f in plpbt.iso plpbt.bin; do
            p=$(find "$tmp" -type f -name "$f" | head -n 1)
            if [ -n "$p" ]; then cp "$p" "$CACHE/plop/$f"; else say "WARNING: $f not in Plop zip"; fi
        done
        rm -rf "$tmp"
    else
        rm -f "$zip.part"
        say "WARNING: Plop download failed ($PLOP_URL); continuing without it"
    fi
else
    say "WARNING: no unzip/bsdtar; skipping Plop"
fi

say "done"
