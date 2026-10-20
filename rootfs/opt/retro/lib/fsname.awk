# fsname.awk: destination file name rules (CONTRACTS.md section 3), gawk with LC_ALL=C.
# Characters illegal on exFAT/NTFS (\ : * ? " < > | and control characters) become '_';
# a trailing dot or space becomes '_'. Applied to every path component; '/' separates.
function fs_clean_name(s) {
	gsub(/[\\:*?"<>|\001-\037]/, "_", s)
	if (s ~ /[. ]$/) s = substr(s, 1, length(s) - 1) "_"
	return s
}
function fs_clean_path(p,    n, a, i, out) {
	n = split(p, a, "/")
	out = ""
	for (i = 1; i <= n; i++) out = out (i > 1 ? "/" : "") fs_clean_name(a[i])
	return out
}
