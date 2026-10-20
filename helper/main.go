// Command retro-helper is the helper-machine side of retro-backup: a
// receiver for the client's tar uploads, a discovery beacon and, with --pxe,
// a proxy-DHCP (or direct-cable DHCP) + TFTP + HTTP boot server.
// See README.md and CONTRACTS.md sections 3-5.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// version is set by build-all.sh with -ldflags "-X main.version=...".
var version = "0.1-dev"

const (
	exitOK     = 0
	exitError  = 1
	exitUsage  = 2
	exitBind   = 3
	directMask = 24
)

type options struct {
	listen     string
	dest       string
	iface      string
	pxe        bool
	dhcpRange  string
	bindAny    bool
	bootFile   string
	beaconPort int
	noCheck    bool
	version    bool
}

func usage(fs *flag.FlagSet) func() {
	return func() {
		w := fs.Output()
		fmt.Fprintf(w, `retro-helper %s - receiver and PXE boot server for retro-backup

Run it on a modern Windows, macOS or Linux machine on the same network as the
old PC. Without --pxe it only receives backups (HTTP API on --listen) and
answers the client's discovery beacon. With --pxe it also boots old PCs over
the network: proxy DHCP next to your router (default), or a full DHCP server
for a PC cabled straight to this machine (--dhcp-range).

Usage:
  retro-helper [flags]

Flags:
`, version)
		fs.PrintDefaults()
		fmt.Fprint(w, `
Examples:
  retro-helper                                   receive into ./retro-backup-received
  retro-helper --pxe --iface en0                 PXE-boot old PCs through the router's LAN
  retro-helper --pxe --iface Ethernet --dhcp-range 10.99.0.100-10.99.0.200
                                                 direct cable; this NIC must be 10.99.0.1/24

Exit codes: 0 ok, 1 runtime error, 2 bad flags or interface choice needed,
3 a port could not be opened (another server running, or missing privileges).
`)
	}
}

func parseFlags(args []string) (*options, error) {
	o := &options{}
	fs := flag.NewFlagSet("retro-helper", flag.ContinueOnError)
	fs.StringVar(&o.listen, "listen", ":8080", "`address` of the HTTP receiver and /boot/ file server (TCP)")
	fs.StringVar(&o.dest, "dest", "./retro-backup-received", "destination `directory`; backups go to DIR/BACKUP/<machine>/<volume>/")
	fs.StringVar(&o.iface, "iface", "", "network interface `name` to serve on (e.g. en0, eth0, \"Ethernet 2\"); required with --pxe when the machine has several")
	fs.BoolVar(&o.pxe, "pxe", false, "serve PXE boot: proxy DHCP on UDP 67 and 4011 next to the router's DHCP, TFTP on UDP 69, files at http://IP:PORT/boot/")
	fs.StringVar(&o.dhcpRange, "dhcp-range", "", "direct-cable mode: lease addresses `FIRST-LAST` (e.g. 10.99.0.100-10.99.0.200); implies --pxe and runs a full DHCP server (mask /24, router and DNS = this machine, 1 h leases); this NIC must have the .1 address of that /24")
	fs.BoolVar(&o.bindAny, "dhcp-bind-any", false, "Windows only: bind the DHCP socket to 0.0.0.0 instead of the interface address (try this if PXE clients are never answered)")
	fs.StringVar(&o.bootFile, "boot-file", "lpxelinux.0", "boot loader `file` offered to PXE clients (DHCP option 67)")
	fs.IntVar(&o.beaconPort, "beacon-port", 9999, "UDP `port` of the discovery beacon (0 disables it)")
	fs.BoolVar(&o.noCheck, "no-dhcp-check", false, "skip the start-up check for other DHCP servers on the LAN")
	fs.BoolVar(&o.version, "version", false, "print the version and exit")
	fs.Usage = usage(fs)
	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	if fs.NArg() > 0 {
		return nil, fmt.Errorf("unexpected argument %q (see --help)", fs.Arg(0))
	}
	if o.dhcpRange != "" {
		o.pxe = true
	}
	return o, nil
}

