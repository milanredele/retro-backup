# Pass B (sweep) aggregation. Input: records "size<space>path-relative-to-volume" separated by
# NUL. Memory is two array elements per directory, never per file (gawk spends ~150 bytes
# per element, so every array counts): ID[path] = integer id, and R[id] = "parent files
# bytes matched direct c1 ... cN": parent id, recursive totals of files, bytes and files
# with a known category, matched files directly in the directory, and cK = files of
# category K. Consecutive files of one directory are summed first, then added to it and
# all its ancestors. (1 million files in 55 000 directories: about 17 MB.)
# Variables: dev, catfile, blkfile (pass A paths, one per line), skipfile, loosefile,
# progfile, used (bytes used on the volume, for the progress estimate), letter (Windows drive
# letter guess or ""), volname, maxgroups (default 200).
# Output: dev B category - label path files bytes 0
#
# Grouping rule (PLAN.md 6.1, folding): directories are visited from the top. A directory
# becomes a group when it is "hot": at least half of its files (recursively) have a known
# category, and either one category has >= 90 % of those files (its subfolders are folded
# into it) or it holds such files itself (a mixed folder, labelled with its majority
# category). Otherwise the walk descends into its subfolders. The volume root and every
# ancestor of a pass A path are never groups (that would overlap pass A); matching files that
# sit directly in such a directory are logged as "loose" and not offered.
# When a volume yields more than maxgroups groups, directories holding two or more groups
# are merged into one (repeatedly, from the deepest level up) until the list is short enough.
BEGIN {
	load_categories(catfile)
	for (i = 1; i <= NCATS; i++) CI[CATS[i]] = i
	ZERO = "0 0 0 0"
	for (i = 1; i <= NCATS; i++) ZERO = ZERO " 0"
	NID = 1; ID[""] = 1; R[1] = "0 " ZERO
	RS = "\n"
	BLK[1] = 1
	while ((getline line < blkfile) > 0) {
		k = getid(line)
		while (k) { BLK[k] = 1; k = par(k) }
	}
	close(blkfile)
	RS = "\0"
	nfiles = 0; nbytes = 0
	if (used <= 0) used = 1
	if (maxgroups <= 0) maxgroups = 200
	cur = SUBSEP
}
# Record fields: f[1] parent, f[2] files, f[3] bytes, f[4] matched, f[5] direct, f[5+K].
function par(k,    f) { split(R[k], f, " "); return f[1] + 0 }
# getid(path): the id of a directory, created with its ancestors on first use.
function getid(p,    k, pk) {
	if (p in ID) return ID[p]
	pk = getid(parent(p))
	k = ++NID
	ID[p] = k
	R[k] = pk " " ZERO
	return k
}
function pack(f,    s, i) {
	s = sprintf("%d %d %.0f %d %d", f[1], f[2], f[3], f[4], f[5])
	for (i = 1; i <= NCATS; i++) s = s " " f[5 + i]
	return s
}
# flush(): add the pending run of files of directory cur to it and its ancestors.
function flush(    k, f, i, first) {
	if (cur == SUBSEP) return
	k = getid(cur)
	first = 1
	while (k) {
		split(R[k], f, " ")
		f[2] += pn; f[3] += pb; f[4] += pm
		if (first) { f[5] += pm; first = 0 }
		for (i = 1; i <= NCATS; i++) f[5 + i] += pc[i]
		R[k] = pack(f)
		k = f[1] + 0
	}
	cur = SUBSEP
}
{
	sp = index($0, " ")
	size = substr($0, 1, sp - 1) + 0
	p = substr($0, sp + 1)
	if (p ~ /[\t\n\r]/) {
		print visible(p) > skipfile
		next
	}
	d = parent(p)
	if (d != cur) {
		flush()
		cur = d; pn = 0; pb = 0; pm = 0
		for (i = 1; i <= NCATS; i++) pc[i] = 0
	}
	c = file_category(p)
	pn++
	pb += size
	if (c != "") { pm++; pc[CI[c]]++ }
	nfiles++
	nbytes += size
	if (nfiles % 5000 == 0) {
		pct = 30 + int(65 * nbytes / used)
		if (pct > 95) pct = 95
		printf "%s\t%d\n", dev, pct >> progfile
		fflush(progfile)
	}
}
# top(k): majority category of directory k (sets TOPN to its file count).
function top(k,    f, i, t) {
	split(R[k], f, " ")
	t = ""; TOPN = 0
	for (i = 1; i <= NCATS; i++) if (f[5 + i] > TOPN) { TOPN = f[5 + i]; t = CATS[i] }
	return t
}
# share(k): at least half of the directory's files have a known category.
function share(k,    f) {
	split(R[k], f, " ")
	return f[4] > 0 && f[4] >= 0.5 * f[2]
}
# state(k): G group candidate, D descend, S nothing below. Memoised in ST.
function state(k,    f) {
	if (k in ST) return ST[k]
	if (k in BLK) return ST[k] = "D"
	split(R[k], f, " ")
	if (f[4] == 0) return ST[k] = "S"
	top(k)
	if (share(k) && TOPN >= 0.9 * f[4]) return ST[k] = "G"
	if (share(k) && f[5] > 0) return ST[k] = "G"
	return ST[k] = "D"
}
function free_path(k,    a) {
	for (a = par(k); a > 1; a = par(a)) if (state(a) != "D") return 0
	return 1
}
# emitted(): fills EM[id] = 1 for the current groups; returns their number.
function emitted(    k, n) {
	delete EM
	n = 0
	for (k = 2; k <= NID; k++) {
		if (state(k) != "G" || !free_path(k)) continue
		EM[k] = 1
		n++
	}
	return n
}
function depth(k,    n) { for (n = 0; k > 1; k = par(k)) n++; return n }
END {
	flush()
	n = emitted()
	# Too many groups: merge directories that hold two or more of them, deepest first.
	while (n > maxgroups) {
		delete CNT
		maxd = 0
		for (k in EM) for (a = par(k); a > 1; a = par(a)) CNT[a]++
		for (a in CNT) if (CNT[a] >= 2 && !(a in BLK) && share(a) && depth(a) > maxd) maxd = depth(a)
		if (maxd == 0) break
		for (a in CNT) if (CNT[a] >= 2 && !(a in BLK) && share(a) && depth(a) == maxd) ST[a] = "G"
		n = emitted()
	}
	for (d in ID) {
		k = ID[d]
		split(R[k], f, " ")
		if (k in EM) {
			if (letter != "") {
				lab = d
				gsub(/\//, "\\", lab)
				lab = letter ":\\" lab
			} else lab = volname ":/" d
			printf "%s\tB\t%s\t-\t%s\t%s\t%d\t%.0f\t0\n", dev, top(k), lab, d, f[2], f[3]
		}
		if (f[5] > 0 && state(k) == "D" && free_path(k))
			printf "%d\t%s\n", f[5], visible(d == "" ? "/" : d) > loosefile
	}
}
