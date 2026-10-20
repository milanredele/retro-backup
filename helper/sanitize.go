package main

import (
	"strings"
	"unicode/utf8"
)

// Name sanitising, CONTRACTS.md section 3.
//
// machine, volume and group: only [A-Za-z0-9._-], everything else becomes
// '_', at most 40 characters; "", "." and ".." become "_" so that a name can
// never address a parent directory.
//
// Path components: UTF-8 is passed through; the characters illegal on
// exFAT/NTFS (\ / : * ? " < > |), control characters (0x00-0x1f, 0x7f) and
// a trailing run of dots or spaces are replaced by '_' (each character of the
// trailing run, so "a. ." becomes "a___"). Invalid UTF-8 bytes also become
// '_' (APFS and NTFS cannot store them). Windows reserved device names (CON,
// PRN, AUX, NUL, COM1-9, LPT1-9, with or without extension) get a '_'
// appended to the stem when the helper runs on Windows only, because there
// they cannot be created; on other hosts they are legal and kept.

const maxNameLen = 40

// sanitizeName cleans a machine, volume or group name.
func sanitizeName(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '.', c == '_', c == '-':
			b.WriteByte(c)
		default:
			// A multi-byte UTF-8 rune becomes a single '_'.
			if c >= 0x80 {
				_, size := utf8.DecodeRuneInString(s[i:])
				i += size - 1
			}
			b.WriteByte('_')
		}
	}
	out := b.String()
	if len(out) > maxNameLen {
		out = out[:maxNameLen]
	}
	if out == "" || out == "." || out == ".." {
		out = "_"
	}
	return out
}

func illegalPathChar(r rune) bool {
	switch r {
	case '\\', '/', ':', '*', '?', '"', '<', '>', '|':
		return true
	}
	return r < 0x20 || r == 0x7f
}

// sanitizeComponent cleans one path component. windows enables the
// reserved-device-name rule.
func sanitizeComponent(s string, windows bool) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if (r == utf8.RuneError && size <= 1) || illegalPathChar(r) {
			b.WriteByte('_')
		} else {
			b.WriteString(s[i : i+size])
		}
		i += size
	}
	out := []byte(b.String())
	for j := len(out) - 1; j >= 0 && (out[j] == '.' || out[j] == ' '); j-- {
		out[j] = '_'
	}
	res := string(out)
	if windows && isWindowsReserved(res) {
		if k := strings.IndexByte(res, '.'); k >= 0 {
			res = res[:k] + "_" + res[k:]
		} else {
			res += "_"
		}
	}
	return res
}

func isWindowsReserved(s string) bool {
	stem := s
	if k := strings.IndexByte(stem, '.'); k >= 0 {
		stem = stem[:k]
	}
	stem = strings.ToUpper(strings.TrimRight(stem, " "))
	switch stem {
	case "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$":
		return true
	}
	if len(stem) == 4 && (strings.HasPrefix(stem, "COM") || strings.HasPrefix(stem, "LPT")) {
		c := stem[3]
		return c >= '1' && c <= '9'
	}
	return false
}

// errUnsafePath is returned for absolute member names and names containing a
// ".." component.
type errUnsafePath struct{ name, why string }

func (e errUnsafePath) Error() string { return e.why + ": " + e.name }

// splitMemberPath validates a tar member name (relative to the volume) and
// returns its components with "", "." and a leading "./" removed. A name
// that is empty after cleaning returns no components and no error.
func splitMemberPath(name string) ([]string, error) {
	if strings.HasPrefix(name, "/") {
		return nil, errUnsafePath{name, "absolute path"}
	}
	var parts []string
	for _, p := range strings.Split(name, "/") {
		switch p {
		case "", ".":
			continue
		case "..":
			return nil, errUnsafePath{name, "path traversal"}
		}
		parts = append(parts, p)
	}
	return parts, nil
}