// bindHint explains the usual cause of a failed bind on this OS.
func bindHint(proto string, port int) string {
	switch runtime.GOOS {
	case "windows":
		switch port {
		case dhcpServerPort, pxeBootPort:
			return "another DHCP/PXE server owns this port: turn off Internet Connection Sharing (adapter Properties > Sharing, or stop the \"Internet Connection Sharing (ICS)\" service), and stop Tftpd64/WDS/other PXE servers"
		case 69:
			return "another TFTP server (Tftpd64, WDS, Windows TFTP client is fine) is running"
		}
	case "darwin":
		switch port {
		case dhcpServerPort:
			return "bootpd owns UDP 67: it is started by Internet Sharing (System Settings > General > Sharing) and by virtual-machine apps with shared/NAT networking (bridge100: UTM, Parallels, VMware Fusion, Docker Desktop, Lima, OrbStack); turn sharing off and quit those apps, then try again"
		case 69:
			return "the built-in tftpd is running: sudo launchctl unload -w /System/Library/LaunchDaemons/tftp.plist"
		}
	case "linux":
		if port < 1024 {
			return "ports below 1024 need privileges: run with sudo, or once: sudo setcap cap_net_bind_service=+ep ./retro-helper; also check that dnsmasq or another DHCP/TFTP server is not running (sudo ss -ulpn)"
		}
	}
	return fmt.Sprintf("another program uses %s port %d (choose another with the flags, or stop it)", proto, port)
}

type bindError struct {
	what string
	err  error
	hint string
}

func (e bindError) Error() string {
	return fmt.Sprintf("cannot open %s: %v\n  hint: %s", e.what, e.err, e.hint)
}

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	o, err := parseFlags(args)
	if errors.Is(err, flag.ErrHelp) {
		return exitOK
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "retro-helper:", err)
		return exitUsage
	}
	if o.version {
		fmt.Println("retro-helper", version)
		return exitOK
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	code, err := serve(ctx, o)
	if err != nil {
		fmt.Fprintln(os.Stderr, "retro-helper:", err)
	}
	return code
}

func httpPort(listen string) (int, error) {
	_, p, err := net.SplitHostPort(listen)
	if err != nil {
		return 0, fmt.Errorf("--listen %q: %v", listen, err)
	}
	n, err := strconv.Atoi(p)
	if err != nil || n <= 0 || n > 65535 {
		return 0, fmt.Errorf("--listen %q: bad port", listen)
	}
	return n, nil
}

// chooseInterface applies the "do not guess" rule.
func chooseInterface(o *options, cands []ifaceInfo, rangeNet *net.IPNet) (*ifaceInfo, error) {
	if o.iface != "" {
		if c := findInterface(cands, o.iface); c != nil {
			return c, nil
		}
		return nil, fmt.Errorf("interface %q not found or has no IPv4 address; candidates:\n%s", o.iface, listInterfaces(cands))
	}
	if rangeNet != nil {
		var hits []int
		for i := range cands {
			if cands[i].addrInSubnet(rangeNet) != nil {
				hits = append(hits, i)
			}
		}
		if len(hits) == 1 {
			return &cands[hits[0]], nil
		}
	}
	switch {
	case len(cands) == 1:
		return &cands[0], nil
	case len(cands) == 0 && o.pxe:
		return nil, errors.New("no network interface with an IPv4 address is up")
	case len(cands) == 0:
		return nil, nil
	case o.pxe:
		return nil, fmt.Errorf("several network interfaces have IPv4 addresses; choose the one the old PC is connected to with --iface NAME:\n%s", listInterfaces(cands))
	}
	return nil, nil // receiver only: listen everywhere
}

func directInstructions(ifname string, ip net.IP) string {
	if ifname == "" {
		ifname = "<interface>"
	}
	mask := "255.255.255.0"
	switch runtime.GOOS {
	case "windows":
		return fmt.Sprintf("  Windows: Settings > Network & internet > Ethernet > IP assignment > Edit > Manual, IPv4 %s, mask %s, no gateway;\n"+
			"           or in an admin prompt: netsh interface ipv4 set address name=\"%s\" static %s %s\n"+
			"           and make sure Internet Connection Sharing is off (it runs its own DHCP on 192.168.137.x).", ip, mask, ifname, ip, mask)
	case "darwin":
		return fmt.Sprintf("  macOS: System Settings > Network > (your Ethernet adapter) > Details > TCP/IP > Configure IPv4: Manually, IP %s, mask %s, router empty;\n"+
			"         or: sudo networksetup -setmanual \"<network service name>\" %s %s", ip, mask, ip, mask)
	default:
		return fmt.Sprintf("  Linux: sudo ip addr add %s/24 dev %s && sudo ip link set %s up (or set it in NetworkManager)", ip, ifname, ifname)
	}
}

