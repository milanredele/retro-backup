package main

import (
	"archive/tar"
	"bufio"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Receiver: the HTTP API of CONTRACTS.md section 4.

const (
	manifestMember = ".retro-manifest.tsv"
	partSuffix     = ".retro-part"
	corruptSuffix  = ".CORRUPT"
	progressEvery  = 10 * time.Second
)

type receiver struct {
	dest    string // absolute destination directory
	version string
	stats   *stats
	windows bool // apply Windows reserved-name rule

	mu   sync.Mutex
	busy map[string]bool // machine/volume/group uploads in progress

	manifestMu sync.Mutex // MANIFEST.tsv regeneration
	logMu      sync.Mutex // retro-backup.log appends
}

func newReceiver(dest, version string, st *stats) *receiver {
	return &receiver{dest: dest, version: version, stats: st, windows: runtime.GOOS == "windows", busy: map[string]bool{}}
}

func (rc *receiver) register(mux *http.ServeMux) {
	mux.HandleFunc("/status", rc.handleStatus)
	mux.HandleFunc("/free", rc.handleFree)
	mux.HandleFunc("/resume", rc.handleResume)
	mux.HandleFunc("/upload", rc.handleUpload)
	mux.HandleFunc("/log", rc.handleLog)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	enc.Encode(v)
}

func jsonError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func allowMethods(w http.ResponseWriter, r *http.Request, methods ...string) bool {
	for _, m := range methods {
		if r.Method == m {
			return true
		}
	}
	w.Header().Set("Allow", strings.Join(methods, ", "))
	jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
	return false
}

func (rc *receiver) free() uint64 {
	n, err := freeBytes(rc.dest)
	if err != nil {
		logf("WARN cannot read free space of %s: %v", rc.dest, err)
	}
	return n
}

func (rc *receiver) handleStatus(w http.ResponseWriter, r *http.Request) {
	if !allowMethods(w, r, http.MethodGet, http.MethodHead) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"name":       "retro-helper",
		"version":    rc.version,
		"dest":       rc.dest,
		"free_bytes": rc.free(),
	})
}

func (rc *receiver) handleFree(w http.ResponseWriter, r *http.Request) {
	if !allowMethods(w, r, http.MethodGet, http.MethodHead) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"free_bytes": rc.free()})
}

// target sanitises machine, volume and group from the query string.
func targetNames(r *http.Request) (m, v, g string, ok bool) {
	q := r.URL.Query()
	m, v, g = q.Get("machine"), q.Get("volume"), q.Get("group")
	return m, v, g, m != "" && v != "" && g != ""
}

func (rc *receiver) volDir(m, v string) string {
	return filepath.Join(rc.dest, "BACKUP", m, v)
}

type resumeFile struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	MD5    string `json:"md5"`
	Stored string `json:"stored,omitempty"` // only when the name was sanitised
}

func (rc *receiver) handleResume(w http.ResponseWriter, r *http.Request) {
	if !allowMethods(w, r, http.MethodGet, http.MethodHead) {
		return
	}
	m, v, g, ok := targetNames(r)
	if !ok {
		jsonError(w, http.StatusBadRequest, "machine, volume and group are required")
		return
	}
	vd := rc.volDir(sanitizeName(m), sanitizeName(v))
	idx, err := loadIndex(indexPath(vd, sanitizeName(g)))
	if err != nil {
		jsonError(w, http.StatusInternalServerError, err.Error())
		return
	}
	files := []resumeFile{}
	for _, e := range idx.sorted() {
		// Cheap sanity check: the file must still be there with its size.
		fi, err := os.Stat(filepath.Join(vd, filepath.FromSlash(e.Stored)))
		if err != nil || !fi.Mode().IsRegular() || fi.Size() != e.Size {
			continue
		}
		rf := resumeFile{Path: e.Orig, Size: e.Size, MD5: e.MD5}
		if e.Stored != e.Orig {
			rf.Stored = e.Stored
		}
		files = append(files, rf)
	}
	writeJSON(w, http.StatusOK, map[string]any{"files": files})
}

