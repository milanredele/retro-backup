#!/bin/sh
# remaster.sh - build out/retro.gz (+ out/vmlinuz) from Tiny Core core.gz, the tcz closure and
# the repo's rootfs/ overlay. Runs as root inside the retro-backup-builder container
# (repo mounted at /src). See PLAN.md section 7 and CONTRACTS.md section 1.
set -eu

SRC=${SRC:-$(cd "$(dirname "$0")/.." && pwd)}
CACHE=${CACHE:-$SRC/build/cache}
LIST=${LIST:-$SRC/build/tcz.list}
OUT=${OUT:-$SRC/out}
# The work tree must live on a case-sensitive, root-owned filesystem (not the macOS bind mount).
WORK=${WORK:-/tmp/retro-work}
KVER=${KVER:-6.12.11-tinycore}
MIRROR=${MIRROR:-http://tinycorelinux.net/16.x/x86}
PATH_CONTRACT=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

say() { printf '%s\n' "remaster: $*" >&2; }
die() { say "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (inside the builder container)"
[ -f "$CACHE/core.gz" ] || die "missing $CACHE/core.gz; run 'make fetch' first"
[ -f "$CACHE/vmlinuz" ] || die "missing $CACHE/vmlinuz; run 'make fetch' first"

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
W=$WORK

# ---------------------------------------------------------------------------------------------
# 1. Base: core.gz
say "unpacking core.gz"
(cd "$W" && gzip -dc "$CACHE/core.gz" | cpio -idm --quiet --no-absolute-filenames)
[ -c "$W/dev/console" ] || say "WARNING: dev/console missing after unpack (mknod not permitted?)"

if [ -d "$W/lib/modules/$KVER/kernel" ]; then
    say "core.gz already contains lib/modules/$KVER"
else
    say "core.gz has no modules; adding modules.gz"
    if [ ! -f "$CACHE/modules.gz" ]; then
        curl -sSfL -o "$CACHE/modules.gz" "$MIRROR/release/distribution_files/modules.gz"
        curl -sSfL -o "$CACHE/modules.gz.md5.txt" "$MIRROR/release/distribution_files/modules.gz.md5.txt"
    fi
    (cd "$CACHE" && md5sum -c modules.gz.md5.txt >/dev/null) || die "modules.gz md5 mismatch"
    (cd "$W" && gzip -dc "$CACHE/modules.gz" | cpio -idm --quiet --no-absolute-filenames)
fi

# ---------------------------------------------------------------------------------------------
# 2. Extensions: the closure computed by fetch.sh (falls back to tcz.list)
if [ -f "$CACHE/tcz.closure" ]; then
    TCZS=$(cat "$CACHE/tcz.closure")
else
    TCZS=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$LIST" | grep -v '^$')
fi
n=0
for t in $TCZS; do
    f=$CACHE/tcz/$t.tcz
    [ -f "$f" ] || die "missing $f; run 'make fetch'"
    unsquashfs -q -n -f -d "$W" "$f" >/dev/null || die "unsquashfs failed: $t"
    n=$((n + 1))
done
say "unpacked $n extensions"

# ---------------------------------------------------------------------------------------------
# 3. Post-install scripts (usr/local/tce.installed/<name>). tce-load would run these at load time;
# with everything baked into the initramfs nobody runs them, so the known ones are applied here
# against the work tree (their udevadm/update-ca-certificates calls are replaced by build-time
# equivalents). Unknown non-empty scripts are run once at boot (sysinit) instead.
TI=$W/usr/local/tce.installed
POSTINST_BUILD=
POSTINST_BOOT=
cpnew() { [ -e "$2" ] || cp -p "$1" "$2"; }
for s in "$TI"/*; do
    [ -f "$s" ] || continue
    name=${s##*/}
    [ -s "$s" ] || continue # empty marker file
    case $name in
    ca-certificates)
        mkdir -p "$W/usr/local/etc/ssl/certs"
        cpnew "$W/usr/local/share/ca-certificates/files/ca-certificates.conf" "$W/usr/local/etc/ca-certificates.conf"
        # Equivalent of update-ca-certificates: certificates not yet listed in the conf are added
        # (enabled), then the enabled ones are concatenated into the bundle.
        conf=$W/usr/local/etc/ca-certificates.conf
        (cd "$W/usr/local/share/ca-certificates" && find . -name '*.crt' ! -path './files/*' |
            sed 's|^\./||' | LC_ALL=C sort) | while IFS= read -r c; do
            grep -qxF -e "$c" -e "!$c" "$conf" || echo "$c" >>"$conf"
        done
        bundle=$W/usr/local/etc/ssl/certs/ca-certificates.crt
        : >"$bundle"
        grep -v -e '^#' -e '^!' -e '^[[:space:]]*$' "$conf" |
            while IFS= read -r c; do
                p=$W/usr/local/share/ca-certificates/$c
                [ -f "$p" ] && { cat "$p"; echo; } >>"$bundle"
            done
        ln -sf /usr/local/etc/ssl/certs/ca-certificates.crt "$W/usr/local/etc/ssl/cacert.pem"
        ln -sf /usr/local/etc/ssl/certs/ca-certificates.crt "$W/usr/local/etc/ssl/ca-bundle.crt"
        say "ca bundle: $(grep -c 'BEGIN CERTIFICATE' "$bundle") certificates"
        ;;
    file)
        [ -e "$W/usr/bin/file" ] || ln -s /usr/local/bin/file "$W/usr/bin/file"
        ;;
    findutils)
        mkdir -p "$W/var/lib/locate"
        ;;
    glibc_gconv)
        tar xzf "$W/usr/local/share/glibc_gconv/files/files.tar.gz" -C "$W"
        rm -f "$W/usr/local/share/glibc_gconv/files/files.tar.gz" # extracted; save RAM
        ;;
    gpm)
        mkdir -p "$W/usr/local/etc/gpm"
        cpnew "$W/usr/local/share/gpm/files/gpm.conf" "$W/usr/local/etc/gpm/gpm.conf"
        cpnew "$W/usr/local/share/gpm/files/gpm-root.conf" "$W/usr/local/etc/gpm/gpm-root.conf"
        ;;
    lvm2)
        # udevadm reload/trigger skipped: the rules are in place before udevd starts.
        mkdir -p "$W/etc/udev/rules.d"
        for r in 10-dm.rules 11-dm-lvm.rules 13-dm-disk.rules 95-dm-notify.rules; do
            cpnew "$W/usr/local/share/lvm2/files/$r" "$W/etc/udev/rules.d/$r"
        done
        ;;
    mdadm)
        mkdir -p "$W/etc/udev/rules.d"
        cpnew "$W/usr/local/etc/udev/rules.d/64-md-raid.rules" "$W/etc/udev/rules.d/64-md-raid.rules"
        cpnew "$W/usr/local/etc/mdadm.conf.sample" "$W/usr/local/etc/mdadm.conf"
        ;;
    openssl)
        for d in certs private crl newcerts; do mkdir -p "$W/usr/local/etc/ssl/$d"; done
        [ -f "$W/usr/local/etc/ssl/index.txt" ] || : >"$W/usr/local/etc/ssl/index.txt"
        [ -f "$W/usr/local/etc/ssl/serial" ] || echo 01 >"$W/usr/local/etc/ssl/serial"
        [ -f "$W/usr/local/etc/ssl/crlnumber" ] || echo 01 >"$W/usr/local/etc/ssl/crlnumber"
        ;;
    smartmontools)
        mkdir -p "$W/usr/local/etc"
        cpnew "$W/usr/local/share/smartmontools/files/smartd.conf" "$W/usr/local/etc/smartd.conf"
        cpnew "$W/usr/local/share/smartmontools/files/drivedb.h" "$W/usr/local/share/smartmontools/drivedb.h"
        ;;
    *)
        POSTINST_BOOT="$POSTINST_BOOT $name"
        continue
        ;;
    esac
    POSTINST_BUILD="$POSTINST_BUILD $name"
