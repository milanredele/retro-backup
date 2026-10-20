# retro-backup — bootable pendrive that salvages user data from old PCs

Status: research done, no code yet. Date: 2026-10-20.

## 1. Goal

A single USB pendrive that:

1. Boots a PC from roughly 2000–2015 (BIOS-era, 32-bit or 64-bit CPU, 128 MB+ RAM) regardless of
   the installed OS (Windows 2000/XP/Vista/7/8, old Linux, possibly old macOS Intel).
2. Mounts every internal disk read-only, scans for user data (photos, videos, documents, email,
   music, archives), and shows a grouped list with counts and sizes.
3. Lets the user tick what to keep and copies it to the pendrive's data partition, with a log and
   a manifest.
4. Is small (tens of MB) and boots in seconds. Text-mode UI; no X, no framebuffer tricks.
5. Can alternatively boot over the LAN (PXE) and copy over the LAN to a helper machine running
   recent Windows, macOS or Linux, for PCs that cannot boot USB or only have USB 1.1 (section 10).

## 2. Existing solutions (researched 2026-10-20) — nothing fits, so we build

| Tool | Verdict |
|---|---|
| Rescuezilla | Imaging tool (Clonezilla-compatible). A "data salvage" tool and a file explorer are roadmap items only; the Image Explorer beta was marked out of service in 2.6. 32-bit build exists but is a 700 MB+ Ubuntu 18.04 desktop. Too big, wrong workflow. |
| SystemRescue | Excellent toolkit but 64-bit only since 9.0.3 (2022). Last 32-bit build is old and still a manual mount-and-copy session. |
| Trinity Rescue Kit | Closest in spirit (text menu, 32-bit, tiny). Abandoned since ~2016/2020, kernel too old for modern pendrives and SATA controllers. |
| Redo Rescue / Clonezilla | Whole-disk imaging, not file-level selection. |
| PhotoRec / TestDisk | File carving from raw sectors. Loses names and folders. Right tool for a *damaged* filesystem, wrong tool for the normal case. Worth bundling as a fallback. |
| Hiren's BootCD PE, Lazesoft, WinPE | 64-bit WinPE, needs 1–2 GB RAM, not redistributable. Out. |
| Finnix, Grml, Puppy, antiX | Generic live systems. antiX/Puppy keep 32-bit non-PAE kernels but are 500 MB–1.7 GB desktop images with no scan-and-pick workflow. |
| GitHub profile backup scripts (PowerShell, USMT front-ends) | Run *inside* Windows; useless when the machine does not boot or is XP. |

Conclusion: the base OS problem is solved (Tiny Core), the "find my stuff and copy it" layer does
not exist. That layer is the product.

## 3. Hardware realities that drive the design

- CPU: pre-2004 machines are 32-bit only; some (Pentium M Banias, early Celeron M, Geode, VIA C3)
  have no PAE. A 32-bit, non-PAE, i486-class kernel runs on everything from 1995 to today. One
  kernel covers all BIOS-boot machines; a 64-bit kernel is only needed for UEFI-only boxes.
- RAM: 128–512 MB is common. Whole system must live in a ~20 MB initramfs and never swap.
- USB: pre-2002 boards have USB 1.1 only (~1 MB/s, 50 GB takes a day). USB 2.0 gives ~25–30 MB/s.
  Old IDE disks top out around 30–60 MB/s. Expect copies to be bandwidth-bound; show ETA honestly.
- BIOS USB boot: boards before ~2003 may not boot USB at all. Ship Plop Boot Manager (plpbt.iso,
  ~1 MB) to burn to CD/floppy as a chain-loader. Some BIOSes want "USB-HDD" emulation: use a
  classic MBR, partition 1 active, CHS-aligned, with syslinux's mbr.bin.
- Filesystems seen in the wild: NTFS (90% of cases), FAT32 (Win98/ME, cameras), ext2/3/4,
  ReiserFS (SUSE 2001–2008 default!), XFS, JFS, LVM (Fedora/RHEL default), HFS+ (Macs).
  ReiserFS was deleted from Linux 6.13, so the kernel must be ≤ 6.12 LTS.
- Never write to the source disk: mount everything `ro`. Hibernated Windows volumes are read-only
  mounted safely by ntfs3; dirty NTFS volumes fall back to ntfs-3g `ro`.
