package main

import (
	"archive/tar"
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if os.Getenv("RETRO_TEST_LOG") == "" {
		setLogOutput(io.Discard)
	}
	os.Exit(m.Run())
}

type member struct {
	name string
	typ  byte
	body []byte
	link string
}

var testMtime = time.Date(2007, 6, 15, 10, 30, 0, 0, time.UTC)

func md5hex(b []byte) string {
	s := md5.Sum(b)
	return hex.EncodeToString(s[:])
}

// buildTar writes members, then a manifest built from manifest lines.
func buildTar(t *testing.T, ms []member, manifest []string) []byte {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, m := range ms {
		h := &tar.Header{Name: m.name, Typeflag: m.typ, Mode: 0o644, ModTime: testMtime, Format: tar.FormatPAX}
		switch m.typ {
		case tar.TypeReg:
			h.Size = int64(len(m.body))
		case tar.TypeDir:
			h.Mode = 0o755
		case tar.TypeSymlink:
			h.Linkname = m.link
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if m.typ == tar.TypeReg {
			tw.Write(m.body)
		}
	}
	if manifest != nil {
		mf := []byte(strings.Join(manifest, "\n") + "\n")
		tw.WriteHeader(&tar.Header{Name: manifestMember, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(mf)), ModTime: time.Now()})
		tw.Write(mf)
	}
	tw.Close()
	return buf.Bytes()
}

func manifestLine(path string, body []byte) string {
	return fmt.Sprintf("%s\t%d\t%d\t%s", path, len(body), testMtime.Unix(), md5hex(body))
}

func postUpload(t *testing.T, base, machine, volume, group string, body []byte) (int, uploadResult) {
	t.Helper()
	q := url.Values{"machine": {machine}, "volume": {volume}, "group": {group}}
	resp, err := http.Post(base+"/upload?"+q.Encode(), "application/x-tar", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var res uploadResult
	if err := json.NewDecoder(resp.Body).Decode(&res); err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, res
}

func getJSON(t *testing.T, u string, v any) {
	t.Helper()
	resp, err := http.Get(u)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("GET %s: %s", u, resp.Status)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/json" {
		t.Fatalf("GET %s: content type %q", u, ct)
	}
	if err := json.NewDecoder(resp.Body).Decode(v); err != nil {
		t.Fatal(err)
	}
}

type resumeResp struct {
	Files []resumeFile `json:"files"`
}

func resumePaths(t *testing.T, base, m, v, g string) map[string]resumeFile {
	var rr resumeResp
	q := url.Values{"machine": {m}, "volume": {v}, "group": {g}}
	getJSON(t, base+"/resume?"+q.Encode(), &rr)
	out := map[string]resumeFile{}
	for _, f := range rr.Files {
		out[f.Path] = f
	}
	return out
}

func newTestServer(t *testing.T) (*receiver, *httptest.Server) {
	rc := newReceiver(t.TempDir(), "9.9", newStats())
	srv := httptest.NewServer(newMux(rc, nil))
	t.Cleanup(srv.Close)
	return rc, srv
}

