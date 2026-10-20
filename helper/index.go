package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// The per-group index dest/BACKUP/M/V/.retro-index/<group>.tsv records every
// file of the group that arrived completely, so that /resume needs no
// hashing. It is an append-only log while an upload runs (one line per
// finished file, so a dropped connection loses nothing) and is compacted
// when the upload ends. Line format, tab separated, escaped with escTSV:
//
//	orig_path  stored_path  size  mtime_epoch  md5
//
// orig_path is the member name as the client sent it (that is what /resume
// returns, so the client can match it); stored_path is the sanitised path on
// disk relative to the volume directory. md5 "-" deletes the entry.

const indexDirName = ".retro-index"

type indexEntry struct {
	Orig   string
	Stored string
	Size   int64
	Mtime  int64
	MD5    string
}

type groupIndex struct {
	path     string
	entries  map[string]indexEntry // by Orig
	byStored map[string]string     // Stored -> Orig
	f        *os.File              // open for appending during an upload
}

func escTSV(s string) string {
	if !strings.ContainsAny(s, "\\\t\n\r") {
		return s
	}
	r := strings.NewReplacer("\\", "\\\\", "\t", "\\t", "\n", "\\n", "\r", "\\r")
	return r.Replace(s)
}

func unescTSV(s string) string {
	if !strings.Contains(s, "\\") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			i++
			switch s[i] {
			case 't':
				b.WriteByte('\t')
			case 'n':
				b.WriteByte('\n')
			case 'r':
				b.WriteByte('\r')
			default:
				b.WriteByte(s[i])
			}
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func indexPath(volDir, group string) string {
	return filepath.Join(volDir, indexDirName, group+".tsv")
}

// loadIndex reads an index; a missing file is an empty index.
func loadIndex(path string) (*groupIndex, error) {
	gi := &groupIndex{path: path, entries: map[string]indexEntry{}, byStored: map[string]string{}}
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return gi, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		fs := strings.Split(sc.Text(), "\t")
		if len(fs) != 5 {
			continue // torn last line after a crash
		}
		size, err1 := strconv.ParseInt(fs[2], 10, 64)
		mtime, err2 := strconv.ParseInt(fs[3], 10, 64)
		if err1 != nil || err2 != nil {
			continue
		}
		e := indexEntry{Orig: unescTSV(fs[0]), Stored: unescTSV(fs[1]), Size: size, Mtime: mtime, MD5: fs[4]}
		gi.apply(e)
	}
	return gi, sc.Err()
}

func (gi *groupIndex) apply(e indexEntry) {
	if old, ok := gi.entries[e.Orig]; ok {
		delete(gi.byStored, old.Stored)
	}
	if e.MD5 == "-" {
		delete(gi.entries, e.Orig)
		return
	}
	gi.entries[e.Orig] = e
	gi.byStored[e.Stored] = e.Orig
}

func formatIndexLine(e indexEntry) string {
	return fmt.Sprintf("%s\t%s\t%d\t%d\t%s\n", escTSV(e.Orig), escTSV(e.Stored), e.Size, e.Mtime, e.MD5)
}

// record updates the index in memory and appends the change to disk.
func (gi *groupIndex) record(e indexEntry) error {
	gi.apply(e)
	if gi.f == nil {
		if err := os.MkdirAll(filepath.Dir(gi.path), 0o755); err != nil {
			return err
		}
		f, err := os.OpenFile(gi.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return err
		}
		gi.f = f
	}
	_, err := gi.f.WriteString(formatIndexLine(e))
	return err
}

func (gi *groupIndex) remove(orig string) error {
	e, ok := gi.entries[orig]
	if !ok {
		return nil
	}
	e.MD5 = "-"
	return gi.record(e)
}

func (gi *groupIndex) sorted() []indexEntry {
	out := make([]indexEntry, 0, len(gi.entries))
	for _, e := range gi.entries {
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Orig < out[j].Orig })
	return out
}

// compact closes the append handle and rewrites the index atomically.
func (gi *groupIndex) compact() error {
	if gi.f != nil {
		gi.f.Close()
		gi.f = nil
	}
	if len(gi.entries) == 0 {
		if _, err := os.Stat(gi.path); os.IsNotExist(err) {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(gi.path), 0o755); err != nil {
		return err
	}
	tmp := gi.path + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	for _, e := range gi.sorted() {
		w.WriteString(formatIndexLine(e))
	}
	if err := w.Flush(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, gi.path)
}
