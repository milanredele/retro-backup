package main

import (
	"strings"
	"testing"
)

func TestSanitizeComponent(t *testing.T) {
	cases := []struct {
		in, want string
		windows  bool
	}{
		{"Fotók 2007", "Fotók 2007", false},
		{"Jóska", "Jóska", false},
		{"report: final?.txt", "report_ final_.txt", false},
		{`a\b`, "a_b", false},
		{`*?"<>|:`, "_______", false},
		{"tab\there", "tab_here", false},
		{"nl\nx\x7f", "nl_x_", false},
		{"trailing.", "trailing_", false},
		{"trailing ", "trailing_", false},
		{"dots. .", "dots___", false},
		{"...", "___", false},
		{".hidden", ".hidden", false},
		{" leading space", " leading space", false},
		{"ok.txt", "ok.txt", false},
		{"bad\xffutf8", "bad_utf8", false},
		{"日本語.doc", "日本語.doc", false},
		{"CON", "CON", false},
		{"CON", "CON_", true},
		{"con.txt", "con_.txt", true},
		{"LPT1.doc", "LPT1_.doc", true},
		{"COM0", "COM0", true},
		{"CONSOLE", "CONSOLE", true},
		{"nul", "nul_", true},
	}
	for _, c := range cases {
		if got := sanitizeComponent(c.in, c.windows); got != c.want {
			t.Errorf("sanitizeComponent(%q, %v) = %q, want %q", c.in, c.windows, got, c.want)
		}
	}
}

func TestSanitizeName(t *testing.T) {
	cases := []struct{ in, want string }{
		{"JOSKA-PC", "JOSKA-PC"},
		{"Jóska PC", "J_ska_PC"},
		{"sda1", "sda1"},
		{"SYSTEM_20070615-1030", "SYSTEM_20070615-1030"},
		{"a/b\\c", "a_b_c"},
		{"..", "_"},
		{".", "_"},
		{"", "_"},
		{"_probe", "_probe"},
		{strings.Repeat("x", 50), strings.Repeat("x", 40)},
		{"D:", "D_"},
	}
	for _, c := range cases {
		if got := sanitizeName(c.in); got != c.want {
			t.Errorf("sanitizeName(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSplitMemberPath(t *testing.T) {
	ok := map[string]string{
		"a/b/c":        "a/b/c",
		"./a//b/./c/":  "a/b/c",
		"Fotók 2007/x": "Fotók 2007/x",
		"..a/b..":      "..a/b..",
		"./":           "",
	}
	for in, want := range ok {
		parts, err := splitMemberPath(in)
		if err != nil || strings.Join(parts, "/") != want {
			t.Errorf("splitMemberPath(%q) = %q, %v", in, parts, err)
		}
	}
	for _, in := range []string{"/etc/passwd", "../x", "a/../../x", "a/.."} {
		if _, err := splitMemberPath(in); err == nil {
			t.Errorf("splitMemberPath(%q) accepted", in)
		}
	}
}

func TestIndexEscaping(t *testing.T) {
	for _, s := range []string{"plain", "tab\there", `back\slash`, "nl\nx", `\t literal`} {
		if got := unescTSV(escTSV(s)); got != s {
			t.Errorf("round trip %q -> %q", s, got)
		}
	}
}
