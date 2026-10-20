package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/insomniacslk/dhcp/dhcpv4"
	"github.com/insomniacslk/dhcp/iana"
)

// DHCP side of the PXE server. pxeServer.handle is a pure function of the
// request (plus the lease table), so it is unit-tested without sockets.

const (
	dhcpServerPort = 67
	dhcpClientPort = 68
	pxeBootPort    = 4011
	leaseDuration  = time.Hour
	offerHold      = time.Minute
)

type pxeServer struct {
	serverIP net.IP
	bootFile string
	pool     *leasePool // nil: proxy mode

	mu      sync.Mutex
	ignore  map[string]bool      // MACs of our own rogue-server probe
	recent  map[string]time.Time // duplicate suppression
	seenPXE map[string]bool      // log the first DISCOVER per MAC loudly
	now     func() time.Time
}

func newPXEServer(serverIP net.IP, bootFile string, pool *leasePool) *pxeServer {
	return &pxeServer{
		serverIP: serverIP.To4(), bootFile: bootFile, pool: pool,
		ignore: map[string]bool{}, recent: map[string]time.Time{}, seenPXE: map[string]bool{},
		now: time.Now,
	}
}

func (s *pxeServer) ignoreMAC(mac net.HardwareAddr) {
	s.mu.Lock()
	s.ignore[mac.String()] = true
	s.mu.Unlock()
}

func isPXEClient(req *dhcpv4.DHCPv4) bool {
	return strings.HasPrefix(req.ClassIdentifier(), "PXEClient")
}

// clientArch returns option 93's first value, or 0 (x86 BIOS) when absent:
// PXE 2.0 ROMs from before RFC 4578 do not send it.
func clientArch(req *dhcpv4.DHCPv4) iana.Arch {
	if a := req.ClientArch(); len(a) > 0 {
		return a[0]
	}
	return iana.INTEL_X86PC
}

// duplicate reports whether the same packet was handled moments ago (a
// broadcast can arrive on two sockets).
func (s *pxeServer) duplicate(req *dhcpv4.DHCPv4, port int) bool {
	key := fmt.Sprintf("%d/%s/%s/%s", port, req.TransactionID, req.ClientHWAddr, req.MessageType())
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, t := range s.recent {
		if now.Sub(t) > time.Second {
			delete(s.recent, k)
		}
	}
	if t, ok := s.recent[key]; ok && now.Sub(t) < 300*time.Millisecond {
		return true
	}
	s.recent[key] = now
	return false
}

// handle returns the reply and where to send it, or nil for no reply. port
// is the local port the request arrived on, src its source address.
func (s *pxeServer) handle(req *dhcpv4.DHCPv4, port int, src *net.UDPAddr) (*dhcpv4.DHCPv4, *net.UDPAddr) {
	if req.OpCode != dhcpv4.OpcodeBootRequest || len(req.ClientHWAddr) == 0 {
		return nil, nil
	}
	s.mu.Lock()
	ignored := s.ignore[req.ClientHWAddr.String()]
	s.mu.Unlock()
	if ignored || s.duplicate(req, port) {
		return nil, nil
	}
	if port == pxeBootPort {
		return s.handleBootServer(req, src)
	}
	if s.pool != nil {
		return s.handleDirect(req)
	}
	return s.handleProxy(req)
}

func (s *pxeServer) pxeEligible(req *dhcpv4.DHCPv4) bool {
	if !isPXEClient(req) {
		return false
	}
	if a := clientArch(req); a != iana.INTEL_X86PC {
		s.mu.Lock()
		first := !s.seenPXE["arch/"+req.ClientHWAddr.String()]
		s.seenPXE["arch/"+req.ClientHWAddr.String()] = true
		s.mu.Unlock()
		if first {
			logf("PXE client %s is %s (option 93 = %d): only BIOS PXE is supported, not answering (boot it in legacy/CSM mode)", req.ClientHWAddr, a, uint16(a))
		}
		return false
	}
	return true
}

