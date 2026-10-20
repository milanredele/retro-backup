package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func TestPXEConfigAndBootHTTP(t *testing.T) {
	big := strings.Repeat("K", 100000)
	fsys := fstest.MapFS{"lpxelinux.0": {Data: []byte("PXE")}, "vmlinuz": {Data: []byte(big)}}
	b := newBootFiles(fsys, "http://192.168.1.23:8080", "1.0")
	if b.missing {
		t.Errorf("lpxelinux.0 reported missing")
	}
	cfg := string(b.config)
	for _, want := range []string{
		"KERNEL http://192.168.1.23:8080/boot/vmlinuz\n",
		"APPEND initrd=http://192.168.1.23:8080/boot/retro.gz quiet nomodeset vga=788 vt.default_utf8=1 norestore noswap nodhcp base rootfstype=ramfs retro.boot=pxe retro.dest=http://192.168.1.23:8080\n",
	} {
		if !strings.Contains(cfg, want) {
			t.Errorf("config lacks %q:\n%s", want, cfg)
		}
	}
	rc := newReceiver(t.TempDir(), "1.0", newStats())
	srv := httptest.NewServer(newMux(rc, b))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/boot/pxelinux.cfg/default")
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(got) != cfg {
		t.Errorf("served config differs")
	}

	req, _ := http.NewRequest("GET", srv.URL+"/boot/vmlinuz", nil)
	req.Header.Set("Range", "bytes=99990-")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	got, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent || string(got) != "KKKKKKKKKK" {
		t.Errorf("range: %d %q", resp.StatusCode, got)
	}
	for _, p := range []string{"/boot/retro.gz", "/boot/../main.go", "/boot/%2e%2e/x"} {
		resp, _ := http.Get(srv.URL + p)
		if resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s: %d", p, resp.StatusCode)
		}
		resp.Body.Close()
	}

	// The embedded placeholder directory has no boot loader.
	if !newBootFiles(embeddedBootFS(), "http://x:8080", "1").missing {
		t.Log("real boot files are embedded")
	}
}

func TestCleanName(t *testing.T) {
	for in, want := range map[string]string{"/lpxelinux.0": "lpxelinux.0", "pxelinux.cfg\\default": "pxelinux.cfg/default", "./a": "a"} {
		if got, ok := cleanName(in); !ok || got != want {
			t.Errorf("cleanName(%q) = %q %v", in, got, ok)
		}
	}
	for _, in := range []string{"", "/", "../x", "a/../../b"} {
		if _, ok := cleanName(in); ok {
			t.Errorf("cleanName(%q) accepted", in)
		}
	}
}
