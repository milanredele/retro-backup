# json.awk: flatten a JSON document into "key.path<TAB>value" lines (gawk, LC_ALL=C).
# Arrays use 0-based indexes: {"files":[{"path":"a"}]} gives "files.0.path<TAB>a".
# Strings are decoded (\uXXXX and surrogate pairs become UTF-8); tabs, CR and LF inside
# values become spaces. Only what the helper API needs; no validation beyond that.
BEGIN { RS = "^$"; hex = "0123456789abcdef" }
function utf8(c) {
	if (c < 128) return sprintf("%c", c)
	if (c < 2048) return sprintf("%c%c", 192 + int(c / 64), 128 + c % 64)
	if (c < 65536) return sprintf("%c%c%c", 224 + int(c / 4096), 128 + int(c / 64) % 64, 128 + c % 64)
	return sprintf("%c%c%c%c", 240 + int(c / 262144), 128 + int(c / 4096) % 64, 128 + int(c / 64) % 64, 128 + c % 64)
}
function hexval(s,    i, v) {
	v = 0; s = tolower(s)
	for (i = 1; i <= length(s); i++) v = v * 16 + index(hex, substr(s, i, 1)) - 1
	return v
}
function skipws() { while (pos <= n && index(" \t\r\n", substr(doc, pos, 1))) pos++ }
function str(    out, ch, c, lo) {
	out = ""; pos++
	while (pos <= n) {
		ch = substr(doc, pos, 1)
		if (ch == "\"") { pos++; break }
		if (ch == "\\") {
			ch = substr(doc, pos + 1, 1); pos += 2
			if (ch == "n" || ch == "t" || ch == "r") out = out " "
			else if (ch == "b" || ch == "f") out = out " "
			else if (ch == "u") {
				c = hexval(substr(doc, pos, 4)); pos += 4
				if (c >= 55296 && c < 56320 && substr(doc, pos, 2) == "\\u") {
					lo = hexval(substr(doc, pos + 2, 4)); pos += 6
					c = 65536 + (c - 55296) * 1024 + (lo - 56320)
				}
				out = out utf8(c)
			} else out = out ch
			continue
		}
		if (ch == "\t" || ch == "\n" || ch == "\r") ch = " "
		out = out ch; pos++
	}
	return out
}
function value(path,    ch, k, i, v) {
	skipws(); ch = substr(doc, pos, 1)
	if (ch == "{") {
		pos++; skipws()
		if (substr(doc, pos, 1) == "}") { pos++; return }
		while (pos <= n) {
			skipws(); k = str(); skipws()
			if (substr(doc, pos, 1) == ":") pos++
			value(path == "" ? k : path "." k)
			skipws(); ch = substr(doc, pos, 1); pos++
			if (ch != ",") return
		}
		return
	}
	if (ch == "[") {
		pos++; skipws(); i = 0
		if (substr(doc, pos, 1) == "]") { pos++; return }
		while (pos <= n) {
			value(path "." i); i++
			skipws(); ch = substr(doc, pos, 1); pos++
			if (ch != ",") return
		}
		return
	}
	if (ch == "\"") { v = str(); printf "%s\t%s\n", path, v; return }
	v = ""
	while (pos <= n && !index(",]} \t\r\n", substr(doc, pos, 1))) { v = v substr(doc, pos, 1); pos++ }
	printf "%s\t%s\n", path, v
}
{ doc = $0 }
END { n = length(doc); pos = 1; if (n) value("") }