done
say "post-install applied at build:${POSTINST_BUILD:- none}"
say "post-install deferred to boot:${POSTINST_BOOT:- none}"

# ---------------------------------------------------------------------------------------------
# 3b. Prune what an offline, English, text-mode data-rescue system never uses, to keep the
# initramfs small (it must unpack into RAM next to its compressed copy on 128 MB machines).
# PRUNE=0 disables this step.
if [ "${PRUNE:-1}" = 1 ]; then
    before=$(du -sk "$W" | cut -f1)
    L=$W/usr/local
    # Documentation, headers, static/libtool libs, desktop files, translations.
    rm -rf "$L/share/doc" "$L/share/man" "$L/share/info" "$L/share/licences" "$L/share/gtk-doc" \
        "$L/share/pixmaps" "$L/share/applications" "$L/share/locale" "$L/include" \
        "$L/lib/pkgconfig" "$L/share/pkgconfig" "$L/share/aclocal" "$W/usr/share/man" "$W/usr/share/doc"
    find "$L/lib" -type f \( -name '*.a' -o -name '*.la' \) -exec rm -f {} +
    # glibc gconv: keep Unicode, Western/Central/Eastern European, Cyrillic, Greek, Turkish, DOS
    # and Windows code pages (old file names on FAT/ext); drop EBCDIC and CJK.
    if [ -d "$W/usr/lib/gconv" ]; then
        for g in "$W"/usr/lib/gconv/*.so; do
            case ${g##*/} in
            UNICODE.so | UTF-*.so | ISO8859-*.so | CP12[0-9][0-9].so | CP737.so | CP775.so | \
                IBM437.so | IBM85[0-9].so | IBM86[0-9].so | KOI8-*.so | MACINTOSH.so | \
                MAC-CENTRALEUROPE.so | ISO646.so | ANSI_X3.110.so) ;;
            *) rm -f "$g" ;;
            esac
        done
    fi
    # terminfo: the consoles we can meet (VGA console, serial, ssh/xterm) are enough.
    if [ -d "$L/share/terminfo" ]; then
        keep=$WORK.terminfo
        rm -rf "$keep" && mkdir -p "$keep"
        for t in a/ansi d/dumb l/linux l/linux-16color v/vt100 v/vt102 v/vt220 x/xterm \
            x/xterm-color x/xterm-256color s/screen s/screen-256color r/rxvt c/cons25; do
            [ -e "$L/share/terminfo/$t" ] || continue
            mkdir -p "$keep/${t%/*}" && cp -a "$L/share/terminfo/$t" "$keep/$t"
        done
        rm -rf "$L/share/terminfo" && mv "$keep" "$L/share/terminfo"
    fi
    # Tools pulled in only as library dependencies.
    rm -f "$L/bin/openssl" "$L/bin/c_rehash"
    # gcc runtime and pcre variants: remove a library only if no ELF in the tree needs it.
    needed=$WORK.needed
    find "$W" -type f \( -perm -u+x -o -name '*.so*' \) -exec sh -c '
        for f; do readelf -d "$f" 2>/dev/null | sed -n "s/.*(NEEDED).*\[\(.*\)\]/\1/p"; done' sh {} + |
        sort -u >"$needed"
    for lib in libasan libubsan libtsan liblsan libhwasan libquadmath libitm libgomp libatomic \
        libgfortran libpcre2-16 libpcre2-32 libpcre2-posix libpcrecpp libpcreposix; do
        for f in "$L"/lib/"$lib".so*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            if grep -q "^$lib\.so" "$needed"; then continue 2; fi
        done
        rm -f "$L"/lib/"$lib".so*
    done
    rm -f "$needed"
    # Kernel modules for hardware that never appears in a pre-2015 desktop/laptop: datacenter
    # NICs, flash/MTD chips.
    E=$W/lib/modules/$KVER/kernel/drivers/net/ethernet
    for d in mellanox qlogic chelsio sfc netronome cavium huawei emulex brocade amazon google \
        fungible pensando cisco myricom neterion wangxun aquantia alacritech tehuti mscc \
        microsoft engleder meta intel/ice intel/i40e intel/iavf intel/idpf intel/ixgbe \
        intel/ixgbevf intel/fm10k intel/igbvf broadcom/bnx2x broadcom/bnxt marvell/octeontx2 \
        marvell/prestera; do
        rm -rf "${E:?}/$d"
    done
    rm -rf "$L/lib/modules/$KVER/kernel/drivers/mtd" "$L/lib/modules/$KVER/kernel/fs/jffs2" \
        "$L/lib/modules/$KVER/kernel/fs/ubifs"
    after=$(du -sk "$W" | cut -f1)
    say "pruned $(((before - after) / 1024)) MiB (tree now $((after / 1024)) MiB)"
