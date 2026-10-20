//go:build !linux && !darwin && !windows

package main

import "net"

func listenDHCP(port int, ifc *net.Interface, ip net.IP, bindAny bool) (dhcpConn, error) {
	return listenPlain(port)
}
