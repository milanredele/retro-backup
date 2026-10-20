package main

import (
	"net"
	"testing"
	"time"
)

func TestBeaconRoundTrip(t *testing.T) {
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	go (&beacon{conn: c, httpPort: 8080, fallback: net.IPv4(10, 0, 0, 1)}).serve()

	cl, err := net.DialUDP("udp4", nil, c.LocalAddr().(*net.UDPAddr))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	cl.Write([]byte("hello?")) // ignored
	cl.Write([]byte("RETRO-HELPER?\n"))
	cl.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 256)
	n, err := cl.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(buf[:n]), "RETRO-HELPER http://127.0.0.1:8080"; got != want {
		t.Errorf("beacon answered %q, want %q", got, want)
	}
}