fi

# ---------------------------------------------------------------------------------------------
# 4. Kernel modules from extensions: kernel.tclocal -> usr/local/lib/modules/<ver>/kernel.
# A relative link works both at runtime and for depmod -b (absolute links would resolve on the
# build host).
MD=$W/lib/modules/$KVER
mkdir -p "$W/usr/local/lib/modules/$KVER/kernel"
rm -f "$MD/kernel.tclocal"
ln -s "../../../usr/local/lib/modules/$KVER/kernel" "$MD/kernel.tclocal"
DEPMOD_AT_BOOT=
# Debian's kmod is built without zlib and Tiny Core ships .ko.gz, so depmod runs on a shadow copy
# with decompressed modules; the resulting text indexes (all busybox modprobe reads, and all that
# core.gz ships) get their .ko names mapped back to .ko.gz.
SH=$WORK.shadow
rm -rf "$SH"
mkdir -p "$SH/lib/modules/$KVER"
cp -a "$MD/kernel" "$SH/lib/modules/$KVER/kernel"
cp -a "$W/usr/local/lib/modules/$KVER/kernel" "$SH/lib/modules/$KVER/kernel.tclocal"
find "$SH/lib/modules/$KVER" -name '*.ko.gz' -exec gunzip -f {} +
if depmod -a -b "$SH" "$KVER" 2>"$WORK.depmod.err" && [ -s "$SH/lib/modules/$KVER/modules.dep" ]; then
    rm -f "$MD"/modules.*
    for f in modules.dep modules.alias modules.softdep modules.symbols; do
        [ -f "$SH/lib/modules/$KVER/$f" ] || continue
        sed 's/\.ko\([: ]\|$\)/.ko.gz\1/g' "$SH/lib/modules/$KVER/$f" >"$MD/$f"
    done
    say "depmod: $(wc -l <"$MD/modules.dep" | tr -d ' ') modules indexed ($(grep -c '^kernel.tclocal/' "$MD/modules.dep") from extensions)"
    for m in ntfs3 exfat reiserfs xfs jfs hfsplus dm-mod raid1; do
        grep -q "/$m\.ko\.gz:" "$MD/modules.dep" || say "WARNING: module $m not in modules.dep"
    done
