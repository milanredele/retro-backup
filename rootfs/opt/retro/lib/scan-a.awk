# Pass A counting. Input: records "size<space>absolute-path" separated by NUL (find -printf).
# Variables: mnt, dev, catfile, grpfile (path \t category \t preselect \t user \t label),
# skipfile. Output: dev A category user label path files bytes preselect.
BEGIN {
	load_categories(catfile)
	RS = "\n"
	while ((getline line < grpfile) > 0) {
		split(line, f, "\t")
		G[f[1]] = line
	}
	close(grpfile)
	RS = "\0"
	pre = mnt "/"
	plen = length(pre)
}
{
	sp = index($0, " ")
	size = substr($0, 1, sp - 1) + 0
	p = substr($0, sp + 1)
	if (substr(p, 1, plen) == pre) p = substr(p, plen + 1)
	if (p ~ /[\t\n\r]/) {
		print visible(p) > skipfile
		next
	}
	c = file_category(p)
	q = p
	while (q != "") {
		if (q in G) {
			F[q]++
			S[q] += size
			if (c != "") CC[q, c]++
		}
		q = parent(q)
	}
}
END {
	for (g in G) {
		if (!(g in F)) continue
		split(G[g], f, "\t")
		cat = f[2]
		if (cat == "auto") {
			cat = "other"; best = 0
			for (i = 1; i <= NCATS; i++)
				if (CC[g, CATS[i]] > best) { best = CC[g, CATS[i]]; cat = CATS[i] }
		}
		printf "%s\tA\t%s\t%s\t%s\t%s\t%d\t%.0f\t%s\n", dev, cat, f[4], f[5], g, F[g], S[g], f[3]
	}
}