func (rc *receiver) handleLog(w http.ResponseWriter, r *http.Request) {
	if !allowMethods(w, r, http.MethodPost, http.MethodPut) {
		return
	}
	m := r.URL.Query().Get("machine")
	if m == "" {
		jsonError(w, http.StatusBadRequest, "machine is required")
		return
	}
	dir := filepath.Join(rc.dest, "BACKUP", sanitizeName(m))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		jsonError(w, http.StatusInternalServerError, err.Error())
		return
	}
	rc.logMu.Lock()
	defer rc.logMu.Unlock()
	f, err := os.OpenFile(filepath.Join(dir, "retro-backup.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		jsonError(w, http.StatusInternalServerError, err.Error())
		return
	}
	n, err := io.Copy(f, r.Body)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		jsonError(w, http.StatusInternalServerError, err.Error())
		return
	}
	logf("log from %s: %d bytes appended to BACKUP/%s/retro-backup.log", sanitizeName(m), n, sanitizeName(m))
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// uploadResult is the /upload response. The first six fields are the
// contract; the others are additions a client may ignore.
type uploadResult struct {
	Received   int         `json:"received"`
	Bytes      int64       `json:"bytes"`
	Verified   int         `json:"verified"`
	Mismatched []string    `json:"mismatched"`
	Renamed    [][2]string `json:"renamed"`
	Kept       int         `json:"kept"`
	Missing    []string    `json:"missing"`
	Unlisted   int         `json:"unlisted"`
	Rejected   []string    `json:"rejected"`
	Errors     []string    `json:"errors"`
	Manifest   bool        `json:"manifest"`
	BodyBytes  int64       `json:"body_bytes"`
	Machine    string      `json:"machine"`
	Volume     string      `json:"volume"`
	Group      string      `json:"group"`
	Error      string      `json:"error,omitempty"`
}

func newUploadResult() *uploadResult {
	return &uploadResult{Mismatched: []string{}, Renamed: [][2]string{}, Missing: []string{}, Rejected: []string{}, Errors: []string{}}
}

type countingReader struct {
	r io.Reader
	n int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += int64(n)
	return n, err
}

// trackedReader remembers a read error so that a broken stream can be told
// apart from a failing disk.
type trackedReader struct {
	r   io.Reader
	err error
}

func (t *trackedReader) Read(p []byte) (int, error) {
	n, err := t.r.Read(p)
	if err != nil && err != io.EOF {
		t.err = err
	}
	return n, err
}

type streamError struct{ err error }

func (e streamError) Error() string { return "reading upload stream: " + e.err.Error() }

type diskFullError struct{ err error }

func (e diskFullError) Error() string { return "destination full: " + e.err.Error() }

func isDiskFull(err error) bool {
	if errors.Is(err, syscall.ENOSPC) {
		return true
	}
	var errno syscall.Errno
	if runtime.GOOS == "windows" && errors.As(err, &errno) {
		return errno == 112 || errno == 39 // ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL
	}
	return false
}

func (rc *receiver) acquire(key string) bool {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	if rc.busy[key] {
		return false
	}
	rc.busy[key] = true
	return true
}

func (rc *receiver) release(key string) {
	rc.mu.Lock()
	delete(rc.busy, key)
	rc.mu.Unlock()
}

