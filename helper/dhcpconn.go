package main

import (
	"fmt"
	"net"
	"time"
)

// dhcpConn is a UDP socket for DHCP that can receive broadcasts and send
// limited broadcasts out of the chosen interface, without raw sockets.
// The per-OS constructor listenDHCP is in dhcpconn_<os>.go:
//
//   - linux: bound to 0.0.0.0:port; IP_PKTINFO (golang.org/x/net/ipv4)
//     reports the arrival interface and selects the outgoing one.
//   - darwin: bound to 0.0.0.0:port with IP_BOUND_IF = interface index, so
//     the socket only sees and sends on that interface.
//   - windows: bound to <interface IP>:port; Windows delivers broadcasts
//     arriving on that interface to such a socket and sends 255.255.255.255
//     out of it. --dhcp-bind-any binds 0.0.0.0 instead.
type dhcpConn interface {
	// ReadFrom returns the arrival interface index, or 0 when unknown.
	ReadFrom(b []byte) (n int, src *net.UDPAddr, ifIndex int, err error)
	WriteTo(b []byte, dst *net.UDPAddr) error
	SetReadDeadline(t time.Time) error
	Close() error
}

// plainConn is a wildcard-bound UDP socket with no interface information.
type plainConn struct{ c *net.UDPConn }

func (p plainConn) ReadFrom(b []byte) (int, *net.UDPAddr, int, error) {
	n, a, err := p.c.ReadFromUDP(b)
	return n, a, 0, err
}

func (p plainConn) WriteTo(b []byte, dst *net.UDPAddr) error {
	_, err := p.c.WriteToUDP(b, dst)
	return err
}

func (p plainConn) SetReadDeadline(t time.Time) error { return p.c.SetReadDeadline(t) }
func (p plainConn) Close() error                      { return p.c.Close() }

func listenPlain(port int) (dhcpConn, error) {
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: port})
	if err != nil {
		return nil, err
	}
	return plainConn{c}, nil
}

func addrString(ip net.IP, port int) string {
	if ip == nil {
		ip = net.IPv4zero
	}
	return fmt.Sprintf("%s:%d", ip, port)
}