- Pendrive output filesystem: exFAT (no 4 GB file limit, readable on Mac/Win/Linux). Needs a
  separate small FAT32 partition for the bootloader because syslinux cannot boot from exFAT.

## 4. Base system choice: Tiny Core Linux 16.2, x86 (32-bit) — verified facts

Fetched from tinycorelinux.net on 2026-10-20:

- Core-16.2.iso = 19.4 MB. Kernel 6.12.11 (LTS, last ReiserFS kernel). `vmlinuz` 5.8 MB,
  `core.gz` 13.1 MB.
- Kernel config: `CONFIG_M486=y`, no `CONFIG_X86_PAE` → runs on non-PAE CPUs. Built in: UHCI, OHCI,
  EHCI, usb-storage, sd, AHCI, ata_piix, ext4, vfat, fuse, VESA fb + text console. Modules:
  ntfs3, ntfs, exfat, reiserfs, xfs, jfs, hfsplus.
- Extensions present in the x86 repo: `ntfs-3g`, `rsync`, `dialog`, `ncursesw`, `exfatprogs`,
  `lvm2`, `mdadm`, `testdisk` (includes photorec), `ddrescue`, `pv`, `mc`, `ncdu`, `findutils`,
  `coreutils`, `file`, `gawk`, `sed`, `grep`, `util-linux`, `hdparm`, `smartmontools`,
  `syslinux`, `squashfs-tools`, `cpio`, `fdupes`, `sqlite3`, `glibc_gconv`, `kmaps`,
  `filesystems-6.12.11-tinycore` (reiserfs/xfs/jfs/hfsplus modules).
- Everything above remastered into one initramfs is ~20 MB compressed, ~60 MB in RAM.

Alternatives considered: Alpine x86 (newer userland but PAE status unclear and had a non-PAE
regression in 3.18); Buildroot (full control, best end state, but days of work before anything
boots). Plan: Tiny Core now, keep all our code base-agnostic (POSIX sh + standard tools) so a
Buildroot port later is a build-script change.

## 5. Pendrive layout

```
MBR (syslinux mbr.bin), DOS partition table, CHS-aligned
  p1  FAT32  256 MB  label RETROBOOT  active   syslinux + vmlinuz + retro.gz (+ EFI/ for later)
  p2  exFAT  rest    label RETRODATA           BACKUP/<machine>/<volume>/... + logs + manifest
```

Build as a raw `.img` (dd/Etcher/Rufus-DD to any pendrive ≥ 8 GB); p2 is grown to the stick
size on first boot (`sfdisk` + `exfatprogs`) or by the flasher script.

Kernel cmdline: `quiet nomodeset vga=normal norestore noswap nodhcp waitusb=10 base`.
Text console only; `nomodeset` avoids KMS black screens on 2005–2012 GPUs.

## 6. Software architecture (all in `/opt/retro/` inside the initramfs)

```
init (Tiny Core) → /opt/bootlocal.sh → retro-main.sh
   ├─ 10-devices.sh   enumerate block devices, exclude the boot stick, mdadm --assemble, vgchange -ay,
   │                  mount every partition ro at /mnt/src/<dev> (ntfs3 → ntfs-3g fallback; fsck never)
   ├─ 20-scan.sh      emit candidates as TSV: volume \t group \t category \t path \t count \t bytes
   ├─ 30-ui.sh        dialog screens: overview → checklist → confirm → progress → summary
   ├─ 40-copy.sh      rsync per selected group, log, manifest, verify, sync, unmount
   └─ lib/            categories.conf  locations.conf  excludes.conf  i18n
```

Interface rule: the scanner writes a TSV file, the UI reads it. Either side can be rewritten
(e.g. scanner in Go for speed, UI in a nicer TUI) without touching the other.

### 6.1 Scanner — two passes

Pass A, "profiles" (fast, high precision). Detect the OS per volume and enumerate user profiles:

- Windows 2000/XP: `Documents and Settings/<user>/` (skip Default User, All Users except
  `All Users/Documents`, LocalService, NetworkService). Buckets: `My Documents` (incl. My Pictures,
  My Music, My Videos), `Desktop`, `Favorites`, `Application Data`, `Local Settings/Application Data`.
- Windows Vista/7/8/10: `Users/<user>/` → Desktop, Documents, Pictures, Videos, Music, Downloads,
  Favorites, OneDrive, `AppData`; plus `Users/Public`, plus `Windows.old/` (recursive).
