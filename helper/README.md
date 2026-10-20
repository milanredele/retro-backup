# retro-helper

`retro-helper` is the program that runs on a modern machine (Windows 10/11, macOS 13+, Linux,
also a Raspberry Pi) next to the old PC. It is a single static binary with no installer and it
needs no admin rights on Windows or macOS. It does three jobs:

1. **Receiver.** An HTTP API on TCP 8080 (CONTRACTS.md section 4). The retro-backup client
   streams one tar per selected group. The helper unpacks it on the fly into
   `--dest/BACKUP/<machine>/<volume>/`, hashes every file and checks it against the manifest.
2. **Discovery beacon.** It listens on UDP 9999. When a client sends `RETRO-HELPER?` it answers
   `RETRO-HELPER http://<ip>:8080`, so a USB-booted PC finds the helper on its own.
3. **PXE boot server** (only with `--pxe`). It boots old PCs over the network: proxy DHCP
   (UDP 67 and 4011), TFTP (UDP 69) for `lpxelinux.0`, and HTTP `/boot/` for the kernel and
   initrd. Without `--pxe` the helper never touches DHCP.

## Building

```sh
cd helper && ./build-all.sh        # five binaries in ../out/helper/
cd helper && go test ./...         # unit and end-to-end tests (no root, no network needed)
```

`build-all.sh` cross-compiles with `CGO_ENABLED=0 -trimpath -ldflags "-s -w -X main.version=..."`
for windows/amd64, darwin/arm64, darwin/amd64, linux/amd64 and linux/arm64. The output is
`out/helper/retro-helper-<os>-<arch>[.exe]`. Set `VERSION=1.0` to override the version string.

The binary embeds whatever is in `helper/bootfiles/`. The top-level `make helper` target (it
belongs to the build pipeline) should:

1. copy `lpxelinux.0`, `ldlinux.c32`, `libcom32.c32`, `libutil.c32`, `menu.c32` (from syslinux
   6.03 `bios/`), `out/vmlinuz` and `out/retro.gz` into `helper/bootfiles/`;
2. run `cd helper && ./build-all.sh`.

When only the placeholder README is in `bootfiles/`, the helper still builds and works as a
receiver. With `--pxe` it logs `boot files missing, run make helper` once and answers boot-file
requests with 404 / TFTP "file not found". `pxelinux.cfg/default` is never embedded. The helper
generates it at start-up with its own IP (CONTRACTS.md section 5). It has a `retro` entry,
booted after 5 s, and a `safe` entry (`acpi=off noapic nolapic`) that you get by typing `safe`
at the `boot:` prompt.

## Quick start

```sh
retro-helper                                  # receiver only, into ./retro-backup-received
retro-helper --dest D:\Backups                # receiver only, another destination
retro-helper --pxe --iface en0                # also PXE-boot old PCs through the router's LAN
retro-helper --pxe --iface Ethernet --dhcp-range 10.99.0.100-10.99.0.200   # direct cable
retro-helper --help                           # every flag
```

On start-up it prints one line like this, then one line per event (PXE discover, TFTP file
sent, beacon answer, HTTP request, upload progress every 10 s with MB/s, upload summary):

```
12:00:01 retro-helper 0.1 listening on http://192.168.1.23:8080 (en0, dest=/Users/me/retro-backup-received, free=412.3 GiB) — waiting
```

Ctrl-C stops it cleanly and prints the totals per machine. Press Ctrl-C a second time to quit
at once.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | runtime error |
| 2 | bad flags, or `--iface` needed |
| 3 | a port could not be opened; the message includes an OS-specific hint |

### Choosing the interface

The helper never guesses which network the old PC is on. Hyper-V/WSL switches on Windows, and
bridges and VM networks on macOS, make guessing wrong. With `--pxe`, if more than one interface
has an IPv4 address, the helper lists them and exits:

```
retro-helper: several network interfaces have IPv4 addresses; choose the one the old PC is connected to with --iface NAME:
  en0                      192.168.0.153/24
  bridge100                192.168.64.1/24
```

Interface names:

- Windows: the adapter name, for example `--iface Ethernet` or `--iface "Ethernet 2"`.
- macOS: `en0`, `en7` (USB/Thunderbolt Ethernet).
- Linux: `eth0`, `enp3s0`.

Without `--pxe` the receiver listens on every interface and prints every address.

## Wiring: which mode?

