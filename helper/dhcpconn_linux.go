//go:build linux

package main

import (
	"net"
	"time"

	"golang.org/x/net/ipv4"
)

type pktinfoConn struct {
	c       *net.UDPConn
	p       *ipv4.PacketConn
	ifIndex int
	src     net.IP
}

func listenDHCP(port int, ifc *net.Interface, ip net.IP, bindAny bool) (dhcpConn, error) {
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: port})
	if err != nil {
		return nil, err
	}
	p := ipv4.NewPacketConn(c)
	if ifc == nil || p.SetControlMessage(ipv4.FlagInterface, true) != nil {
		return plainConn{c}, nil
	}
	return &pktinfoConn{c: c, p: p, ifIndex: ifc.Index, src: ip}, nil
}

func (k *pktinfoConn) ReadFrom(b []byte) (int, *net.UDPAddr, int, error) {
	n, cm, a, err := k.p.ReadFrom(b)
	ua, _ := a.(*net.UDPAddr)
	idx := 0
	if cm != nil {
		idx = cm.IfIndex
	}
	return n, ua, idx, err
}

func (k *pktinfoConn) WriteTo(b []byte, dst *net.UDPAddr) error {
	var cm *ipv4.ControlMessage
	if dst.IP.Equal(net.IPv4bcast) {
		cm = &ipv4.ControlMessage{IfIndex: k.ifIndex}
	}
	_, err := k.p.WriteTo(b, cm, dst)
	return err
}

func (k *pktinfoConn) SetReadDeadline(t time.Time) error { return k.c.SetReadDeadline(t) }
func (k *pktinfoConn) Close() error                      { return k.c.Close() }