else
    say "WARNING: host depmod failed ($(head -n 3 "$WORK.depmod.err")); will run depmod -a at boot"
    DEPMOD_AT_BOOT=1
fi
rm -rf "$SH"

# ---------------------------------------------------------------------------------------------
# 5. Dynamic linker: make sure /usr/local/lib is searched. The host's x86_64 ldconfig can index
# i386 libraries; the cache is regenerated at boot anyway (::sysinit:/sbin/ldconfig).
grep -qx '/usr/local/lib' "$W/etc/ld.so.conf" 2>/dev/null || echo /usr/local/lib >>"$W/etc/ld.so.conf"
if ldconfig -r "$W" 2>/dev/null; then
    say "ld.so.cache pre-generated with host ldconfig"
else
    say "host ldconfig failed; relying on boot-time ldconfig"
fi

# ---------------------------------------------------------------------------------------------
# 6. Overlay rootfs/ 1:1 (owned by root) and make the client scripts executable.
if [ -d "$SRC/rootfs" ]; then
    cp -a "$SRC/rootfs/." "$W/"
    (cd "$SRC/rootfs" && find . ! -name .DS_Store) | while IFS= read -r p; do
        chown -h 0:0 "$W/$p"
    done
    find "$W" -name .DS_Store -exec rm -f {} +
    if [ -d "$W/opt/retro" ]; then
        find "$W/opt/retro" -type f -name '*.sh' -exec chmod 0755 {} +
    fi
    say "overlaid rootfs/ ($(cd "$SRC/rootfs" && find . -type f | wc -l | tr -d ' ') files)"
