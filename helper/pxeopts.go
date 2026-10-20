package main

import (
	"encoding/binary"
	"net"
	"sort"

	"github.com/insomniacslk/dhcp/dhcpv4"
)

// PXE vendor options (DHCP option 43 when option 60 is "PXEClient").
//
// Reference: Intel "Preboot Execution Environment (PXE) Specification"
// version 2.1 (1999), section 2.2.3 (PXE vendor options) and section 2.2.5
// (boot server discovery); same layout as dnsmasq's proxy mode
// (dhcp-range=...,proxy + pxe-service=x86PC,...), which is known to work with
// Intel, Realtek, Broadcom, 3Com MBA and iPXE ROMs.
//
// ProxyDHCP OFFER (UDP 67 -> client 68), option 43 contents in this order:
//
//	06 01 07                     PXE_DISCOVERY_CONTROL = 7:
//	                             bit0 no broadcast discovery, bit1 no multicast
//	                             discovery, bit2 only servers from option 8;
//	                             bit3 (use the offer's boot file directly) is
//	                             left clear so classic ROMs do the 4011 request
//	08 07 80 00 01 a.b.c.d       PXE_BOOT_SERVERS: type 0x8000, 1 address = us
//	09 0f 80 00 0c "retro-backup" PXE_BOOT_MENU: one item, type 0x8000
//	0a 0d 00 "retro-backup"      PXE_MENU_PROMPT: timeout 0 = select the first
//	                             (only) item immediately, no F8 prompt
//	47 04 80 00 00 00            PXE_BOOT_ITEM: type 0x8000, layer 0
//	ff                           end of vendor options
//
// Boot server type 0x8000 is the first vendor-specific type (dnsmasq numbers
// its pxe-service entries from 0x8000 too); type 0 would mean "local boot".
//
// Boot-server ACK (UDP 4011 -> client), option 43 = 47 04 80 00 00 00 ff,
// echoing the type/layer the client asked for in its own option 43/71.
//
// Besides option 43 both replies carry option 60 "PXEClient", option 54 and
// siaddr = helper IP, option 66 = helper IP, option 67 and the BOOTP file
// field = lpxelinux.0, and option 97 echoed from the client (the PXE spec
// requires the server to return the client's UUID). iPXE and other clients
// that skip boot server discovery use siaddr/file from the offer directly.
const (
	pxeDiscoveryControl = 6
	pxeBootServers      = 8
	pxeBootMenu         = 9
	pxeMenuPrompt       = 10
	pxeBootItem         = 71
	pxeVendorEnd        = 255

	pxeServerType  = 0x8000
	pxeMenuText    = "retro-backup"
	pxeControlBits = 0x07
)

func appendSub(b []byte, code byte, data []byte) []byte {
	b = append(b, code, byte(len(data)))
	return append(b, data...)
}

// pxeOfferVendorOptions builds option 43 for the proxyDHCP offer.
func pxeOfferVendorOptions(server net.IP) []byte {
	var b []byte
	b = appendSub(b, pxeDiscoveryControl, []byte{pxeControlBits})
	srv := []byte{pxeServerType >> 8, pxeServerType & 0xff, 1}
	srv = append(srv, server.To4()...)
	b = appendSub(b, pxeBootServers, srv)
	menu := []byte{pxeServerType >> 8, pxeServerType & 0xff, byte(len(pxeMenuText))}
	menu = append(menu, pxeMenuText...)
	b = appendSub(b, pxeBootMenu, menu)
	b = appendSub(b, pxeMenuPrompt, append([]byte{0}, pxeMenuText...))
	b = appendSub(b, pxeBootItem, []byte{pxeServerType >> 8, pxeServerType & 0xff, 0, 0})
	return append(b, pxeVendorEnd)
}

// pxeAckVendorOptions builds option 43 for the boot-server ACK.
func pxeAckVendorOptions(typ, layer uint16) []byte {
	item := make([]byte, 4)
	binary.BigEndian.PutUint16(item, typ)
	binary.BigEndian.PutUint16(item[2:], layer)
	return append(appendSub(nil, pxeBootItem, item), pxeVendorEnd)
}

// parseVendorSubOptions splits option 43 into sub-options.
func parseVendorSubOptions(b []byte) map[byte][]byte {
	out := map[byte][]byte{}
	for i := 0; i < len(b); {
		code := b[i]
		if code == 0 {
			i++
			continue
		}
		if code == pxeVendorEnd || i+1 >= len(b) {
			break
		}
		l := int(b[i+1])
		if i+2+l > len(b) {
			break
		}
		out[code] = b[i+2 : i+2+l]
		i += 2 + l
	}
	return out
}

// marshalDHCP serialises a reply with option 53 first and 54 second (some
// old PXE ROMs only look at the first option for the message type, which is
// also what dnsmasq and ISC dhcpd do), 82 last, then end and padding to the
// 300-byte BOOTP minimum.
func marshalDHCP(d *dhcpv4.DHCPv4) []byte {
	raw := d.ToBytes()
	out := append([]byte{}, raw[:240]...) // fixed header + magic cookie
	put := func(code uint8, data []byte) {
		if len(data) == 0 {
			out = append(out, code, 0)
			return
		}
		for len(data) > 0 {
			n := len(data)
			if n > 255 {
				n = 255
			}
			out = append(out, code, byte(n))
			out = append(out, data[:n]...)
			data = data[n:]
		}
	}
	var codes []int
	for c := range d.Options {
		switch c {
		case 0, 53, 54, 82, 255:
		default:
			codes = append(codes, int(c))
		}
	}
	sort.Ints(codes)
	for _, c := range []uint8{53, 54} {
		if v, ok := d.Options[c]; ok {
			put(c, v)
		}
	}
	for _, c := range codes {
		put(uint8(c), d.Options[uint8(c)])
	}
	if v, ok := d.Options[82]; ok {
		put(82, v)
	}
	out = append(out, 255)
	for len(out) < 300 {
		out = append(out, 0)
	}
	return out
}