- Linux: `/home/*`, `/root`; `/etc/os-release` or `/etc/issue` for the label.
- macOS: `Users/<user>/{Desktop,Documents,Pictures,Movies,Music,Library/Mail}` (bonus, cheap).
- Email stores (exact locations, highest value, easiest to miss):
  - Outlook: `*.pst`, `*.ost` anywhere under the profile (XP: `Local Settings/Application Data/
    Microsoft/Outlook`, 7: `AppData/Local/Microsoft/Outlook` and `Documents/Outlook Files`).
  - Outlook Express: `Local Settings/Application Data/Identities/{GUID}/Microsoft/Outlook Express/*.dbx`
    and address book `Application Data/Microsoft/Address Book/*.wab`.
  - Windows Mail (Vista): `AppData/Local/Microsoft/Windows Mail/`.
  - Windows Live Mail (7): `AppData/Local/Microsoft/Windows Live Mail/`.
  - Thunderbird: `Application Data/Thunderbird/Profiles`, `AppData/Roaming/Thunderbird/Profiles`,
    `~/.thunderbird`, `~/.mozilla-thunderbird`.
  - Eudora `*.mbx`, The Bat!, Pegasus; Linux: `~/Maildir`, `~/mbox`, `/var/mail/*`,
    `~/.evolution`, `~/.kde/share/apps/kmail`, `~/.local/share/evolution`.
  - Browser bookmarks: `Favorites/`, `bookmarks.html`, `places.sqlite`, Chrome `Bookmarks`.
- Pass A output: one group per (user, bucket), each with file count and bytes, pre-ticked.

Pass B, "sweep" (recall). `find` over each volume with prunes (`Windows`, `WINNT`, `Program Files*`,
`ProgramData`, `System Volume Information`, `$Recycle.Bin`, `RECYCLER`, `pagefile.sys`,
`hiberfil.sys`, `*/Temp`, `Temporary Internet Files`, `*/Cache*`, `/usr`, `/lib*`, `/var/cache`,
`/proc`, `/sys`, `node_modules`, `lost+found`, and anything already claimed by pass A), matching
by extension per category. Aggregate per directory with `awk`; fold a directory into its parent
when the parent is ≥ 90 % the same category; present "hot folders" sorted by size, e.g.
`D:\Fotók 2007   1 234 photos   2.1 GB`. Not pre-ticked.

Categories (editable `categories.conf`):

- photos: jpg jpeg png gif bmp tif tiff heic heif webp psd cr2 nef arw dng orf raf rw2 pef srw
- videos: avi mpg mpeg mp4 m4v mov wmv asf mkv 3gp flv vob mts m2ts mod tod rm rmvb divx
- documents: doc docx xls xlsx ppt pptx pdf rtf txt odt ods odp sxw wpd wps pub one csv epub mobi
  djvu xps tex md
- email: pst ost dbx wab mbx mbox eml msg nws (plus the directory rules above)
- music: mp3 wma m4a aac flac wav ogg ape wv mid
- archives: zip rar 7z tar gz bz2 iso (off by default)
- everything else under a user profile: "other user files" (off by default)

Speed: `find` (GNU findutils, for `-printf`) streams; awk aggregates in RAM. ~1 M files on a
2005 PC should scan in a few minutes; disk seek time dominates, not CPU.

### 6.2 UI (dialog, 80x25 VGA text, works on every machine)

1. Boot splash → auto-run; `Esc` at any point drops to a shell / `mc` for manual work.
2. Scanning: `dialog --gauge` with per-volume progress.
3. Overview checklist: tree-ish list, grouped by volume → user → bucket, then "hot folders"
   from the sweep. Keys: space toggle, `a` all, `n` none, `i` info (top 20 files of a group).
4. Destination: RETRODATA partition, a second USB disk, or a network helper (section 10).
   Confirm: total selected vs free space, ETA from a 10-second throughput probe on that channel.
5. Copy: `rsync` per group with `--info=progress2`, total gauge, per-file line, error count.
6. Summary: copied / skipped / unreadable, log path, "safe to remove" after `sync` + unmount.
   Options: back to list (copy more), power off, reboot.
Language: English first; strings in one file so Hungarian can be added.

### 6.3 Copy