else
    say "WARNING: no rootfs/ directory to overlay"
fi

# ---------------------------------------------------------------------------------------------
# 7. Console wrappers launched by init. busybox init passes a minimal environment, so each wrapper
# sets PATH/TERM/HOME itself.
mkdir -p "$W/sbin"
cat >"$W/sbin/retro-tty1" <<EOF
#!/bin/sh
# tty1: the retro-backup UI; falls back to a root shell so the system stays usable.
PATH=$PATH_CONTRACT HOME=/root TERM=\${TERM:-linux}
export PATH HOME TERM
cd /
if [ -x /opt/retro/retro-main.sh ]; then
    exec /opt/retro/retro-main.sh
fi
echo "retro-main: /opt/retro/retro-main.sh not found, starting a shell"
exec /bin/sh -l
EOF
cat >"$W/sbin/retro-tty2" <<EOF
#!/bin/sh
# tty2: root shell, no login.
PATH=$PATH_CONTRACT HOME=/root TERM=\${TERM:-linux}
export PATH HOME TERM
cd /root 2>/dev/null || cd /
echo "retro-backup root shell (tty2). Alt+F1 = backup UI, Alt+F3 = mc, Alt+F4 = log."
exec /bin/sh -l
EOF
cat >"$W/sbin/retro-tty3" <<EOF
#!/bin/sh
# tty3: Midnight Commander as root (shell if mc is missing).
PATH=$PATH_CONTRACT HOME=/root TERM=\${TERM:-linux}
export PATH HOME TERM
cd /mnt 2>/dev/null || cd /
[ -x /usr/local/bin/mc ] && exec /usr/local/bin/mc
exec /bin/sh -l
EOF
cat >"$W/sbin/retro-serial" <<EOF
#!/bin/sh
# ttyS0: root shell on the serial port, only when the kernel console is on ttyS0 (QEMU tests);
# otherwise sleep so init does not respawn-loop on machines without a UART.
PATH=$PATH_CONTRACT HOME=/root TERM=\${TERM:-vt100}
export PATH HOME TERM
case " \$(cat /proc/cmdline) " in
*" console=ttyS0"*) ;;
*) exec sleep 2147483647 ;;
esac
echo
echo "retro-serial: Please press Enter to activate this console."
read -r _ || exec sleep 2147483647
exec /bin/sh -l
EOF
chmod 0755 "$W/sbin/retro-tty1" "$W/sbin/retro-tty2" "$W/sbin/retro-tty3" "$W/sbin/retro-serial"
mkdir -p "$W/root"

BOOTHOOK=
if [ -n "$POSTINST_BOOT" ] || [ -n "$DEPMOD_AT_BOOT" ]; then
    BOOTHOOK=/etc/init.d/retro-preinit
    {
        echo '#!/bin/sh'
        echo '# Generated by build/remaster.sh: work that could not be done at build time.'
        echo "PATH=$PATH_CONTRACT; export PATH"
        [ -n "$DEPMOD_AT_BOOT" ] && echo "/sbin/depmod -a $KVER"
        for name in $POSTINST_BOOT; do
            echo "sh /usr/local/tce.installed/$name >/dev/null 2>&1"
        done
        echo 'exit 0'
    } >"$W$BOOTHOOK"
    chmod 0755 "$W$BOOTHOOK"
fi