// pxeReply builds the proxyDHCP / boot-server reply skeleton.
func (s *pxeServer) pxeReply(req *dhcpv4.DHCPv4, mt dhcpv4.MessageType, vendor []byte) *dhcpv4.DHCPv4 {
	resp, err := dhcpv4.NewReplyFromRequest(req,
		dhcpv4.WithMessageType(mt),
		dhcpv4.WithYourIP(net.IPv4zero),
		dhcpv4.WithServerIP(s.serverIP),
		dhcpv4.WithOption(dhcpv4.OptServerIdentifier(s.serverIP)),
		dhcpv4.WithOption(dhcpv4.OptClassIdentifier("PXEClient")),
		dhcpv4.WithOption(dhcpv4.OptTFTPServerName(s.serverIP.String())),
		dhcpv4.WithOption(dhcpv4.OptBootFileName(s.bootFile)),
		dhcpv4.WithGeneric(dhcpv4.OptionVendorSpecificInformation, vendor),
		dhcpv4.WithOptionCopied(req, dhcpv4.OptionClientMachineIdentifier),
	)
	if err != nil {
		return nil
	}
	resp.BootFileName = s.bootFile
	if mt == dhcpv4.MessageTypeAck && req.ClientIPAddr != nil {
		resp.ClientIPAddr = req.ClientIPAddr
	}
	return resp
}

func (s *pxeServer) handleProxy(req *dhcpv4.DHCPv4) (*dhcpv4.DHCPv4, *net.UDPAddr) {
	if !s.pxeEligible(req) {
		return nil, nil
	}
	var mt dhcpv4.MessageType
	switch req.MessageType() {
	case dhcpv4.MessageTypeDiscover:
		mt = dhcpv4.MessageTypeOffer
		logf("PXE DISCOVER from %s (%s) -> proxy offer %s from %s", req.ClientHWAddr, req.ClassIdentifier(), s.bootFile, s.serverIP)
	case dhcpv4.MessageTypeRequest:
		// Only requests addressed to us; the others select the router's lease.
		if sid := req.ServerIdentifier(); sid == nil || !sid.Equal(s.serverIP) {
			return nil, nil
		}
		mt = dhcpv4.MessageTypeAck
		logf("PXE REQUEST from %s to proxy -> ack %s", req.ClientHWAddr, s.bootFile)
	default:
		return nil, nil
	}
	resp := s.pxeReply(req, mt, pxeOfferVendorOptions(s.serverIP))
	if resp == nil {
		return nil, nil
	}
	return resp, replyDest(req, resp)
}

// handleBootServer answers the PXE boot-server request on UDP 4011.
func (s *pxeServer) handleBootServer(req *dhcpv4.DHCPv4, src *net.UDPAddr) (*dhcpv4.DHCPv4, *net.UDPAddr) {
	if !s.pxeEligible(req) {
		return nil, nil
	}
	if mt := req.MessageType(); mt != dhcpv4.MessageTypeRequest && mt != dhcpv4.MessageTypeInform {
		return nil, nil
	}
	typ, layer := uint16(pxeServerType), uint16(0)
	if sub := parseVendorSubOptions(req.GetOneOption(dhcpv4.OptionVendorSpecificInformation)); len(sub[pxeBootItem]) == 4 {
		typ = binary.BigEndian.Uint16(sub[pxeBootItem])
		layer = binary.BigEndian.Uint16(sub[pxeBootItem][2:]) & 0x7fff
	}
	resp := s.pxeReply(req, dhcpv4.MessageTypeAck, pxeAckVendorOptions(typ, layer))
	if resp == nil {
		return nil, nil
	}
	dst := src
	if dst == nil || dst.IP.IsUnspecified() {
		dst = replyDest(req, resp)
	}
	logf("PXE boot-server request from %s (%s) -> %s", req.ClientHWAddr, dst.IP, s.bootFile)
	return resp, dst
}

// replyDest implements RFC 2131 section 4.1 without raw sockets: relay
// agent, else unicast to a configured ciaddr, else broadcast. Unicasting to
// yiaddr of a client without an address would need an ARP entry written
// behind the OS's back (raw sockets), so those replies are broadcast even
// when the client did not set the broadcast flag; every DHCP client must
// accept a broadcast reply.
func replyDest(req, resp *dhcpv4.DHCPv4) *net.UDPAddr {
	if gi := req.GatewayIPAddr; gi != nil && !gi.IsUnspecified() {
		return &net.UDPAddr{IP: gi, Port: dhcpServerPort}
	}
	if resp.MessageType() != dhcpv4.MessageTypeNak && !req.IsBroadcast() {
		if ci := req.ClientIPAddr; ci != nil && !ci.IsUnspecified() {
			return &net.UDPAddr{IP: ci, Port: dhcpClientPort}
		}
	}
	return &net.UDPAddr{IP: net.IPv4bcast, Port: dhcpClientPort}
}

