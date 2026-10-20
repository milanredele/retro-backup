# Interface contracts between the retro-backup components

Three components are developed independently and meet only at the interfaces below. Change an
interface here first, then in the code. Reference: PLAN.md.

| Component | Directory | Language | Output |
|---|---|---|---|
| Build pipeline | `build/`, `Makefile` | sh, Docker | `out/retro-backup.img`, `out/retro.iso`, `out/vmlinuz`, `out/retro.gz` |
| Client (runs on the old PC) | `rootfs/` (overlaid 1:1 onto the initramfs root) | POSIX sh (busybox ash), awk, dialog | entry point `/opt/retro/retro-main.sh` |
| Helper (runs on a modern machine) | `helper/` | Go, single static binary | PXE server + receiver |
| Tests and fixtures | `test/` | sh, Docker (alpine) | fixture generators, scanner tests |

## 1. Client runtime environment (what the build guarantees the client)

- Base: Tiny Core Linux 16.2 x86, kernel 6.12.11-tinycore, busybox userland, plus the tcz
  extensions listed in `build/tcz.list` unpacked into the initramfs (at least: ntfs-3g, rsync,
  dialog, ncursesw, ncursesw-terminfo, exfatprogs, lvm2, mdadm, testdisk, ddrescue, pv, mc, ncdu,
  findutils, coreutils, file, gawk, sed, grep, util-linux, hdparm, smartmontools, curl,
  filesystems-6.12.11-tinycore, kmaps, glibc_gconv).
- PATH is `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` so GNU find/awk/sed/grep/
  coreutils (installed in /usr/local) win over busybox.
- The build sets `/etc/inittab` so that tty1 runs `/opt/retro/retro-main.sh` as root (respawn),
  tty2 runs a root shell, tty3 a root shell with `mc`. The client never relies on Tiny Core's
  `bootlocal.sh`, `tc` user, or tce loading. Boot codes used: `base norestore noswap nodhcp`.
- The whole system runs from RAM; the client may write freely to `/tmp` and `/run/retro`.
- A `C.UTF-8` locale is installed (`/usr/lib/locale/C.utf8`, copied from Debian's libc-bin at build
  time) and the console font has Latin-2 glyphs, so the UI runs dialog and gawk with
  `LC_ALL=C.UTF-8` and non-ASCII file names display correctly. The default console is the
  800x600 VESA framebuffer (100x37 characters); the UI sizes its boxes from the terminal size.