func TestReceiverEndToEnd(t *testing.T) {
	rc, srv := newTestServer(t)

	rnd := rand.New(rand.NewSource(1))
	big := make([]byte, 5<<20)
	rnd.Read(big)
	letter := []byte("Kedves Jóska,\r\nszia!\r\n")
	photo := []byte("\xff\xd8\xff\xe0 not really a jpeg")
	report := []byte("final numbers\n")
	bad := []byte("this file will be declared corrupt\n")

	const (
		docs     = "Documents and Settings/Jóska/My Documents"
		pLetter  = docs + "/letter.doc"
		pReport  = docs + "/report: final?.txt"
		pReport2 = docs + "/report_ final_.txt"
		pPhoto   = "Fotók 2007/nyár/kép 001.jpg"
		pBig     = "Fotók 2007/big.bin"
		pBad     = "bad.txt"
	)
	members := []member{
		{name: "Documents and Settings/", typ: tar.TypeDir},
		{name: "Documents and Settings/Jóska/", typ: tar.TypeDir},
		{name: docs + "/", typ: tar.TypeDir},
		{name: "./" + pLetter, typ: tar.TypeReg, body: letter},
		{name: pReport, typ: tar.TypeReg, body: report},
		{name: "Fotók 2007/", typ: tar.TypeDir},
		{name: "Fotók 2007/nyár/", typ: tar.TypeDir},
		{name: pPhoto, typ: tar.TypeReg, body: photo},
		{name: pBig, typ: tar.TypeReg, body: big},
		{name: "../../escape.txt", typ: tar.TypeReg, body: []byte("evil")},
		{name: "Fotók 2007/../../../escape2.txt", typ: tar.TypeReg, body: []byte("evil")},
		{name: "/etc/passwd", typ: tar.TypeReg, body: []byte("evil")},
		{name: "link", typ: tar.TypeSymlink, link: "/etc/passwd"},
		{name: pBad, typ: tar.TypeReg, body: bad},
	}
	manifest := []string{
		manifestLine(pLetter, letter),
		manifestLine(pReport, report),
		manifestLine(pPhoto, photo),
		manifestLine(pBig, big),
		fmt.Sprintf("%s\t%d\t%d\t%s", pBad, len(bad), testMtime.Unix(), strings.Repeat("0", 32)),
	}
	code, res := postUpload(t, srv.URL, "JOSKA-PC", "SYSTEM", "g0001", buildTar(t, members, manifest))
	if code != 200 {
		t.Fatalf("upload status %d: %+v", code, res)
	}
	if res.Received != 5 || res.Verified != 4 || res.Bytes != int64(len(letter)+len(report)+len(photo)+len(big)+len(bad)) {
		t.Errorf("received %d verified %d bytes %d", res.Received, res.Verified, res.Bytes)
	}
	if len(res.Mismatched) != 1 || res.Mismatched[0] != pBad {
		t.Errorf("mismatched = %q", res.Mismatched)
	}
	if len(res.Renamed) != 1 || res.Renamed[0] != [2]string{pReport, pReport2} {
		t.Errorf("renamed = %q", res.Renamed)
	}
	sort.Strings(res.Rejected)
	if want := []string{"../../escape.txt", "/etc/passwd", "Fotók 2007/../../../escape2.txt", "link"}; strings.Join(res.Rejected, "|") != strings.Join(want, "|") {
		t.Errorf("rejected = %q", res.Rejected)
	}
	if !res.Manifest || len(res.Missing) != 0 || len(res.Errors) != 0 {
		t.Errorf("manifest %v missing %q errors %q", res.Manifest, res.Missing, res.Errors)
	}

	vol := filepath.Join(rc.dest, "BACKUP", "JOSKA-PC", "SYSTEM")
	for p, want := range map[string][]byte{pLetter: letter, pReport2: report, pPhoto: photo, pBig: big, pBad + corruptSuffix: bad} {
		fp := filepath.Join(vol, filepath.FromSlash(p))
		got, err := os.ReadFile(fp)
		if err != nil {
			t.Errorf("%s: %v", p, err)
			continue
		}
		if !bytes.Equal(got, want) {
			t.Errorf("%s: content differs", p)
		}
		if fi, _ := os.Stat(fp); !fi.ModTime().Equal(testMtime) {
			t.Errorf("%s: mtime %v, want %v", p, fi.ModTime(), testMtime)
		}
	}
	if fi, err := os.Stat(filepath.Join(vol, "Fotók 2007", "nyár")); err != nil || !fi.ModTime().Equal(testMtime) {
		t.Errorf("directory mtime not preserved: %v %v", fi, err)
	}
	for _, p := range []string{pBad, pReport, "link", "escape.txt"} {
		if _, err := os.Lstat(filepath.Join(vol, filepath.FromSlash(p))); err == nil {
			t.Errorf("%s should not exist", p)
		}
	}
	for _, p := range []string{filepath.Join(rc.dest, "escape.txt"), filepath.Join(rc.dest, "BACKUP", "escape.txt"), filepath.Join(rc.dest, "BACKUP", "JOSKA-PC", "escape.txt")} {
		if _, err := os.Stat(p); err == nil {
			t.Errorf("traversal wrote %s", p)
		}
	}
	matches, _ := filepath.Glob(filepath.Join(vol, "*", "*"+partSuffix))
	if len(matches) > 0 {
		t.Errorf("temporary files left: %q", matches)
	}
	mf, err := os.ReadFile(filepath.Join(vol, "MANIFEST.tsv"))
	if err != nil || strings.Count(string(mf), "\n") != 5 || !strings.Contains(string(mf), pReport2+"\t") {
		t.Errorf("MANIFEST.tsv: %v\n%s", err, mf)
	}

	rs := resumePaths(t, srv.URL, "JOSKA-PC", "SYSTEM", "g0001")
	if len(rs) != 4 {
		t.Errorf("resume has %d files, want 4: %v", len(rs), rs)
	}
	if f, ok := rs[pReport]; !ok || f.Stored != pReport2 || f.MD5 != md5hex(report) {
		t.Errorf("resume entry for renamed file: %+v", f)
	}
	if f := rs[pBig]; f.Size != int64(len(big)) || f.MD5 != md5hex(big) {
		t.Errorf("resume entry for big file: %+v", f)
	}
	if _, ok := rs[pBad]; ok {
		t.Errorf("corrupt file listed in resume")
	}

	// Second upload of the group: the client skipped what /resume listed
	// except letter.doc (resent identical) and sends bad.txt again, good.
	members2 := []member{
		{name: pLetter, typ: tar.TypeReg, body: letter},
		{name: pBad, typ: tar.TypeReg, body: bad},
	}
	manifest2 := append(manifest[:4:4], manifestLine(pBad, bad))
	before, _ := os.Stat(filepath.Join(vol, filepath.FromSlash(pLetter)))
	code, res = postUpload(t, srv.URL, "JOSKA-PC", "SYSTEM", "g0001", buildTar(t, members2, manifest2))
	if code != 200 || res.Received != 2 || res.Verified != 5 || len(res.Mismatched) != 0 || len(res.Missing) != 0 {
		t.Fatalf("second upload: %d %+v", code, res)
	}
	if res.Kept != 4 { // letter resent identical + 3 not resent
		t.Errorf("kept = %d, want 4", res.Kept)
	}
	after, _ := os.Stat(filepath.Join(vol, filepath.FromSlash(pLetter)))
	if !os.SameFile(before, after) {
		t.Errorf("identical file was replaced instead of kept")
	}
	if got, _ := os.ReadFile(filepath.Join(vol, pBad)); !bytes.Equal(got, bad) {
		t.Errorf("bad.txt not stored on second upload")
	}
	if rs := resumePaths(t, srv.URL, "JOSKA-PC", "SYSTEM", "g0001"); len(rs) != 5 {
		t.Errorf("resume after second upload: %d files", len(rs))
	}
	mf, _ = os.ReadFile(filepath.Join(vol, "MANIFEST.tsv"))
	if n := strings.Count(string(mf), "\n"); n != 5 {
		t.Errorf("MANIFEST.tsv has %d lines after re-upload, want 5", n)
	}
	if rs := resumePaths(t, srv.URL, "JOSKA-PC", "SYSTEM", "g0002"); len(rs) != 0 {
		t.Errorf("other group not empty")
	}
}

