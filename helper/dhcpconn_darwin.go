//go:build darwin

package main

import (
	"context"
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

func listenDHCP(port int, ifc *net.Interface, ip net.IP, bindAny bool) (dhcpConn, error) {
	lc := net.ListenConfig{}
	if ifc != nil && !bindAny {
		idx := ifc.Index
		lc.Control = func(network, address string, rc syscall.RawConn) error {
			var serr error
			err := rc.Control(func(fd uintptr) {
				serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, idx)
			})
			if err != nil {
				return err
			}
			return serr
		}
	}
	pc, err := lc.ListenPacket(context.Background(), "udp4", addrString(nil, port))
	if err != nil {
		return nil, err
	}
	return plainConn{pc.(*net.UDPConn)}, nil
}
