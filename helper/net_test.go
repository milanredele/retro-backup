package main

import (
	"bytes"
	"net"
	"testing"
	"testing/fstest"
	"time"

	"github.com/insomniacslk/dhcp/dhcpv4"
	"github.com/pin/tftp/v3"
)

func TestTFTPServesBootFiles(t *testing.T) {
	loader := bytes.Repeat([]byte{0x90}, 40000)
	b := newBootFiles(fstest.MapFS{"lpxelinux.0": {Data: loader}}, "http://10.99.0.1:8080", "1")
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	s := newTFTPServer(b)
	go s.Serve(c)
	defer s.Shutdown()

	cl, err := tftp.NewClient(c.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	cl.SetBlockSize(1456)
	cl.RequestTSize(true)
	for name, want := range map[string][]byte{"lpxelinux.0": loader, "/pxelinux.cfg/default": b.config} {
		wt, err := cl.Receive(name, "octet")
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if n, ok := wt.(tftp.IncomingTransfer).Size(); !ok || n != int64(len(want)) {
			t.Errorf("%s: tsize %d %v, want %d", name, n, ok, len(want))
		}
		var buf bytes.Buffer
		if _, err := wt.WriteTo(&buf); err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(buf.Bytes(), want) {
			t.Errorf("%s: content differs", name)
		}
	}
	if _, err := cl.Receive("vmlinuz", "octet"); err == nil {
		t.Errorf("missing file did not fail")
	}
}

func TestBootServerOverUDP(t *testing.T) {
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	go serveDHCP(plainConn{c}, pxeBootPort, newPXEServer(net.IPv4(127, 0, 0, 1), "lpxelinux.0", nil), 0)

	cl, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	req := pxeDiscover(t, dhcpv4.WithMessageType(dhcpv4.MessageTypeRequest), dhcpv4.WithBroadcast(false),
		dhcpv4.WithClientIP(net.IPv4(127, 0, 0, 1)))
	cl.WriteToUDP(req.ToBytes(), c.LocalAddr().(*net.UDPAddr))
	cl.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 1500)
	n, _, err := cl.ReadFromUDP(buf)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := dhcpv4.FromBytes(buf[:n])
	if err != nil || resp.MessageType() != dhcpv4.MessageTypeAck || resp.BootFileName != "lpxelinux.0" || resp.TransactionID != req.TransactionID {
		t.Errorf("reply %v %v", resp, err)
	}
}