| Setup | Command | What happens |
|---|---|---|
| Old PC and helper both plugged into the home router or a switch on it | `--pxe --iface X` | **Proxy DHCP.** The router keeps handing out addresses. The helper only adds boot information, and only for PXE clients (option 60 `PXEClient`). Nothing to configure. The helper may be on Wi-Fi, but expect lower speed. |
| Old PC cabled straight to the helper, no router | `--pxe --iface X --dhcp-range 10.99.0.100-10.99.0.200` | **Direct cable.** The helper is the only DHCP server: 1 h leases from the range, mask 255.255.255.0, router and DNS = the helper. **The helper NIC must have the static address 10.99.0.1/24** (see your OS below). The helper checks for this and warns if it is missing. A 100 Mbit NIC needs a crossover cable or a small switch; gigabit NICs auto-cross. |
| USB-booted old PC, any network | (no `--pxe`) | Receiver and beacon only. |

At start-up with `--pxe` the helper sends one test DHCPDISCOVER (random MAC) from UDP 68, if
that port is free. In proxy mode it warns when *no* DHCP server answers, because the old PC
would get no address. In direct-cable mode it warns when *another* DHCP server answers. The
test is skipped when the OS DHCP client holds port 68, which is common.

## Windows 10/11

- **SmartScreen.** The binary is unsigned. Click "More info" > "Run anyway". Or open
  right-click > Properties and tick "Unblock" before the first start.
- **Firewall prompt.** On first start Windows asks whether to allow `retro-helper`. Allow it
  on **Private networks**. Your network must be set to Private (Settings > Network & internet >
  Ethernet/Wi-Fi > Network profile type > Private); on a Public network the prompt's rule does
  not apply. If you dismissed the prompt, go to Windows Security > Firewall > "Allow an app
  through firewall".
- **No admin rights needed.** Ports 67, 69, 4011, 8080 and 9999 are not privileged on Windows.
- **Internet Connection Sharing (ICS) must be off in direct-cable mode.** ICS runs its own DHCP
  server on 192.168.137.x. Turn it off in the adapter's Properties > Sharing tab, or stop the
  "Internet Connection Sharing (ICS)" service. If UDP 67 is busy, the helper exits with code 3
  and says so. Other PXE servers (Tftpd64, WDS) must be stopped too.
- **Setting 10.99.0.1 for direct-cable mode.** Use Settings > Network & internet > Ethernet >
  IP assignment > Edit > Manual > IPv4 on: IP address `10.99.0.1`, subnet mask
  `255.255.255.0`, gateway and DNS empty. Or, in an administrator prompt:

  ```
  netsh interface ipv4 set address name="Ethernet" static 10.99.0.1 255.255.255.0
  ```

  To go back to DHCP afterwards: `netsh interface ipv4 set address name="Ethernet" dhcp`.
  On Windows the address must exist before the helper starts, because the DHCP socket is
  bound to it.
- If PXE clients are never answered, try `--dhcp-bind-any`. It binds 0.0.0.0:67 instead of the
  interface address.

## macOS 13+

- **First start.** The binary is not notarized. Run `xattr -d com.apple.quarantine
  ./retro-helper-darwin-arm64` once, or right-click > Open in Finder.
- **Incoming connections.** macOS asks once "Do you want the application to accept incoming
  network connections?". Click **Allow**.
- **No sudo needed.** macOS lets normal users bind ports below 1024 on all addresses.
- **UDP 67 busy.** `bootpd` owns UDP 67 while Internet Sharing is on (System Settings > General
  > Sharing), and while a VM app with shared/NAT networking runs (`bridge100`: UTM, Parallels,
  VMware Fusion, Docker Desktop, Lima, OrbStack). Turn sharing off and quit those apps before
  `--pxe`. The helper exits with code 3 and this hint.
- **Setting 10.99.0.1 for direct-cable mode.** Go to System Settings > Network > (the Ethernet
  adapter) > Details > TCP/IP > Configure IPv4: Manually. Set IP address `10.99.0.1`, subnet
  mask `255.255.255.0`, router empty. Or use
  `sudo networksetup -setmanual "USB 10/100/1000 LAN" 10.99.0.1 255.255.255.0`; list the
  service names with `networksetup -listallnetworkservices`.

## Linux

- **Ports.** UDP 67 and 69 are privileged. Either run with `sudo`, or allow the binary once:

  ```sh
  sudo setcap cap_net_bind_service=+ep ./retro-helper-linux-amd64
  ```

  The receiver alone (port 8080) and the beacon need nothing.
- **Port conflicts.** Stop `dnsmasq`, `isc-dhcp-server`, `tftpd-hpa` or libvirt's dnsmasq on
  the same interface. `sudo ss -ulpn` shows who owns a port.
- **Firewall.** Open UDP 67, 69, 4011 and 9999, and TCP 8080. For example:
  `sudo ufw allow 67,69,4011,9999/udp && sudo ufw allow 8080/tcp`.