# ---------------------------------------------------------------------------------------------
# 8. inittab. Tiny Core's tc-config does not start gettys itself; only inittab does, so replacing
# the tty1 autologin line is enough to keep tty1 for the UI.
{
    echo '# /etc/inittab: busybox init, generated by retro-backup build/remaster.sh'
    echo '::sysinit:/sbin/ldconfig'
    [ -n "$BOOTHOOK" ] && echo "::sysinit:$BOOTHOOK"
    echo '::sysinit:/etc/init.d/rcS'
    echo
    echo 'tty1::respawn:/sbin/retro-tty1'
    echo 'tty2::respawn:/sbin/retro-tty2'
    echo 'tty3::respawn:/sbin/retro-tty3'
    echo '# tty4 is left free for log output (retro.debug / common.sh log)'
    echo 'ttyS0::respawn:/sbin/retro-serial'
    echo
    echo '::restart:/etc/init.d/rc.shutdown'
    echo '::restart:/sbin/init'
    echo '::ctrlaltdel:/sbin/reboot'
    echo '::shutdown:/etc/init.d/rc.shutdown'
} >"$W/etc/inittab"

# ---------------------------------------------------------------------------------------------
# 9. Environment: PATH, hostname, keyboard, console font.
if grep -q '^PATH=' "$W/etc/profile"; then
    sed -i "s|^PATH=.*|PATH=\"$PATH_CONTRACT\"|" "$W/etc/profile"
else
    sed -i "1a PATH=\"$PATH_CONTRACT\"; export PATH" "$W/etc/profile"
fi
grep -q "^PATH=\"$PATH_CONTRACT\"" "$W/etc/profile" || die "failed to set PATH in etc/profile"
# Hostname: tc-config runs /opt/bootsync.sh, which calls "sethostname box" (rewrites etc/hosts).
echo retro >"$W/etc/hostname"
sed -i 's/\([[:space:]]\)box\b/\1retro/g' "$W/etc/hosts"
if [ -f "$W/opt/bootsync.sh" ]; then
    sed -i 's|^/usr/bin/sethostname box$|/usr/bin/sethostname retro|' "$W/opt/bootsync.sh"
    grep -q 'sethostname retro' "$W/opt/bootsync.sh" || say "WARNING: could not set hostname in opt/bootsync.sh"
fi
# Tiny Core's /root/.profile does "exec login -f tc"; root must stay root on every console.
cat >"$W/root/.profile" <<'EOF'
# /root/.profile (retro-backup): stay root; Tiny Core's version switched to the tc user.
[ -f /root/.ashrc ] && . /root/.ashrc
EOF
[ -f "$W/root/.ashrc" ] || cp "$W/etc/skel/.ashrc" "$W/root/.ashrc" 2>/dev/null || true
mkdir -p "$W/etc/sysconfig" && touch "$W/etc/sysconfig/superuser"
# Keyboard: tc-config defaults to KEYMAP=us (and the kernel's built-in map is US); record it.
mkdir -p "$W/etc/sysconfig"
echo KEYMAP=us >"$W/etc/sysconfig/keymap"
# Console font: kernel default (nothing to do; no setfont call anywhere).

# ---------------------------------------------------------------------------------------------
# 10. Repack.
say "repacking"
rm -f "$OUT/retro.gz.tmp"
(cd "$W" && find . | LC_ALL=C sort | cpio -o -H newc --quiet | gzip -9 >"$OUT/retro.gz.tmp")
mv "$OUT/retro.gz.tmp" "$OUT/retro.gz"
cp "$CACHE/vmlinuz" "$OUT/vmlinuz"

csize=$(wc -c <"$OUT/retro.gz" | tr -d ' ')
usize=$(du -sb "$W" | cut -f1)
say "retro.gz: $csize bytes compressed ($((csize / 1048576)) MiB), tree $usize bytes ($((usize / 1048576)) MiB) uncompressed"
if [ "$csize" -gt $((25 * 1048576)) ]; then
    say "WARNING: retro.gz exceeds 25 MiB. Biggest extensions:"
    du -k "$CACHE"/tcz/*.tcz | sort -rn | head -n 10 | sed 's/^/  KiB /' >&2
fi
say "done: $OUT/retro.gz $OUT/vmlinuz"