func (s *pxeServer) directReply(req *dhcpv4.DHCPv4, mt dhcpv4.MessageType, yiaddr net.IP) *dhcpv4.DHCPv4 {
	mods := []dhcpv4.Modifier{
		dhcpv4.WithMessageType(mt),
		dhcpv4.WithOption(dhcpv4.OptServerIdentifier(s.serverIP)),
	}
	if mt != dhcpv4.MessageTypeNak {
		mods = append(mods,
			dhcpv4.WithServerIP(s.serverIP),
			dhcpv4.WithOption(dhcpv4.OptSubnetMask(s.pool.mask)),
			dhcpv4.WithOption(dhcpv4.OptRouter(s.serverIP)),
			dhcpv4.WithOption(dhcpv4.OptDNS(s.serverIP)),
			dhcpv4.WithOption(dhcpv4.OptTFTPServerName(s.serverIP.String())),
			dhcpv4.WithOption(dhcpv4.OptBootFileName(s.bootFile)),
		)
		if yiaddr != nil {
			mods = append(mods,
				dhcpv4.WithYourIP(yiaddr),
				dhcpv4.WithOption(dhcpv4.OptIPAddressLeaseTime(s.pool.leaseTime)),
				dhcpv4.WithOption(dhcpv4.OptRenewTimeValue(s.pool.leaseTime/2)),
				dhcpv4.WithOption(dhcpv4.OptRebindingTimeValue(s.pool.leaseTime*7/8)),
			)
		}
	}
	resp, err := dhcpv4.NewReplyFromRequest(req, mods...)
	if err != nil {
		return nil
	}
	if mt != dhcpv4.MessageTypeNak {
		resp.BootFileName = s.bootFile
	}
	return resp
}

// handleDirect is a plain authoritative DHCP server for the direct cable.
// PXE clients get siaddr/file (classic "DHCP-only" PXE boot, no option 43),
// which every PXE ROM supports.
func (s *pxeServer) handleDirect(req *dhcpv4.DHCPv4) (*dhcpv4.DHCPv4, *net.UDPAddr) {
	mac := req.ClientHWAddr.String()
	if isPXEClient(req) && clientArch(req) != iana.INTEL_X86PC {
		s.pxeEligible(req) // logs once
	}
	var resp *dhcpv4.DHCPv4
	switch req.MessageType() {
	case dhcpv4.MessageTypeDiscover:
		ip := s.pool.offer(mac, req.RequestedIPAddress())
		if ip == nil {
			logf("DHCP DISCOVER from %s: address pool exhausted", mac)
			return nil, nil
		}
		kind := "DHCP"
		if isPXEClient(req) {
			kind = "PXE"
		}
		logf("%s DISCOVER from %s -> offer %s", kind, mac, ip)
		resp = s.directReply(req, dhcpv4.MessageTypeOffer, ip)
	case dhcpv4.MessageTypeRequest:
		if sid := req.ServerIdentifier(); sid != nil && !sid.Equal(s.serverIP) {
			s.pool.cancelOffer(mac)
			return nil, nil
		}
		ip := req.RequestedIPAddress()
		if ip == nil || ip.IsUnspecified() {
			ip = req.ClientIPAddr
		}
		if ip == nil || ip.IsUnspecified() || !s.pool.commit(mac, ip) {
			logf("DHCP REQUEST from %s for %v -> NAK", mac, ip)
			resp = s.directReply(req, dhcpv4.MessageTypeNak, nil)
			break
		}
		logf("DHCP REQUEST from %s -> ack %s for %s", mac, ip, s.pool.leaseTime)
		resp = s.directReply(req, dhcpv4.MessageTypeAck, ip.To4())
	case dhcpv4.MessageTypeRelease:
		s.pool.release(mac, req.ClientIPAddr)
		logf("DHCP RELEASE from %s (%s)", mac, req.ClientIPAddr)
		return nil, nil
	case dhcpv4.MessageTypeDecline:
		s.pool.decline(mac, req.RequestedIPAddress())
		logf("DHCP DECLINE from %s for %s (address in use?)", mac, req.RequestedIPAddress())
		return nil, nil
	case dhcpv4.MessageTypeInform:
		resp = s.directReply(req, dhcpv4.MessageTypeAck, nil)
	default:
		return nil, nil
	}
	if resp == nil {
		return nil, nil
	}
	return resp, replyDest(req, resp)
}

// leasePool is the in-memory lease table of direct-cable mode.
type leasePool struct {
	mu        sync.Mutex
	start     uint32
	end       uint32
	server    uint32
	mask      net.IPMask
	leaseTime time.Duration
	byMAC     map[string]uint32
	byIP      map[uint32]*lease
	declined  map[uint32]time.Time
	now       func() time.Time
}

type lease struct {
	mac       string
	expiry    time.Time
	committed bool
}

func ip4u(ip net.IP) uint32 { return binary.BigEndian.Uint32(ip.To4()) }