func (rc *receiver) handleUpload(w http.ResponseWriter, r *http.Request) {
	if !allowMethods(w, r, http.MethodPost, http.MethodPut) {
		return
	}
	start := time.Now()
	body := &countingReader{r: r.Body}
	if r.URL.Query().Get("machine") == "_probe" {
		rc.probe(w, r, body, start)
		return
	}
	om, ov, og, ok := targetNames(r)
	if !ok {
		jsonError(w, http.StatusBadRequest, "machine, volume and group are required")
		return
	}
	res := newUploadResult()
	res.Machine, res.Volume, res.Group = sanitizeName(om), sanitizeName(ov), sanitizeName(og)
	for _, p := range [][3]string{{"machine", om, res.Machine}, {"volume", ov, res.Volume}, {"group", og, res.Group}} {
		if p[1] != p[2] {
			logf("RENAMED %s %s -> %s", p[0], p[1], p[2])
		}
	}
	label := res.Machine + "/" + res.Volume + "/" + res.Group
	if !rc.acquire(label) {
		res.Error = "an upload of this group is already in progress"
		writeJSON(w, http.StatusConflict, res)
		return
	}
	defer rc.release(label)

	u := &upload{
		rc:          rc,
		res:         res,
		label:       label,
		volDir:      rc.volDir(res.Machine, res.Volume),
		received:    map[string]indexEntry{},
		storedOwner: map[string]string{},
		reported:    map[string]bool{},
		start:       start,
	}
	logf("upload %s started from %s", label, clientIP(r))
	err := os.MkdirAll(u.volDir, 0o755)
	if err == nil {
		u.idx, err = loadIndex(indexPath(u.volDir, res.Group))
	}
	if err == nil {
		err = u.run(body)
		u.finish()
	}
	res.BodyBytes = body.n
	status := http.StatusOK
	if err != nil {
		res.Error = err.Error()
		var se streamError
		var df diskFullError
		switch {
		case errors.As(err, &se):
			status = http.StatusBadRequest
		case errors.As(err, &df):
			status = http.StatusInsufficientStorage
		default:
			status = http.StatusInternalServerError
		}
		logf("upload %s FAILED: %v", label, err)
	}
	el := time.Since(start)
	rc.stats.add(res.Machine, func(m *machineStats) {
		m.Uploads++
		m.Files += res.Received
		m.Bytes += res.Bytes
		m.Verified += res.Verified
		m.Mismatched += len(res.Mismatched)
		m.Renamed += len(res.Renamed)
		m.Rejected += len(res.Rejected)
		m.Busy += el
	})
	logf("upload %s done: %d files (%d already present), %s in %s = %.1f MB/s; verified %d, mismatched %d, missing %d, renamed %d, rejected %d, errors %d, manifest %v",
		label, res.Received, res.Kept, humanBytes(uint64(res.Bytes)), el.Round(time.Millisecond), mbps(body.n, el),
		res.Verified, len(res.Mismatched), len(res.Missing), len(res.Renamed), len(res.Rejected), len(res.Errors), res.Manifest)
	writeJSON(w, status, res)
}

// probe accepts the speed-test upload and discards it.
func (rc *receiver) probe(w http.ResponseWriter, r *http.Request, body *countingReader, start time.Time) {
	res := newUploadResult()
	res.Machine, res.Volume, res.Group = "_probe", "_probe", "_probe"
	tr := tar.NewReader(body)
	for {
		if _, err := tr.Next(); err != nil {
			break
		}
		n, err := io.Copy(io.Discard, tr)
		res.Bytes += n
		if err != nil {
			break
		}
		res.Received++
	}
	io.Copy(io.Discard, body) // junk that is not a tar is fine too
	res.BodyBytes = body.n
	el := time.Since(start)
	logf("speed probe from %s: %s in %s = %.1f MB/s (discarded)", clientIP(r), humanBytes(uint64(body.n)), el.Round(time.Millisecond), mbps(body.n, el))
	writeJSON(w, http.StatusOK, res)
}

type dirTime struct {
	path  string
	mtime time.Time
}

type manifestEntry struct {
	Path  string
	Size  int64
	Mtime int64
	MD5   string
}

// upload is the state of one POST /upload.
type upload struct {
	rc          *receiver
	res         *uploadResult
	label       string
	volDir      string
	idx         *groupIndex
	received    map[string]indexEntry // by original path, this upload
	storedOwner map[string]string     // stored path -> original path, this upload
	reported    map[string]bool       // directory prefixes already reported as renamed
	dirTimes    []dirTime
	manifest    []manifestEntry
	start       time.Time
	lastLog     time.Time
}

func (u *upload) rename(orig, stored string) {
	u.res.Renamed = append(u.res.Renamed, [2]string{orig, stored})
	logf("RENAMED %s -> %s (%s)", orig, stored, u.label)
}