func TestReceiverTruncatedUploadResumes(t *testing.T) {
	rc, srv := newTestServer(t)
	a := bytes.Repeat([]byte("a"), 100_000)
	b := bytes.Repeat([]byte("b"), 300_000)
	full := buildTar(t, []member{{name: "a.bin", typ: tar.TypeReg, body: a}, {name: "b.bin", typ: tar.TypeReg, body: b}}, nil)
	cut := full[:len(full)/2] // inside b.bin
	code, res := postUpload(t, srv.URL, "M", "V", "g1", cut)
	if code != http.StatusBadRequest || res.Received != 1 || res.Error == "" {
		t.Fatalf("truncated upload: %d %+v", code, res)
	}
	vol := filepath.Join(rc.dest, "BACKUP", "M", "V")
	if _, err := os.Stat(filepath.Join(vol, "b.bin")); err == nil {
		t.Errorf("partial b.bin left under its real name")
	}
	if _, err := os.Stat(filepath.Join(vol, "b.bin"+partSuffix)); err == nil {
		t.Errorf("partial temp file left")
	}
	rs := resumePaths(t, srv.URL, "M", "V", "g1")
	if len(rs) != 1 || rs["a.bin"].MD5 != md5hex(a) {
		t.Errorf("resume after truncation: %v", rs)
	}
}

