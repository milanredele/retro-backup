package main

import (
	"errors"
	"fmt"
	"net"
	"strings"
)

// Discovery beacon (CONTRACTS.md section 4): a client broadcasts
// "RETRO-HELPER?" to UDP 9999 and gets "RETRO-HELPER http://<ip>:<port>".

const beaconQuery = "RETRO-HELPER?"

type beacon struct {
	conn     net.PacketConn
	httpPort int
	fallback net.IP
}

func beaconAnswer(ip net.IP, port int) string {
	return fmt.Sprintf("RETRO-HELPER http://%s:%d", ip, port)
}

func (b *beacon) serve() {
	buf := make([]byte, 512)
	for {
		n, addr, err := b.conn.ReadFrom(buf)
		if err != nil {
			if isClosed(err) {
				return
			}
			continue
		}
		if strings.TrimSpace(string(buf[:n])) != beaconQuery {
			continue
		}
		ua, ok := addr.(*net.UDPAddr)
		if !ok {
			continue
		}
		ip := localIPFor(ua.IP, b.fallback)
		if ip == nil {
			continue
		}
		msg := beaconAnswer(ip, b.httpPort)
		if _, err := b.conn.WriteTo([]byte(msg), addr); err != nil {
			logf("beacon: reply to %s failed: %v", addr, err)
			continue
		}
		logf("beacon: %s asked, answered %s", ua.IP, msg)
	}
}

func isClosed(err error) bool { return errors.Is(err, net.ErrClosed) }