func (u *upload) reject(name, why string) {
	u.res.Rejected = append(u.res.Rejected, name)
	logf("REJECTED %q in %s: %s", name, u.label, why)
}

func (u *upload) fail(name string, err error) {
	u.res.Errors = append(u.res.Errors, name+": "+err.Error())
	logf("ERROR %s in %s: %v", name, u.label, err)
}

func (u *upload) run(body io.Reader) error {
	tr := tar.NewReader(body)
	buf := make([]byte, 1<<20)
	u.lastLog = time.Now()
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return streamError{err}
		}
		parts, perr := splitMemberPath(hdr.Name)
		if perr != nil {
			u.reject(hdr.Name, perr.(errUnsafePath).why)
			continue
		}
		if len(parts) == 0 {
			continue
		}
		rel := strings.Join(parts, "/")
		switch hdr.Typeflag {
		case tar.TypeDir:
			u.dir(parts, hdr)
		case tar.TypeReg, '\x00', tar.TypeGNUSparse, tar.TypeCont:
			if rel == manifestMember {
				m, err := parseManifest(tr)
				if err != nil {
					if _, isStream := err.(streamError); isStream {
						return err
					}
					u.fail(manifestMember, err)
				}
				u.manifest = append(u.manifest, m...)
				u.res.Manifest = true
				continue
			}
			if err := u.file(parts, rel, hdr, tr, buf); err != nil {
				var se streamError
				var df diskFullError
				if errors.As(err, &se) || errors.As(err, &df) {
					return err
				}
				u.fail(rel, err)
			}
		case tar.TypeSymlink:
			u.reject(rel, "symlink to "+hdr.Linkname+" not supported")
		case tar.TypeLink:
			u.reject(rel, "hard link to "+hdr.Linkname+" not supported")
		default:
			u.reject(rel, fmt.Sprintf("unsupported tar member type %q", hdr.Typeflag))
		}
		if time.Since(u.lastLog) >= progressEvery {
			u.lastLog = time.Now()
			el := time.Since(u.start)
			logf("upload %s: %d files, %s, %.1f MB/s", u.label, u.res.Received, humanBytes(uint64(u.res.Bytes)), mbps(u.res.Bytes, el))
		}
	}
}

// sanitizedParts maps components and reports renamed directory prefixes;
// for a file the last component is left for the caller to report.
func (u *upload) sanitizedParts(parts []string, isDir bool) []string {
	sp := make([]string, len(parts))
	for i, p := range parts {
		sp[i] = sanitizeComponent(p, u.rc.windows)
	}
	if sp[0] == indexDirName {
		sp[0] = "_" + sp[0][1:] // never write into our own index directory
	}
	dirs := len(parts) - 1
	if isDir {
		dirs = len(parts)
	}
	for i := 0; i < dirs; i++ {
		if parts[i] != sp[i] {
			o := strings.Join(parts[:i+1], "/")
			if !u.reported[o] {
				u.reported[o] = true
				u.rename(o, strings.Join(sp[:i+1], "/"))
			}
		}
	}
	return sp
}

func (u *upload) localPath(stored string) (string, error) {
	p := filepath.Join(u.volDir, filepath.FromSlash(stored))
	rel, err := filepath.Rel(u.volDir, p)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errors.New("path escapes the volume directory")
	}
	return p, nil
}

func (u *upload) dir(parts []string, hdr *tar.Header) {
	sp := u.sanitizedParts(parts, true)
	p, err := u.localPath(strings.Join(sp, "/"))
	if err != nil {
		u.reject(hdr.Name, err.Error())
		return
	}
	if err := os.MkdirAll(p, 0o755); err != nil {
		u.fail(hdr.Name, err)
		return
	}
	u.dirTimes = append(u.dirTimes, dirTime{p, hdr.ModTime})
}

// ownerOf returns the original path already stored under stored, if any.
func (u *upload) ownerOf(stored string) (string, bool) {
	if o, ok := u.storedOwner[stored]; ok {
		return o, true
	}
	o, ok := u.idx.byStored[stored]
	return o, ok
}