func serve(ctx context.Context, o *options) (int, error) {
	port, err := httpPort(o.listen)
	if err != nil {
		return exitUsage, err
	}
	dest, err := filepath.Abs(o.dest)
	if err != nil {
		return exitError, err
	}
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return exitError, fmt.Errorf("cannot create --dest %s: %v", dest, err)
	}

	var rangeStart, rangeEnd net.IP
	var rangeNet *net.IPNet
	if o.dhcpRange != "" {
		rangeStart, rangeEnd, err = parseRange(o.dhcpRange)
		if err != nil {
			return exitUsage, err
		}
		rangeNet = &net.IPNet{IP: rangeStart.Mask(net.CIDRMask(directMask, 32)), Mask: net.CIDRMask(directMask, 32)}
	}

	cands, err := candidateInterfaces()
	if err != nil {
		return exitError, err
	}
	chosen, err := chooseInterface(o, cands, rangeNet)
	if err != nil {
		return exitUsage, err
	}

	var serverIP net.IP
	ifname := "all interfaces"
	if chosen != nil {
		ifname = chosen.Iface.Name
		serverIP = chosen.primary()
	}
	if rangeNet != nil {
		want := append(net.IP{}, rangeNet.IP...)
		want[3] = 1
		if ip4u(want) >= ip4u(rangeStart) && ip4u(want) <= ip4u(rangeEnd) {
			return exitUsage, fmt.Errorf("--dhcp-range %s must not contain the helper address %s", o.dhcpRange, want)
		}
		logf("direct-cable mode: this machine's NIC %s must have the static address %s/24 (no gateway).", ifname, want)
		if got := chosen.addrInSubnet(rangeNet); got != nil {
			serverIP = got
		} else {
			serverIP = want
			logf("WARN %s has no address in %s (it has: %s). Set it now; DHCP answers already use %s:", ifname, rangeNet, chosen.addrList(), want)
			logf("%s", directInstructions(chosen.Iface.Name, want))
			if runtime.GOOS == "windows" && !o.bindAny {
				return exitUsage, fmt.Errorf("on Windows the address must be configured before start-up; set %s/24 on %s and run again", want, ifname)
			}
		}
	}
	if serverIP == nil && len(cands) > 0 {
		serverIP = cands[0].primary()
	}
	if serverIP == nil {
		serverIP = net.IPv4(127, 0, 0, 1).To4()
	}
	baseURL := fmt.Sprintf("http://%s:%d", serverIP, port)

	st := newStats()
	rc := newReceiver(dest, version, st)

	var boot *bootFiles
	if o.pxe {
		boot = newBootFiles(embeddedBootFS(), baseURL, version)
	}

	// Bind everything first so that a failure exits before "waiting".
	ln, err := net.Listen("tcp", o.listen)
	if err != nil {
		return exitBind, bindError{"HTTP " + o.listen, err, bindHint("TCP", port)}
	}
	srv := &http.Server{Handler: newMux(rc, boot), ReadHeaderTimeout: 30 * time.Second, IdleTimeout: 2 * time.Minute}
	var closers []func()
	defer func() {
		for i := len(closers) - 1; i >= 0; i-- {
			closers[i]()
		}
	}()

	if o.beaconPort > 0 {
		bc, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: o.beaconPort})
		if err != nil {
			ln.Close()
			return exitBind, bindError{fmt.Sprintf("beacon UDP %d", o.beaconPort), err, bindHint("UDP", o.beaconPort)}
		}
		closers = append(closers, func() { bc.Close() })
		go (&beacon{conn: bc, httpPort: port, fallback: serverIP}).serve()
	}

	var pxe *pxeServer
	if o.pxe {
		var pool *leasePool
		if rangeNet != nil {
			pool = newLeasePool(rangeStart, rangeEnd, serverIP)
		}
		pxe = newPXEServer(serverIP, o.bootFile, pool)
		var ifc *net.Interface
		if chosen != nil {
			ifc = &chosen.Iface
		}
		c67, err := listenDHCP(dhcpServerPort, ifc, serverIP, o.bindAny)
		if err != nil {
			ln.Close()
			return exitBind, bindError{"DHCP UDP 67", err, bindHint("UDP", dhcpServerPort)}
		}
		closers = append(closers, func() { c67.Close() })
		c4011, err := listenPlain(pxeBootPort)
		if err != nil {
			ln.Close()
			return exitBind, bindError{"PXE boot server UDP 4011", err, bindHint("UDP", pxeBootPort)}
		}
		closers = append(closers, func() { c4011.Close() })
		tc, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 69})
		if err != nil {
			ln.Close()
			return exitBind, bindError{"TFTP UDP 69", err, bindHint("UDP", 69)}
		}
		ts := newTFTPServer(boot)
		closers = append(closers, ts.Shutdown)
		go ts.Serve(tc)
		wantIf := 0
		if ifc != nil {
			wantIf = ifc.Index
		}
		go serveDHCP(c67, dhcpServerPort, pxe, wantIf)
		go serveDHCP(c4011, pxeBootPort, pxe, 0)
	}

	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logf("HTTP server stopped: %v", err)
		}
	}()

	free := rc.free()
	logf("retro-helper %s listening on %s (%s, dest=%s, free=%s) — waiting", version, baseURL, ifname, dest, humanBytes(free))
	if chosen == nil && len(cands) > 1 {
		for _, c := range cands {
			logf("  also reachable on %s: http://%s:%d", c.Iface.Name, c.primary(), port)
		}
	}
	if o.beaconPort > 0 {
		logf("discovery beacon on UDP %d", o.beaconPort)
	}
	if o.pxe {
		mode := "proxy DHCP next to the existing DHCP server (switch/router mode)"
		if rangeNet != nil {
			mode = fmt.Sprintf("full DHCP for %s on a direct cable, 1 h leases", o.dhcpRange)
		}
		logf("PXE: %s; TFTP on UDP 69, boot file %s, kernel and initrd via %s/boot/", mode, o.bootFile, baseURL)
		boot.warnMissing()
		if !o.noCheck {
			go checkOtherDHCP(chosen, serverIP, pxe, rangeNet != nil)
		}
	}

	<-ctx.Done()
	signal.Reset(os.Interrupt, syscall.SIGTERM) // a second Ctrl-C quits at once
	logf("stopping (Ctrl-C again to quit immediately)")
	sctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := srv.Shutdown(sctx); err != nil {
		srv.Close()
	}
	for _, line := range strings.Split(st.summary(), "\n") {
		logf("%s", line)
	}
	return exitOK, nil
}

func checkOtherDHCP(chosen *ifaceInfo, serverIP net.IP, pxe *pxeServer, direct bool) {
	var ifc *net.Interface
	if chosen != nil {
		ifc = &chosen.Iface
	}
	servers, ran := probeDHCPServers(ifc, serverIP, pxe, 4*time.Second)
	if !ran {
		logf("DHCP check skipped (UDP 68 is in use by the OS DHCP client or needs privileges)")
		return
	}
	var list []string
	for _, s := range servers {
		list = append(list, s.String())
	}
	switch {
	case direct && len(servers) > 0:
		logf("WARN another DHCP server answers on this network (%s): direct-cable mode must be the only one. Unplug the router / turn off ICS or Internet Sharing, or use proxy mode (drop --dhcp-range).", strings.Join(list, ", "))
	case !direct && len(servers) == 0:
		logf("WARN no DHCP server answered a test DISCOVER within 4 s: proxy mode needs the router's DHCP to give the old PC an address. On a direct cable use --dhcp-range 10.99.0.100-10.99.0.200.")
	case !direct:
		logf("DHCP server(s) on the LAN: %s (good: proxy mode only adds the boot information)", strings.Join(list, ", "))
	}
}
