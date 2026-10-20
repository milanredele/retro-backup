//go:build windows

package main

import "net"

func listenDHCP(port int, ifc *net.Interface, ip net.IP, bindAny bool) (dhcpConn, error) {
	bind := ip
	if bindAny || ip == nil {
		bind = net.IPv4zero
	}
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: bind, Port: port})
	if err != nil {
		return nil, err
	}
	return plainConn{c}, nil
}