func withSuffix(p string, n int) string {
	dir, base := "", p
	if k := strings.LastIndexByte(p, '/'); k >= 0 {
		dir, base = p[:k+1], p[k+1:]
	}
	ext := filepath.Ext(base)
	if ext == base {
		ext = ""
	}
	return fmt.Sprintf("%s%s~%d%s", dir, strings.TrimSuffix(base, ext), n, ext)
}

func (u *upload) file(parts []string, rel string, hdr *tar.Header, tr io.Reader, buf []byte) error {
	sp := u.sanitizedParts(parts, false)
	stored := strings.Join(sp, "/")
	// Two different names that sanitise to the same one get ~2, ~3, ...
	if o, ok := u.ownerOf(stored); ok && o != rel {
		for n := 2; ; n++ {
			c := withSuffix(stored, n)
			if o, ok := u.ownerOf(c); !ok || o == rel {
				stored = c
				break
			}
		}
	}
	if stored != rel {
		if parts[len(parts)-1] != sp[len(sp)-1] || stored != strings.Join(sp, "/") {
			u.rename(rel, stored)
		}
	}
	final, err := u.localPath(stored)
	if err != nil {
		u.reject(rel, err.Error())
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(final), 0o755); err != nil {
		return err
	}
	tmp := final + partSuffix
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		if isDiskFull(err) {
			return diskFullError{err}
		}
		return err
	}
	h := md5.New()
	src := &trackedReader{r: tr}
	n, err := io.CopyBuffer(io.MultiWriter(f, h), src, buf)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	u.res.Bytes += n
	if src.err != nil {
		os.Remove(tmp)
		return streamError{src.err}
	}
	if err != nil {
		os.Remove(tmp)
		if isDiskFull(err) {
			return diskFullError{err}
		}
		return err
	}
	e := indexEntry{Orig: rel, Stored: stored, Size: n, Mtime: hdr.ModTime.Unix(), MD5: hex.EncodeToString(h.Sum(nil))}
	prev, had := u.idx.entries[rel]
	if had && prev.Stored == stored && prev.Size == n && prev.MD5 == e.MD5 && regularWithSize(final, n) {
		os.Remove(tmp) // identical copy from an earlier upload: keep it
		u.res.Kept++
	} else {
		if err := os.Rename(tmp, final); err != nil {
			os.Remove(tmp)
			return err
		}
		if !hdr.ModTime.IsZero() {
			os.Chtimes(final, hdr.ModTime, hdr.ModTime)
		}
	}
	u.received[rel] = e
	u.storedOwner[stored] = rel
	u.res.Received++
	if err := u.idx.record(e); err != nil {
		u.fail(indexDirName, err)
	}
	return nil
}

func regularWithSize(p string, n int64) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular() && fi.Size() == n
}

// parseManifest reads MANIFEST.tsv lines: path \t size \t mtime \t md5.
// Lines whose size is not a number (headers, comments) are skipped.
func parseManifest(r io.Reader) ([]manifestEntry, error) {
	tr := &trackedReader{r: r}
	sc := bufio.NewScanner(tr)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	var out []manifestEntry
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		fs := strings.Split(line, "\t")
		if len(fs) < 4 {
			continue
		}
		k := len(fs) - 3
		size, err1 := strconv.ParseInt(fs[k], 10, 64)
		mtime, err2 := strconv.ParseInt(fs[k+1], 10, 64)
		if err1 != nil || err2 != nil {
			continue
		}
		parts, err := splitMemberPath(strings.Join(fs[:k], "\t"))
		if err != nil || len(parts) == 0 {
			continue
		}
		out = append(out, manifestEntry{Path: strings.Join(parts, "/"), Size: size, Mtime: mtime, MD5: strings.ToLower(fs[k+2])})
	}
	if tr.err != nil {
		return out, streamError{tr.err}
	}
	return out, sc.Err()
}

