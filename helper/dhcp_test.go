package main

import (
	"bytes"
	"net"
	"testing"
	"time"

	"github.com/insomniacslk/dhcp/dhcpv4"
	"github.com/insomniacslk/dhcp/iana"
)

var (
	helperIP  = net.IPv4(192, 168, 1, 23).To4()
	clientMAC = net.HardwareAddr{0x00, 0x0c, 0x29, 0x12, 0x34, 0x56}
	guid      = append([]byte{0}, bytes.Repeat([]byte{0xab}, 16)...)
)

func pxeDiscover(t *testing.T, mods ...dhcpv4.Modifier) *dhcpv4.DHCPv4 {
	t.Helper()
	base := []dhcpv4.Modifier{
		dhcpv4.WithBroadcast(true),
		dhcpv4.WithOption(dhcpv4.OptClassIdentifier("PXEClient:Arch:00000:UNDI:002001")),
		dhcpv4.WithOption(dhcpv4.OptClientArch(iana.INTEL_X86PC)),
		dhcpv4.WithGeneric(dhcpv4.OptionClientNetworkInterfaceIdentifier, []byte{1, 2, 1}),
		dhcpv4.WithGeneric(dhcpv4.OptionClientMachineIdentifier, guid),
	}
	d, err := dhcpv4.NewDiscovery(clientMAC, append(base, mods...)...)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// roundTrip serialises like the network path does and parses it back.
func roundTrip(t *testing.T, d *dhcpv4.DHCPv4) *dhcpv4.DHCPv4 {
	t.Helper()
	raw := marshalDHCP(d)
	if len(raw) < 300 {
		t.Errorf("reply is %d bytes, want >= 300", len(raw))
	}
	if raw[240] != 53 {
		t.Errorf("first option is %d, want 53", raw[240])
	}
	p, err := dhcpv4.FromBytes(raw)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestProxyOffer(t *testing.T) {
	s := newPXEServer(helperIP, "lpxelinux.0", nil)
	req := pxeDiscover(t)
	resp, dst := s.handle(req, dhcpServerPort, &net.UDPAddr{IP: net.IPv4zero, Port: 68})
	if resp == nil {
		t.Fatal("no reply to PXE DISCOVER")
	}
	if !dst.IP.Equal(net.IPv4bcast) || dst.Port != 68 {
		t.Errorf("dst = %v, want broadcast:68", dst)
	}
	r := roundTrip(t, resp)
	if r.MessageType() != dhcpv4.MessageTypeOffer || r.TransactionID != req.TransactionID || !bytes.Equal(r.ClientHWAddr, clientMAC) {
		t.Errorf("type %s xid %s mac %s", r.MessageType(), r.TransactionID, r.ClientHWAddr)
	}
	if !r.YourIPAddr.IsUnspecified() {
		t.Errorf("yiaddr = %s, want 0.0.0.0", r.YourIPAddr)
	}
	if !r.ServerIPAddr.Equal(helperIP) || !r.ServerIdentifier().Equal(helperIP) {
		t.Errorf("siaddr %s server id %s", r.ServerIPAddr, r.ServerIdentifier())
	}
	if r.ClassIdentifier() != "PXEClient" {
		t.Errorf("option 60 = %q", r.ClassIdentifier())
	}
	if r.TFTPServerName() != helperIP.String() {
		t.Errorf("option 66 = %q", r.TFTPServerName())
	}
	if r.BootFileNameOption() != "lpxelinux.0" || r.BootFileName != "lpxelinux.0" {
		t.Errorf("option 67 %q file %q", r.BootFileNameOption(), r.BootFileName)
	}
	if !bytes.Equal(r.GetOneOption(dhcpv4.OptionClientMachineIdentifier), guid) {
		t.Errorf("option 97 not echoed")
	}
	if !r.IsBroadcast() {
		t.Errorf("broadcast flag not kept")
	}
	vend := r.GetOneOption(dhcpv4.OptionVendorSpecificInformation)
	if vend[len(vend)-1] != 0xff {
		t.Errorf("option 43 not terminated by 0xff: % x", vend)
	}
	sub := parseVendorSubOptions(vend)
	want := map[byte][]byte{
		pxeDiscoveryControl: {7},
		pxeBootServers:      {0x80, 0x00, 1, 192, 168, 1, 23},
		pxeBootMenu:         append([]byte{0x80, 0x00, 12}, "retro-backup"...),
		pxeMenuPrompt:       append([]byte{0}, "retro-backup"...),
		pxeBootItem:         {0x80, 0x00, 0, 0},
	}
	for code, w := range want {
		if !bytes.Equal(sub[code], w) {
			t.Errorf("option 43 sub-option %d = % x, want % x", code, sub[code], w)
		}
	}
	if len(sub) != len(want) {
		t.Errorf("option 43 has %d sub-options: %v", len(sub), sub)
	}
}

func TestProxyIgnoresNonPXE(t *testing.T) {
	s := newPXEServer(helperIP, "lpxelinux.0", nil)
	d, _ := dhcpv4.NewDiscovery(clientMAC, dhcpv4.WithOption(dhcpv4.OptClassIdentifier("MSFT 5.0")))
	if resp, _ := s.handle(d, dhcpServerPort, nil); resp != nil {
		t.Errorf("replied to a non-PXE DISCOVER")
	}
	d2, _ := dhcpv4.NewDiscovery(clientMAC)
	if resp, _ := s.handle(d2, dhcpServerPort, nil); resp != nil {
		t.Errorf("replied to a DISCOVER without option 60")
	}
	efi := pxeDiscover(t, dhcpv4.WithOption(dhcpv4.OptClientArch(iana.EFI_X86_64)))
	if resp, _ := s.handle(efi, dhcpServerPort, nil); resp != nil {
		t.Errorf("replied to a UEFI client")
	}
	// A REQUEST selecting the router's offer is not for us.
	req := pxeDiscover(t, dhcpv4.WithMessageType(dhcpv4.MessageTypeRequest),
		dhcpv4.WithOption(dhcpv4.OptServerIdentifier(net.IPv4(192, 168, 1, 1))))
	if resp, _ := s.handle(req, dhcpServerPort, nil); resp != nil {
		t.Errorf("replied to a REQUEST for another server")
	}
	// The ROM's DISCOVER is also answered when retransmitted later.
	s.now = func() time.Time { return time.Now().Add(-time.Hour) }
	disc := pxeDiscover(t)
	if r, _ := s.handle(disc, dhcpServerPort, nil); r == nil {
		t.Fatal("no reply")
	}
	s.now = time.Now
	if r, _ := s.handle(disc, dhcpServerPort, nil); r == nil {
		t.Errorf("retransmission after 4 s not answered")
	}
	if r, _ := s.handle(disc, dhcpServerPort, nil); r != nil {
		t.Errorf("duplicate within 300 ms answered twice")
	}
}

func TestBootServerAck(t *testing.T) {
	s := newPXEServer(helperIP, "lpxelinux.0", nil)
	cip := net.IPv4(192, 168, 1, 50).To4()
	req := pxeDiscover(t,
		dhcpv4.WithMessageType(dhcpv4.MessageTypeRequest),
		dhcpv4.WithBroadcast(false),
		dhcpv4.WithClientIP(cip),
		dhcpv4.WithGeneric(dhcpv4.OptionVendorSpecificInformation, []byte{71, 4, 0x80, 0x00, 0x00, 0x00, 0xff}),
	)
	src := &net.UDPAddr{IP: cip, Port: 68}
	resp, dst := s.handle(req, pxeBootPort, src)
	if resp == nil {
		t.Fatal("no boot-server ACK")
	}
	if dst.String() != src.String() {
		t.Errorf("dst %v, want %v", dst, src)
	}
	r := roundTrip(t, resp)
	if r.MessageType() != dhcpv4.MessageTypeAck || r.BootFileName != "lpxelinux.0" || !r.ServerIPAddr.Equal(helperIP) || !r.ClientIPAddr.Equal(cip) {
		t.Errorf("ack: %s", r.Summary())
	}
	vend := r.GetOneOption(dhcpv4.OptionVendorSpecificInformation)
	if !bytes.Equal(vend, []byte{71, 4, 0x80, 0x00, 0x00, 0x00, 0xff}) {
		t.Errorf("ack option 43 = % x", vend)
	}
	if r.ClassIdentifier() != "PXEClient" {
		t.Errorf("ack option 60 = %q", r.ClassIdentifier())
	}
}

func TestDirectModeLeases(t *testing.T) {
	srv := net.IPv4(10, 99, 0, 1).To4()
	start, end, err := parseRange("10.99.0.100-10.99.0.101")
	if err != nil {
		t.Fatal(err)
	}
	pool := newLeasePool(start, end, srv)
	s := newPXEServer(srv, "lpxelinux.0", pool)

	disc := pxeDiscover(t)
	offer, dst := s.handle(disc, dhcpServerPort, nil)
	if offer == nil {
		t.Fatal("no offer")
	}
	o := roundTrip(t, offer)
	ip := o.YourIPAddr
	if !ip.Equal(net.IPv4(10, 99, 0, 100)) || !dst.IP.Equal(net.IPv4bcast) {
		t.Errorf("offered %s to %v", ip, dst)
	}
	if o.MessageType() != dhcpv4.MessageTypeOffer || o.SubnetMask().String() != "ffffff00" ||
		len(o.Router()) != 1 || !o.Router()[0].Equal(srv) || len(o.DNS()) != 1 || !o.DNS()[0].Equal(srv) ||
		o.IPAddressLeaseTime(0) != time.Hour || !o.ServerIdentifier().Equal(srv) || o.BootFileName != "lpxelinux.0" || !o.ServerIPAddr.Equal(srv) {
		t.Errorf("offer: %s", o.Summary())
	}

	req, _ := dhcpv4.NewRequestFromOffer(o)
	ack, _ := s.handle(req, dhcpServerPort, nil)
	if ack == nil || ack.MessageType() != dhcpv4.MessageTypeAck || !ack.YourIPAddr.Equal(ip) {
		t.Fatalf("request: %v", ack)
	}

	// A second client gets the other address, a third none.
	other := net.HardwareAddr{2, 0, 0, 0, 0, 2}
	d2, _ := dhcpv4.NewDiscovery(other)
	o2, _ := s.handle(d2, dhcpServerPort, nil)
	if o2 == nil || !o2.YourIPAddr.Equal(net.IPv4(10, 99, 0, 101)) {
		t.Fatalf("second client: %v", o2)
	}
	d3, _ := dhcpv4.NewDiscovery(net.HardwareAddr{2, 0, 0, 0, 0, 3})
	if o3, _ := s.handle(d3, dhcpServerPort, nil); o3 != nil {
		t.Errorf("pool should be exhausted, offered %s", o3.YourIPAddr)
	}

	// Renewal half an hour later: unicast from ciaddr, no server id.
	later := time.Now().Add(30 * time.Minute)
	pool.now = func() time.Time { return later }
	renew, _ := dhcpv4.NewRenewFromAck(ack)
	renew.TransactionID = dhcpv4.TransactionID{1, 2, 3, 4} // a renewal uses a new xid
	renew.UpdateOption(dhcpv4.OptClassIdentifier("udhcp 1.36.1"))
	r, dst := s.handle(renew, dhcpServerPort, &net.UDPAddr{IP: ip, Port: 68})
	if r == nil || r.MessageType() != dhcpv4.MessageTypeAck || !r.YourIPAddr.Equal(ip) {
		t.Fatalf("renew: %v", r)
	}
	if !dst.IP.Equal(ip) {
		t.Errorf("renew reply to %v, want unicast %s", dst, ip)
	}
	// The lease now runs until later+1h: still ours 80 minutes after start.
	pool.now = func() time.Time { return later.Add(50 * time.Minute) }
	if ip2 := pool.offer("02:00:00:00:00:09", ip); ip2 != nil && ip2.Equal(ip) {
		t.Errorf("renewed lease was handed to another client")
	}

	// Requesting an address of another client is refused.
	bad, _ := dhcpv4.NewRequestFromOffer(o)
	bad.ClientHWAddr = net.HardwareAddr{2, 0, 0, 0, 0, 7}
	bad.TransactionID = dhcpv4.TransactionID{9, 9, 9, 9}
	if n, _ := s.handle(bad, dhcpServerPort, nil); n == nil || n.MessageType() != dhcpv4.MessageTypeNak {
		t.Errorf("want NAK, got %v", n)
	}

	// Release frees the address.
	pool.now = time.Now
	rel, _ := dhcpv4.NewReleaseFromACK(ack)
	s.handle(rel, dhcpServerPort, nil)
	if got := pool.offer("02:00:00:00:00:08", nil); got == nil || !got.Equal(ip) {
		t.Errorf("released address not reused: %v", got)
	}
}

func TestParseRange(t *testing.T) {
	for _, bad := range []string{"10.99.0.100", "10.99.0.200-10.99.0.100", "10.99.0.100-10.99.1.10", "x-y", "10.99.0.0-10.99.0.5"} {
		if _, _, err := parseRange(bad); err == nil {
			t.Errorf("parseRange(%q) accepted", bad)
		}
	}
}

func TestMarshalOrder(t *testing.T) {
	d, _ := dhcpv4.New(dhcpv4.WithMessageType(dhcpv4.MessageTypeOffer),
		dhcpv4.WithOption(dhcpv4.OptServerIdentifier(helperIP)),
		dhcpv4.WithGeneric(dhcpv4.OptionVendorSpecificInformation, []byte{6, 1, 7, 255}))
	raw := marshalDHCP(d)
	if !bytes.Equal(raw[240:249], []byte{53, 1, 2, 54, 4, 192, 168, 1, 23}) {
		t.Errorf("options start % x", raw[240:249])
	}
}