- Kernel command line parameters understood by the client (all optional):
  - `retro.dest=http://IP:8080` helper URL (set by the helper's generated pxelinux config)
  - `retro.debug=1` verbose logging to `/run/retro/debug.log` and tty4
  - `retro.lang=en` UI language (only `en` in v1)
  - `retro.boot=usb|pxe` informational, set by the respective syslinux config
- The boot pendrive is identified by filesystem labels `RETROBOOT` (p1, FAT32) and `RETRODATA`
  (p2, exFAT). The client must never list these as sources and must never mount `RETROBOOT` rw.

## 2. Client internal files (`/run/retro/`)

`volumes.tsv` written by `10-devices.sh`, one line per mounted source volume, tab-separated:

```
dev        fstype  label        size_bytes    mountpoint        os_hint
/dev/sda1  ntfs3   SYSTEM       80026361856   /mnt/src/sda1     winxp
```
`os_hint` is one of `winxp` (2000/XP/2003: has `Documents and Settings/`), `win7` (Vista+: has
`Users/` and `Windows/`), `linux` (has `/etc` and `/home` or `/root`), `macos` (has `Users/` and
`System/Library`), `data` (none of the above). Mountpoint is `/mnt/src/<basename of dev>`;
LVM volumes use `/mnt/src/<vg>-<lv>`, md arrays `/mnt/src/md0`. Always mounted read-only.

`scan.tsv` written by `20-scan.sh`, one line per selectable group:

```
group_id  dev        pass  category   user    label                          path_rel                                   files  bytes       preselect
g0001     /dev/sda1  A     documents  Jóska   Jóska / My Documents           Documents and Settings/Jóska/My Documents  812    1593440123  1
g0002     /dev/sda1  A     email      Jóska   Jóska / Outlook Express mail   Documents and Settings/Jóska/Local Settings/Application Data/Identities/{GUID}/Microsoft/Outlook Express  14  93847263  1
g0003     /dev/sda1  B     photos     -       D:\Fotók 2007                  Fotók 2007                                 1234   2254857830  0
```
- `pass` A = profile location, B = extension sweep. `category` is one of photos videos documents
  email music archives other. `user` is `-` when not under a profile. `label` is what the UI shows.
- `path_rel` is relative to the volume mountpoint, UTF-8, may contain spaces; never contains tabs
  or newlines (such paths are skipped and logged). A group is a directory, copied recursively,
  except email groups which may name a single file (then `files`=1).
- Pass B groups never overlap pass A groups; B groups never nest inside each other.
- `preselect` 1 = ticked by default in the UI.

`selection.txt`: one `group_id` per line, written by the UI, read by the copy stage.
`dest.conf`: `type=usb|disk|net`, `path=/mnt/dst` (usb/disk) or `url=http://IP:8080` (net).

## 3. Destination layout (identical on a USB target and on the helper)

```
BACKUP/<machine>/<volume>/<path_rel>/...        copied files, original names and tree
BACKUP/<machine>/<volume>/MANIFEST.tsv          path_rel \t size \t mtime_epoch \t md5
BACKUP/<machine>/retro-backup.log               human readable log of the whole session
BACKUP/<machine>/scan.tsv                       copy of the scan result
```
- `<machine>`: Windows computer name if obtainable cheaply, else `<label-or-dev>-<YYYYMMDD-HHMM>`.
  Sanitised to `[A-Za-z0-9._-]`, max 40 chars.
- `<volume>`: FS label sanitised the same way, falling back to the device name (`sda1`).
- File names are passed through as UTF-8. Characters illegal on exFAT/NTFS (`\ / : * ? " < > |`,
  control chars, trailing dot or space) are replaced by `_` on both the USB and the helper side,
  and each rename is logged as `RENAMED <old> -> <new>`.
- Copy preserves mtime; owner, group and mode are not preserved.

## 4. Helper HTTP API (TCP 8080, plain HTTP, no auth; LAN use only)

| Method and path | Body | Response (JSON) |
|---|---|---|
| `GET /status` | none | `{"name":"retro-helper","version":"x.y","dest":"/path","free_bytes":N}` |
| `GET /free` | none | `{"free_bytes":N}` |
| `GET /resume?machine=M&volume=V&group=G` | none | `{"files":[{"path":"rel/path","size":N,"md5":"hex"}]}` files already fully received for that group |
| `POST /upload?machine=M&volume=V&group=G` | uncompressed tar stream (ustar/pax, UTF-8 names relative to `<volume>/`); last member is `.retro-manifest.tsv` in MANIFEST.tsv format covering the members sent | `{"received":N,"bytes":N,"verified":N,"mismatched":["rel/path"],"renamed":[["old","new"]]}` |
| `POST /log?machine=M` | text/plain, appended to `BACKUP/M/retro-backup.log` | `{"ok":true}` |

- The helper writes `<dest>/BACKUP/M/V/<path>` while streaming and hashes each file; a file whose
  md5 differs from the manifest is renamed `<name>.CORRUPT` and listed in `mismatched`.
- A group may be uploaded several times (resume): existing files with matching size+md5 are kept.
- Speed probe: `POST /upload?machine=_probe&volume=_probe&group=_probe` with a tar of junk is
  accepted and discarded (nothing written).
- Discovery beacon: client broadcasts UDP datagram `RETRO-HELPER?` to 255.255.255.255:9999; the
  helper answers `RETRO-HELPER http://<ip>:8080`.

## 5. PXE boot files (served by the helper)

- TFTP root = HTTP root `/boot/`: `lpxelinux.0`, `ldlinux.c32`, `libcom32.c32`, `libutil.c32`,
  `menu.c32`, `vmlinuz`, `retro.gz`, `pxelinux.cfg/default` (generated at start-up with the
  helper's IP: kernel `http://IP:8080/boot/vmlinuz`, `APPEND initrd=http://IP:8080/boot/retro.gz
  quiet nomodeset vga=788 vt.default_utf8=1 norestore noswap nodhcp base rootfstype=ramfs retro.boot=pxe
  retro.dest=http://IP:8080`).
- The build copies the boot files into `helper/bootfiles/` before `go build`; the helper embeds
  whatever is in that directory. With only the placeholder README present the helper still builds
  and runs (receiver and beacon work; PXE requests get 404 and a clear log line).

## 6. Pendrive image (`out/retro-backup.img`)

MBR with syslinux `mbr.bin`, DOS partition table. p1: FAT32, 256 MiB, type 0x0C, active, label
`RETROBOOT`, contains `syslinux.cfg`, `ldlinux.sys`, `vmlinuz`, `retro.gz`, `plpbt.iso`,
`README.txt`. p2: exFAT, label `RETRODATA`, fills the rest (image ships at 1 GiB total; `flash.sh`
grows p2 to the stick on Linux). On first boot the client (`05-stick.sh`) grows p2 to the end
of the stick itself when it is still empty, so a stick flashed from macOS or Windows is fully
usable too; `retro.nogrow=1` disables that. syslinux.cfg `APPEND initrd=retro.gz quiet nomodeset vga=788 vt.default_utf8=1 norestore
noswap nodhcp base rootfstype=ramfs retro.boot=usb`, plus a second entry `safe` with `vga=normal acpi=off
noapic nolapic`. `vga=788` is the 800x600 VESA framebuffer console (100x37 characters); the
build loads the Latin-2 Terminus console font (`Lat2-Terminus16.psf.gz`, with Unicode table) at
boot so Central European file names render; `vt.default_utf8=1` keeps the console in UTF-8.
`rootfstype=ramfs` is mandatory on every boot line: without it the kernel caps the unpacked
initramfs at half of RAM and machines with less than 192 MB lose the tail of the archive.
`out/retro.iso` is the same payload with isolinux for CD-only machines.

## 7. Conventions

- Shell: `#!/bin/sh`, POSIX, must run on busybox ash; `shellcheck -s sh` clean. No bashisms.
- Every client script sources `/opt/retro/lib/common.sh` (logging, i18n, tsv helpers).
- Logging: `log INFO|WARN|ERROR "msg"` goes to `/run/retro/retro-backup.log` (copied to the
  destination at the end) and tty4.
- Tests: `make test` runs everything that does not need QEMU or x86 Docker; `make test-qemu`
  needs qemu-system-i386. No binaries are committed.