// finish verifies against the manifest, applies directory mtimes, compacts
// the index and regenerates MANIFEST.tsv.
func (u *upload) finish() {
	if u.res.Manifest {
		u.verify()
	}
	sort.SliceStable(u.dirTimes, func(i, j int) bool { return len(u.dirTimes[i].path) > len(u.dirTimes[j].path) })
	for _, d := range u.dirTimes {
		if !d.mtime.IsZero() {
			os.Chtimes(d.path, d.mtime, d.mtime)
		}
	}
	if err := u.idx.compact(); err != nil {
		u.fail(indexDirName, err)
	}
	if u.res.Manifest {
		if err := u.writeManifests(); err != nil {
			u.fail("MANIFEST.tsv", err)
		}
	}
}

func (u *upload) corrupt(e indexEntry, want manifestEntry) {
	p, err := u.localPath(e.Stored)
	if err == nil {
		err = os.Rename(p, p+corruptSuffix)
	}
	if err != nil {
		u.fail(e.Stored, err)
	}
	u.idx.remove(e.Orig)
	u.res.Mismatched = append(u.res.Mismatched, want.Path)
	logf("MISMATCH %s in %s: got size %d md5 %s, manifest says size %d md5 %s; kept as %s%s",
		want.Path, u.label, e.Size, e.MD5, want.Size, want.MD5, e.Stored, corruptSuffix)
}

func (u *upload) verify() {
	listed := map[string]bool{}
	for _, me := range u.manifest {
		listed[me.Path] = true
		e, ok := u.received[me.Path]
		if !ok {
			// Not sent this time: a file kept from an earlier upload?
			ie, had := u.idx.entries[me.Path]
			if !had {
				u.res.Missing = append(u.res.Missing, me.Path)
				continue
			}
			p, err := u.localPath(ie.Stored)
			if err != nil || !regularWithSize(p, ie.Size) {
				u.idx.remove(me.Path)
				u.res.Missing = append(u.res.Missing, me.Path)
				continue
			}
			e = ie
			u.res.Kept++
		}
		if e.Size == me.Size && e.MD5 == me.MD5 {
			u.res.Verified++
		} else {
			u.corrupt(e, me)
		}
	}
	for p := range u.received {
		if !listed[p] {
			u.res.Unlisted++
		}
	}
}

// writeManifests stores the group's manifest (paths as stored on disk) next
// to its index and rebuilds BACKUP/M/V/MANIFEST.tsv as the concatenation of
// all group manifests of the volume, so repeated uploads never duplicate
// lines.
func (u *upload) writeManifests() error {
	var b strings.Builder
	for _, me := range u.manifest {
		stored := ""
		if e, ok := u.received[me.Path]; ok {
			stored = e.Stored
		} else if e, ok := u.idx.entries[me.Path]; ok {
			stored = e.Stored
		} else {
			parts, _ := splitMemberPath(me.Path)
			sp := make([]string, len(parts))
			for i, p := range parts {
				sp[i] = sanitizeComponent(p, u.rc.windows)
			}
			stored = strings.Join(sp, "/")
		}
		fmt.Fprintf(&b, "%s\t%d\t%d\t%s\n", stored, me.Size, me.Mtime, me.MD5)
	}
	idir := filepath.Join(u.volDir, indexDirName)
	if err := writeFileAtomic(filepath.Join(idir, u.res.Group+".manifest.tsv"), []byte(b.String())); err != nil {
		return err
	}
	u.rc.manifestMu.Lock()
	defer u.rc.manifestMu.Unlock()
	parts, err := filepath.Glob(filepath.Join(idir, "*.manifest.tsv"))
	if err != nil {
		return err
	}
	sort.Strings(parts)
	tmp := filepath.Join(u.volDir, "MANIFEST.tsv.tmp")
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	for _, p := range parts {
		in, err := os.Open(p)
		if err != nil {
			out.Close()
			return err
		}
		_, err = io.Copy(out, in)
		in.Close()
		if err != nil {
			out.Close()
			return err
		}
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(u.volDir, "MANIFEST.tsv"))
}

func writeFileAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
