# Shared awk functions for the scanner and the copy stage (gawk, run with LC_ALL=C).

# load_categories(file): fills CAT[ext] = category and CATS[1..NCATS] (config order).
function load_categories(file,    line, n, w, i, c, saved_rs) {
	saved_rs = RS; RS = "\n"
	while ((getline line < file) > 0) {
		sub(/#.*/, "", line)
		n = split(line, w, /[ \t]+/)
		c = ""
		for (i = 1; i <= n; i++) {
			if (w[i] == "") continue
			if (c == "") {
				c = w[i]
				if (!(c in CATSEEN)) { CATSEEN[c] = 1; CATS[++NCATS] = c }
			} else if (!(tolower(w[i]) in CAT)) CAT[tolower(w[i])] = c
		}
	}
	close(file)
	RS = saved_rs
}

# file_category(path): category of a file by extension, "" when unmatched.
function file_category(p,    b, e) {
	b = p
	sub(/^.*\//, "", b)
	if (!match(b, /\.[^.]+$/) || RSTART == 1) return ""
	e = tolower(substr(b, RSTART + 1))
	return (e in CAT) ? CAT[e] : ""
}

# parent(path): the parent directory, "" for top-level names.
function parent(p,    i) {
	i = match(p, /\/[^\/]*$/)
	return i ? substr(p, 1, i - 1) : ""
}

# visible(path): path with tabs and newlines made visible, for log lines.
function visible(p) {
	gsub(/\t/, "\\t", p)
	gsub(/\n/, "\\n", p)
	gsub(/\r/, "\\r", p)
	return p
}