func TestReceiverProbeAndNames(t *testing.T) {
	rc, srv := newTestServer(t)
	junk := make([]byte, 1<<20)
	code, res := postUpload(t, srv.URL, "_probe", "_probe", "_probe", buildTar(t, []member{{name: "junk", typ: tar.TypeReg, body: junk}}, nil))
	if code != 200 || res.Received != 1 || res.Bytes != int64(len(junk)) || res.BodyBytes < int64(len(junk)) {
		t.Errorf("probe: %d %+v", code, res)
	}
	if _, err := os.Stat(filepath.Join(rc.dest, "BACKUP")); err == nil {
		t.Errorf("probe wrote to disk")
	}
	// Junk that is not a tar is accepted too.
	if code, _ := postUpload(t, srv.URL, "_probe", "_probe", "_probe", bytes.Repeat([]byte{0x55}, 10000)); code != 200 {
		t.Errorf("non-tar probe: %d", code)
	}

	// machine/volume/group are sanitised.
	code, res = postUpload(t, srv.URL, "Jóska PC/../x", "D:", "g 1", buildTar(t, []member{{name: "f.txt", typ: tar.TypeReg, body: []byte("x")}}, nil))
	if code != 200 || res.Machine != "J_ska_PC_.._x" || res.Volume != "D_" || res.Group != "g_1" {
		t.Errorf("names: %d %+v", code, res)
	}
	if _, err := os.Stat(filepath.Join(rc.dest, "BACKUP", "J_ska_PC_.._x", "D_", "f.txt")); err != nil {
		t.Error(err)
	}
	if code, _ := postUpload(t, srv.URL, "M", "", "g", nil); code != http.StatusBadRequest {
		t.Errorf("missing volume: %d", code)
	}
}

func TestReceiverCollisionAndIndexDir(t *testing.T) {
	rc, srv := newTestServer(t)
	ms := []member{
		{name: "a?.txt", typ: tar.TypeReg, body: []byte("1")},
		{name: "a*.txt", typ: tar.TypeReg, body: []byte("2")},
		{name: ".retro-index/x.tsv", typ: tar.TypeReg, body: []byte("3")},
	}
	_, res := postUpload(t, srv.URL, "M", "V", "g", buildTar(t, ms, nil))
	vol := filepath.Join(rc.dest, "BACKUP", "M", "V")
	for p, want := range map[string]string{"a_.txt": "1", "a_~2.txt": "2", "_retro-index/x.tsv": "3"} {
		if got, err := os.ReadFile(filepath.Join(vol, filepath.FromSlash(p))); err != nil || string(got) != want {
			t.Errorf("%s: %q %v", p, got, err)
		}
	}
	if len(res.Renamed) != 3 {
		t.Errorf("renamed: %q", res.Renamed)
	}
}

func TestStatusFreeLog(t *testing.T) {
	rc, srv := newTestServer(t)
	var st map[string]any
	getJSON(t, srv.URL+"/status", &st)
	if st["name"] != "retro-helper" || st["version"] != "9.9" || st["dest"] != rc.dest {
		t.Errorf("status: %v", st)
	}
	if n, ok := st["free_bytes"].(float64); !ok || n <= 0 {
		t.Errorf("status free_bytes: %v", st["free_bytes"])
	}
	if len(st) != 4 {
		t.Errorf("status has extra keys: %v", st)
	}
	var fr map[string]any
	getJSON(t, srv.URL+"/free", &fr)
	if n, ok := fr["free_bytes"].(float64); !ok || n <= 0 || len(fr) != 1 {
		t.Errorf("free: %v", fr)
	}
	for _, chunk := range []string{"line one\n", "line two\n"} {
		resp, err := http.Post(srv.URL+"/log?machine=JOSKA-PC", "text/plain", strings.NewReader(chunk))
		if err != nil {
			t.Fatal(err)
		}
		var ok map[string]bool
		json.NewDecoder(resp.Body).Decode(&ok)
		resp.Body.Close()
		if !ok["ok"] {
			t.Errorf("log response %v", ok)
		}
	}
	got, err := os.ReadFile(filepath.Join(rc.dest, "BACKUP", "JOSKA-PC", "retro-backup.log"))
	if err != nil || string(got) != "line one\nline two\n" {
		t.Errorf("log file: %q %v", got, err)
	}
	resp, _ := http.Post(srv.URL+"/status", "text/plain", nil)
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST /status: %d", resp.StatusCode)
	}
	resp.Body.Close()
}