- **Direct-cable address.** `sudo ip addr add 10.99.0.1/24 dev eth0`, or set it in
  NetworkManager.

## Ports

| Port | Protocol | Purpose | When |
|---|---|---|---|
| 8080 (`--listen`) | TCP | receiver API and `/boot/` files (HTTP Range supported) | always |
| 9999 (`--beacon-port`) | UDP | discovery beacon | always (0 disables it) |
| 67 | UDP | proxy DHCP, or full DHCP with `--dhcp-range` | `--pxe` |
| 4011 | UDP | PXE boot-server requests | `--pxe` |
| 69 | UDP | TFTP with blksize and tsize options | `--pxe` |
| 68 | UDP | one-off check for other DHCP servers | `--pxe`, skipped when busy |

## What the destination looks like

```
retro-backup-received/
  BACKUP/
    JOSKA-PC/                         <machine>, sanitised to [A-Za-z0-9._-], max 40
      retro-backup.log                appended by POST /log
      SYSTEM/                         <volume>
        MANIFEST.tsv                  path \t size \t mtime \t md5, all groups of the volume
        Documents and Settings/Jóska/My Documents/...   original names and tree, mtime kept
        Documents and Settings/Jóska/My Documents/report_ final_.txt   renamed from "report: final?.txt"
        Fotók 2007/kép 001.jpg.CORRUPT                  md5 differed from the manifest
        .retro-index/                 helper bookkeeping, do not edit
          g0001.tsv                   files that arrived complete (used by GET /resume)
          g0001.manifest.tsv          the group's manifest, stored paths
```

- Characters that exFAT/NTFS cannot store (`\ / : * ? " < > |`, control characters, trailing
  dots or spaces) become `_` on every helper OS, the same as on the USB side. Each rename is
  logged as `RENAMED old -> new` and returned in `renamed`. Two names that sanitise to the same
  name get `~2`, `~3` before the extension. On a Windows helper, device names such as `CON` or
  `nul.txt` also get a `_`.
- Symlinks, hard links, devices, absolute paths and names with `..` are rejected, logged and
  listed in `rejected`. Nothing is ever written outside `BACKUP/<machine>/<volume>/`.
- Files are written as `<name>.retro-part` and renamed when complete. A dropped connection
  never leaves a truncated file under the real name. `GET /resume` lists every file that did
  arrive.
- A re-upload of a group keeps the files that are already there with the same size and md5.
- The speed probe (`machine=_probe`) is read and discarded. Nothing is written.

The upload response has the contract fields (`received bytes verified mismatched renamed`).
It also has these extras, which a client may ignore:

| Field | Meaning |
|---|---|
| `kept` | files already present with the same content |
| `missing` | in the manifest, never received |
| `unlisted` | received, not in the manifest |
| `rejected` | members refused (see above) |
| `errors` | per-file errors |
| `manifest` | whether a manifest was seen |
| `body_bytes` | request bytes read |
| `machine`, `volume`, `group` | the sanitised names |
| `error` | the fatal error, with status 400 for a broken tar stream, 507 for a full disk, 409 if the same group is already uploading |

## Troubleshooting

- **The old PC lists "boot from LAN" but never shows a DHCP line.** Many Realtek and some
  other boot ROMs from 2000–2002 speak only RPL/NetWare, not PXE 2.x. Boot the Plop CD (or the
  pendrive) instead and copy over the LAN.
- **"PXE-E51: No DHCP or proxyDHCP offers were received".** Check these in order:
  - Is `--pxe` on, with the right `--iface`?
  - Did the firewall prompt get "Allow"?
  - Is the network profile Private (Windows)?
  - In proxy mode, does the router give the PC an address at all?
  - On a direct cable, is it `--dhcp-range` with 10.99.0.1 set?

  Managed switches with spanning tree can hold a port down for 30 s after link-up. That is
  longer than the ROM's DHCP timeout. Enable PortFast or plug both machines into a dumb switch.
- **"PXE-E53/E32: TFTP open timeout" or "file not found".** The firewall blocks UDP 69, or the
  binary was built without boot files (the log says `boot files missing, run make helper`).
- **Nothing happens on a UEFI-only machine.** Only BIOS PXE (`lpxelinux.0`) is supported. The
  helper logs `only BIOS PXE is supported` and does not answer UEFI clients. Switch the machine
  to Legacy/CSM boot, or use the pendrive.
- **Corporate or school networks.** Windows Server DHCP/WDS, or a managed switch with DHCP
  snooping, can block proxy DHCP. Use direct-cable mode.
- **The client cannot find the helper.** The beacon needs UDP 9999 open in the helper's
  firewall. As a fallback, type the URL printed at start-up into the client.
