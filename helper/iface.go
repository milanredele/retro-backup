package main

import (
	"fmt"
	"net"
	"sort"
	"strings"
)

type ifaceInfo struct {
	Iface net.Interface
	Addrs []*net.IPNet // IPv4 only
}

// primary returns the first routable IPv4, else the first (link-local) one.
func (i ifaceInfo) primary() net.IP {
	for _, a := range i.Addrs {
		if !a.IP.IsLinkLocalUnicast() {
			return a.IP
		}
	}
	if len(i.Addrs) > 0 {
		return i.Addrs[0].IP
	}
	return nil
}

func (i ifaceInfo) addrInSubnet(n *net.IPNet) net.IP {
	for _, a := range i.Addrs {
		if n.Contains(a.IP) {
			return a.IP
		}
	}
	return nil
}

func (i ifaceInfo) String() string {
	return fmt.Sprintf("%-24s %s", i.Iface.Name, i.addrList())
}

func (i ifaceInfo) addrList() string {
	var as []string
	for _, a := range i.Addrs {
		s := a.String()
		if a.IP.IsLinkLocalUnicast() {
			s += " (link-local: no DHCP server answered this NIC)"
		}
		as = append(as, s)
	}
	return strings.Join(as, ", ")
}

// candidateInterfaces lists up, non-loopback, non-point-to-point interfaces
// with at least one IPv4 address.
func candidateInterfaces() ([]ifaceInfo, error) {
	ifs, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	var out []ifaceInfo
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 || ifc.Flags&net.FlagPointToPoint != 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		info := ifaceInfo{Iface: ifc}
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil {
				info.Addrs = append(info.Addrs, &net.IPNet{IP: n.IP.To4(), Mask: n.Mask})
			}
		}
		if len(info.Addrs) > 0 {
			out = append(out, info)
		}
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].Iface.Index < out[b].Iface.Index })
	return out, nil
}

func findInterface(cands []ifaceInfo, name string) *ifaceInfo {
	for i := range cands {
		if cands[i].Iface.Name == name {
			return &cands[i]
		}
	}
	for i := range cands {
		if strings.EqualFold(cands[i].Iface.Name, name) {
			return &cands[i]
		}
	}
	return nil
}

func listInterfaces(cands []ifaceInfo) string {
	var b strings.Builder
	for _, c := range cands {
		b.WriteString("  " + c.String() + "\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

// localIPFor picks the helper address a client at src should use: the
// address of the interface whose subnet contains src, else the source
// address the OS would route from, else fallback.
func localIPFor(src net.IP, fallback net.IP) net.IP {
	if src4 := src.To4(); src4 != nil && !src4.IsUnspecified() && !src4.Equal(net.IPv4bcast) {
		if addrs, err := net.InterfaceAddrs(); err == nil {
			for _, a := range addrs {
				if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil && n.Contains(src4) {
					return n.IP.To4()
				}
			}
		}
		if c, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: src4, Port: 9}); err == nil {
			ip := c.LocalAddr().(*net.UDPAddr).IP
			c.Close()
			if ip.To4() != nil && !ip.IsUnspecified() {
				return ip.To4()
			}
		}
	}
	return fallback
}