- `rsync -rt --modify-window=2 --no-perms --no-owner --no-group --partial --ignore-errors
  --info=progress2` from `/mnt/src/<vol>/<path>` to `/mnt/dst/BACKUP/<machine>/<vol>/<path>`.
  Destination path keeps the original structure so the user can find things later.
- `<machine>` = Windows ComputerName from the registry if cheap (`chntpw`/`reged` not needed:
  read `SYSTEM` hive is overkill) → fall back to volume label + serial + date.
- Illegal exFAT characters (`: * ? " < > |`, trailing dots) only occur on Linux/mac sources:
  rename with `_` and record in the manifest. Unicode names from NTFS pass through (UTF-8).
- Unreadable files (bad sectors): rsync skips and logs; summary offers "retry with ddrescue per
  file" as a later feature. v1 just lists them.
- After copy: `MANIFEST.tsv` (path, size, mtime, md5 — md5 on a 2004 CPU is ~100 MB/s, well
  above USB 2.0 speed, so it is free), `retro-backup.log`, then `sync`, unmount, flush.
- Safety: source mounted `ro`, destination is only ever our own labeled partition or a disk the
  user explicitly picked, no formatting ever happens on the target machine.

## 7. Build pipeline (`build/`), runs on Linux or in Docker on the Mac

1. `fetch.sh` — download vmlinuz, core.gz, listed `.tcz` + their `.dep` closure from the 16.x/x86
   mirror; verify `.md5.txt`.
2. `remaster.sh` — unpack core.gz (fakeroot + cpio), unsquash each tcz into the tree, copy
   `/opt/retro/`, write `/opt/bootlocal.sh`, set console font/keymap, repack `retro.gz`
   (gzip -9; kernel supports it on every CPU). Target ≤ 20 MB.
3. `image.sh` — create `retro-backup.img`: sfdisk layout, mkfs.vfat p1, mkfs.exfat p2, copy
   kernel + initramfs + `syslinux.cfg`, `syslinux -i`, write `mbr.bin`. Also emit `retro.iso`
   (isolinux) for the CD-only fallback, and bundle `plpbt.iso`.
4. `test-qemu.sh` — boots the image with a synthetic "victim" disk:
   - `-cpu pentium3 -m 256` (no PAE, no SSE2), `-cpu pentium -m 128` (worst case),
     `-cpu qemu64 -m 2048` (2010s), `-usb -device usb-ehci` and `-device piix3-usb-uhci` (USB 1.1).
   - Victim images built with `mkfs.ntfs` + ntfs-3g containing a fake XP tree
     (`Documents and Settings/Jóska/My Documents/...`, OE `.dbx`, Outlook `.pst`), a Win7 tree,
     an ext3+ReiserFS Linux tree with `~/.thunderbird`, a FAT32 camera card. Checked into
     `test/fixtures/` as generator scripts, not binaries.
   - Assertions: expected groups appear with expected counts; selected groups copy byte-exact;
     nothing is written to the victim (compare hashes before/after).
5. Real hardware checklist (the only thing QEMU cannot prove): boot on 3–4 actual machines
   (one pre-2004 with USB 1.1 + Plop, one XP-era P4, one Win7 Core2, one UEFI/CSM laptop).

## 8. Milestones

Status 2026-10-20: milestones 1, 1b (helper side), 2 and 3 are implemented and pass in QEMU
(`make test`, `make test-e2e`); nothing has run on real hardware yet (milestone 4). Open:
PXE boot of a QEMU guest from the helper (needs a tap/vmnet network, not done), UEFI, photorec
screen, Windows ComputerName, and harmonising the trailing-dot rename rule between client
(only the last char) and helper (every char of the trailing run).

1. **Boots and mounts** (1–2 days): image builds reproducibly, boots in QEMU on `pentium3`,
   all victim partitions mounted ro, device list on screen. Deliverable: `retro-backup.img`.
1b. **Netboot + helper** (2–3 days): the Go helper serves proxy-DHCP/TFTP/HTTP and the same
   kernel+initramfs boots a QEMU guest over PXE from a Windows, macOS and Linux host; the helper
   receives a tar stream and writes files with verified md5. Deliverable: `retro-helper` binaries.
