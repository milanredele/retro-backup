package main

import (
	"crypto/rand"
	"errors"
	"io"
	"io/fs"
	"net"
	"strings"
	"time"

	"github.com/insomniacslk/dhcp/dhcpv4"
	"github.com/pin/tftp/v3"
)

// serveDHCP reads requests from conn and answers them via s.handle.
// wantIf, when non-zero, drops packets that arrived on another interface.
func serveDHCP(conn dhcpConn, port int, s *pxeServer, wantIf int) {
	buf := make([]byte, 2048)
	for {
		n, src, idx, err := conn.ReadFrom(buf)
		if err != nil {
			if isClosed(err) {
				return
			}
			continue
		}
		if wantIf != 0 && idx != 0 && idx != wantIf {
			continue
		}
		req, err := dhcpv4.FromBytes(buf[:n])
		if err != nil {
			continue
		}
		resp, dst := s.handle(req, port, src)
		if resp == nil || dst == nil {
			continue
		}
		if err := conn.WriteTo(marshalDHCP(resp), dst); err != nil {
			logf("DHCP: sending %s to %s failed: %v", resp.MessageType(), dst, err)
		}
	}
}

// newTFTPServer serves the boot files with blksize/tsize negotiation.
func newTFTPServer(b *bootFiles) *tftp.Server {
	read := func(name string, rf io.ReaderFrom) error {
		ot, _ := rf.(tftp.OutgoingTransfer)
		peer := "?"
		if ot != nil {
			ra := ot.RemoteAddr()
			peer = ra.IP.String()
		}
		rs, size, closeFn, err := b.open(name)
		if err != nil {
			// pxelinux probes pxelinux.cfg/<uuid>, 01-<mac>, C0A8... first.
			if c, _ := cleanName(name); !strings.HasPrefix(c, "pxelinux.cfg/") {
				logf("TFTP %s requested by %s: not found", name, peer)
			}
			if errors.Is(err, fs.ErrNotExist) {
				return errors.New("file not found")
			}
			return err
		}
		defer closeFn()
		if ot != nil {
			ot.SetSize(size)
		}
		start := time.Now()
		n, err := rf.ReadFrom(rs)
		if err != nil {
			logf("TFTP %s to %s failed after %d bytes: %v", name, peer, n, err)
			return err
		}
		logf("TFTP sent %s to %s (%s in %s)", name, peer, humanBytes(uint64(n)), time.Since(start).Round(time.Millisecond))
		return nil
	}
	s := tftp.NewServer(read, nil)
	s.SetTimeout(5 * time.Second)
	s.SetRetries(5)
	return s
}

func randomMAC() net.HardwareAddr {
	m := make(net.HardwareAddr, 6)
	rand.Read(m)
	m[0] = (m[0] | 0x02) &^ 0x01 // locally administered, unicast
	return m
}

// probeDHCPServers sends one DHCPDISCOVER from UDP 68 with a random MAC
// and collects the server identifiers that offer within wait. ran is false
// when port 68 is unavailable (the OS DHCP client holds it, or Linux without
// privileges), in which case nothing is known.
func probeDHCPServers(ifc *net.Interface, ip net.IP, self *pxeServer, wait time.Duration) (servers []net.IP, ran bool) {
	conn, err := listenDHCP(dhcpClientPort, ifc, ip, false)
	if err != nil {
		return nil, false
	}
	defer conn.Close()
	mac := randomMAC()
	if self != nil {
		self.ignoreMAC(mac)
	}
	disc, err := dhcpv4.NewDiscovery(mac, dhcpv4.WithBroadcast(true))
	if err != nil {
		return nil, false
	}
	if err := conn.WriteTo(disc.ToBytes(), &net.UDPAddr{IP: net.IPv4bcast, Port: dhcpServerPort}); err != nil {
		return nil, false
	}
	deadline := time.Now().Add(wait)
	buf := make([]byte, 2048)
	seen := map[string]bool{}
	for time.Now().Before(deadline) {
		conn.SetReadDeadline(deadline)
		n, _, _, err := conn.ReadFrom(buf)
		if err != nil {
			break
		}
		resp, err := dhcpv4.FromBytes(buf[:n])
		if err != nil || resp.TransactionID != disc.TransactionID || resp.MessageType() != dhcpv4.MessageTypeOffer {
			continue
		}
		sid := resp.ServerIdentifier()
		if sid == nil {
			sid = resp.ServerIPAddr
		}
		if sid == nil || (self != nil && sid.Equal(self.serverIP)) || seen[sid.String()] {
			continue
		}
		seen[sid.String()] = true
		servers = append(servers, sid)
	}
	return servers, true
}