func u2ip(u uint32) net.IP {
	ip := make(net.IP, 4)
	binary.BigEndian.PutUint32(ip, u)
	return ip
}

// parseRange parses "10.99.0.100-10.99.0.200". Both ends must be in one /24.
func parseRange(s string) (start, end net.IP, err error) {
	a, b, ok := strings.Cut(s, "-")
	if !ok {
		return nil, nil, fmt.Errorf("--dhcp-range %q: want FIRST-LAST, e.g. 10.99.0.100-10.99.0.200", s)
	}
	start, end = net.ParseIP(strings.TrimSpace(a)).To4(), net.ParseIP(strings.TrimSpace(b)).To4()
	if start == nil || end == nil {
		return nil, nil, fmt.Errorf("--dhcp-range %q: not two IPv4 addresses", s)
	}
	if ip4u(start)>>8 != ip4u(end)>>8 {
		return nil, nil, fmt.Errorf("--dhcp-range %q: both ends must be in the same /24", s)
	}
	if ip4u(start) > ip4u(end) || start[3] == 0 || end[3] == 255 {
		return nil, nil, fmt.Errorf("--dhcp-range %q: invalid range", s)
	}
	return start, end, nil
}

func newLeasePool(start, end, server net.IP) *leasePool {
	return &leasePool{
		start: ip4u(start), end: ip4u(end), server: ip4u(server),
		mask: net.CIDRMask(24, 32), leaseTime: leaseDuration,
		byMAC: map[string]uint32{}, byIP: map[uint32]*lease{}, declined: map[uint32]time.Time{},
		now: time.Now,
	}
}

func (p *leasePool) inRange(u uint32) bool { return u >= p.start && u <= p.end && u != p.server }

func (p *leasePool) freeFor(u uint32, mac string, now time.Time) bool {
	if !p.inRange(u) {
		return false
	}
	if t, ok := p.declined[u]; ok && now.Sub(t) < 10*time.Minute {
		return false
	}
	l := p.byIP[u]
	return l == nil || l.mac == mac || now.After(l.expiry)
}

func (p *leasePool) assign(u uint32, mac string, d time.Duration, committed bool) {
	if old, ok := p.byMAC[mac]; ok && old != u {
		if l := p.byIP[old]; l != nil && l.mac == mac {
			delete(p.byIP, old)
		}
	}
	if l := p.byIP[u]; l != nil && l.mac != mac {
		delete(p.byMAC, l.mac)
	}
	exp := p.now().Add(d)
	if l := p.byIP[u]; l != nil && l.mac == mac && l.committed && !committed && l.expiry.After(exp) {
		exp = l.expiry // an OFFER never shortens a committed lease
		committed = true
	}
	p.byIP[u] = &lease{mac: mac, expiry: exp, committed: committed}
	p.byMAC[mac] = u
}

// offer picks the client's current address, else the one it asks for, else
// the lowest free one.
func (p *leasePool) offer(mac string, requested net.IP) net.IP {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := p.now()
	if u, ok := p.byMAC[mac]; ok && p.freeFor(u, mac, now) {
		p.assign(u, mac, offerHold, false)
		return u2ip(u)
	}
	if requested.To4() != nil {
		if u := ip4u(requested); p.freeFor(u, mac, now) {
			p.assign(u, mac, offerHold, false)
			return u2ip(u)
		}
	}
	for u := p.start; u <= p.end; u++ {
		if p.freeFor(u, mac, now) {
			p.assign(u, mac, offerHold, false)
			return u2ip(u)
		}
	}
	return nil
}

// commit turns an offer into a lease, or renews one.
func (p *leasePool) commit(mac string, ip net.IP) bool {
	if ip.To4() == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	u := ip4u(ip)
	if !p.freeFor(u, mac, p.now()) {
		return false
	}
	p.assign(u, mac, p.leaseTime, true)
	return true
}

func (p *leasePool) cancelOffer(mac string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if u, ok := p.byMAC[mac]; ok {
		if l := p.byIP[u]; l != nil && !l.committed {
			delete(p.byIP, u)
			delete(p.byMAC, mac)
		}
	}
}

func (p *leasePool) release(mac string, ip net.IP) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if u, ok := p.byMAC[mac]; ok {
		delete(p.byIP, u)
		delete(p.byMAC, mac)
	}
}

func (p *leasePool) decline(mac string, ip net.IP) {
	if ip.To4() == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	u := ip4u(ip)
	p.declined[u] = p.now()
	if l := p.byIP[u]; l != nil && l.mac == mac {
		delete(p.byIP, u)
		delete(p.byMAC, mac)
	}
}