2. **Scanner** (2–3 days): passes A and B produce correct TSV on all fixtures; unit tests in sh.
3. **UI + copy** (2–3 days): full flow end to end in QEMU, manifest, log, poweroff.
4. **Hardware shakedown** (ongoing): real old machines, Plop path, USB 1.1 timing, keymap.
5. **Nice-to-have, later**: UEFI 64-bit boot entry (TC x86_64 kernel on the same stick) and
   UEFI PXE (`ipxe.efi` → 64-bit kernel) from the same helper,
   photorec fallback screen for dead filesystems, per-file ddrescue retry, Hungarian UI,
   dedup of identical files across users (`fdupes` is in the repo), Go scanner if sh is too slow.

## 9. Open questions / risks

- Tiny Core remaster vs. Buildroot: TC gets us booting today; if we hit a kernel driver gap on
  real hardware (unlikely with this config) Buildroot is the escape hatch.
- Hibernated or BitLocker/EFS-encrypted volumes: hibernated is fine read-only; BitLocker and EFS
  are out of scope (XP/7 home users rarely used them). Detect and say so.
- Disks that are physically dying: scanning hammers them. v1 shows SMART status up front
  (`smartctl -H`) and warns; imaging with ddrescue first is a separate workflow.
- The pendrive's own write speed matters: pick a USB 3.x stick with decent sustained writes
  (many cheap sticks drop to 5 MB/s after the cache fills).
- Windows (before 10 1703) only shows the *first* partition of a removable stick, so RETRODATA
  is invisible on old Windows machines. Irrelevant here (the stick is read back on a modern
  machine), but worth a line in the README. If it ever matters, swap the partition order and
  use a boot-sector trick, or put data first and boot second with syslinux pointing at p2.

## 10. LAN boot and network copy (added 2026-10-20)

### 10.1 Why

- Boot: business PCs and laptops from ~2000 on have PXE; consumer boards got it with onboard LAN
  around 2002–2004 (often disabled by default). USB boot in the same years is absent or limited to
  flaky USB-ZIP/FDD emulation. For pre-2003 machines LAN is the more reliable boot path.
- Speed: before ~2002 the PC has USB 1.1 (~1 MB/s) but 100 Mbit Ethernet (~11 MB/s): LAN is 10x
  faster. 2003–2005: USB 2.0 (25–35 MB/s) beats 100 Mbit. 2006+: gigabit LAN (60–100 MB/s) beats
  USB 2.0, though the old disk is then the limit. So LAN matters most exactly where USB hurts most.
- Boot medium and destination are independent: PXE-boot and copy to the helper, USB-boot and copy
  over LAN, PXE-boot and copy to a USB disk — all combinations must work.

### 10.2 Helper machine requirements (hard requirement: recent Windows, macOS or Linux)

No dnsmasq, Tftpd64, rsync, NFS or Samba on the helper. One static Go binary, `retro-helper`,
built for windows/amd64, darwin/arm64+amd64, linux/amd64+arm64 (a Raspberry Pi works). It runs
unprivileged (UDP 67/69 and TCP 8080 need no admin on Windows or macOS; on Linux either
`setcap cap_net_bind_service` or run with sudo). It does four things:

1. **Proxy DHCP** (PXE only, no IP leases): answers PXE clients' DHCPDISCOVER with option 60
   `PXEClient` + option 43 boot-server info and serves port 4011. Coexists with the home router
   that keeps handing out addresses. This is the default "switch or router" mode: nothing to
   configure on the network.
2. **Direct-cable mode** (opt-in flag): full DHCP server for one subnet (10.99.0.0/24) when the
   old PC is cabled straight to the helper and there is no router. The helper tells the user to
   set its own NIC to 10.99.0.1/24 (or does it with elevation on request). 100 Mbit NICs need a
   crossover cable or a cheap switch; gigabit NICs auto-cross.
3. **TFTP + HTTP boot server**: `pxelinux.0` (BIOS) via TFTP, then `vmlinuz` and `retro.gz` via
   HTTP (`lpxelinux.0` supports http paths; ~3 s for 20 MB at 100 Mbit instead of 20–30 s over
   TFTP). The helper generates `pxelinux.cfg/default` itself and injects
   `retro.dest=http://<helper-ip>:8080` into the kernel command line. Later: `ipxe.efi` /
   `syslinux.efi` + 64-bit kernel for UEFI-only PXE clients.
4. **Receiver**: `POST /upload?machine=..&volume=..&group=..` takes an uncompressed tar stream and
   unpacks it on the fly under `<dest>/BACKUP/<machine>/<volume>/...`, hashing each file (md5)
   while writing; the client appends the manifest as the last tar member and the helper verifies
   and reports mismatches. `GET /status`, `GET /free` (free space for the confirm screen),
   `GET /resume?group=` (which files already arrived, so a dropped link resumes at file level).
   Illegal NTFS/Windows filename characters on a Windows helper are sanitised the same way as
   for exFAT (section 6.3) and logged.

Helper UI: a console program that prints "listening on 192.168.1.23 (en0) — waiting for PXE
clients", one line per event, and a final per-machine summary. Interface picker on start-up when
there are several (Windows: Hyper-V/WSL virtual switches; macOS: Thunderbolt bridges). Windows
firewall prompt: allow on private networks. Note ICS (Internet Connection Sharing) runs its own
DHCP on 192.168.137.x and must be off in direct-cable mode. A `dnsmasq.conf` example is shipped
for Linux people who prefer their own server; it is not the supported path.

Go libraries (all pure Go, cross-platform): `insomniacslk/dhcp` (server4, proxy-DHCP replies),
`pin/tftp`, net/http, archive/tar. Prior art for the DHCP/TFTP part: pixiecore (Linux-only
because of raw sockets; we avoid raw sockets so Windows works).

### 10.3 Client side (same initramfs as the USB build)

- Add nothing for netboot: Tiny Core officially supports PXE with the same `vmlinuz` + initramfs.
  Verify in milestone 1b that the wired NIC drivers for the era are in the base modules
  (e100, e1000, 8139too, 8139cp, 3c59x, tg3, r8169, forcedeth, via-rhine, sis900, skge, sky2,
  pcnet32 for QEMU/VMware); add any missing one to the remaster.
- `50-net.sh`: bring up eth* with `udhcpc`; find the helper by (a) `retro.dest=` on the kernel
  command line, (b) a UDP broadcast beacon on port 9999 answered by the helper (covers USB-booted
  machines), (c) a typed IP in the UI. Probe throughput for 10 s for the ETA.
- Transfer: `tar -c` per selected group piped into `curl -T -` (or a 200-line Go uploader if curl
  is too heavy; `curl.tcz` is small). No compression and no TLS: a Pentium III does ~10 MB/s of
  SSH/AES and would nullify the LAN gain; gzip is equally CPU-bound. Plain HTTP on a private LAN
  is acceptable for this use case and is stated in the UI.
- Progress: bytes sent / total, per-group, same gauge as the USB path. Dropped link: retry the
  group with `/resume`, skipping files the helper already has.
- Both destinations at once (USB partition + helper) are allowed; the manifest records where each
  group went.

### 10.4 Build and test additions

- `build/helper/`: Go module, `make helper` cross-compiles the five binaries; the boot files
  (`pxelinux.0`, `lpxelinux.0`, `ldlinux.c32`, `vmlinuz`, `retro.gz`) are embedded in the binary
  (`embed`), so the helper is a single file to copy to any machine.
- `test-qemu.sh --pxe`: QEMU guest with `-boot n -netdev user` is not enough for proxy-DHCP; use a
  tap/bridge on Linux and `vmnet` on macOS, or simplest: run the helper in direct-cable mode on a
  host-only network. Assert the guest boots and a 1 GB group arrives with a matching manifest.
  Run the helper test on all three OSes in CI (GitHub Actions has runners for all of them;
  the QEMU boot test is Linux-only, the receiver tests run everywhere).
- Real hardware: one pre-2003 PC with PXE-capable onboard NIC or a 3C905C, booted from a Windows
  11 laptop and from the Mac, through a dumb switch on the home router, and once over a direct
  cable.

### 10.5 Risks specific to LAN

- Some 2000–2002 Realtek boot ROMs speak only RPL/Netware boot, not PXE 2.1: the machine lists
  "boot from LAN" but never DHCPs. Fallback is the Plop CD.
- Proxy DHCP on a network with a Windows Server DHCP/WDS or a managed switch with DHCP snooping
  can be blocked; home networks are fine. Direct-cable mode is the universal escape hatch.
- Windows helper: Defender SmartScreen warns on an unsigned binary; document it or sign later.
- macOS helper: the OS asks "allow incoming connections" for the binary once.
- Wi-Fi is never used on the old PC; the helper may be on Wi-Fi only if the old PC is cabled to
  the same router (proxy mode), with correspondingly lower throughput.
