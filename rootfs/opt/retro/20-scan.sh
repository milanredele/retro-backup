#!/bin/sh
# 20-scan.sh: find user data on every mounted source volume and write scan.tsv
# (CONTRACTS.md section 2). Pass A walks the known profile and mail-store locations
# (lib/locations.conf); pass B sweeps the rest of the volume by extension
# (lib/categories.conf) with pruning (lib/excludes.conf) and per-directory folding.
# Progress lines "<dev>\t<percent>" go to $RETRO_RUN/scan.progress; the last line is
# "ALL\t100" when the scan is complete.
# shellcheck source=lib/common.sh
. "${RETRO_HOME:-/opt/retro}/lib/common.sh"

SCAN_TMP=$RETRO_RUN/scan.tmp
SCAN_PROGRESS=$RETRO_RUN/scan.progress

# ci_resolve BASE PATTERN TYPE: paths relative to BASE matching PATTERN component by
# component, ignoring case; '*' matches one component. Intermediate components must be real
# directories (symlinks and junctions are not followed); the last one must be of find -type
# TYPE (d or f). Names with tabs or newlines never match. One path per line, sorted.
ci_resolve() {
	_cr_base=$1
	_cr_rest=$2
	printf '\n' >"$SCAN_TMP/res.cur"
	while [ -n "$_cr_rest" ]; do
		case $_cr_rest in
		*/*)
			_cr_comp=${_cr_rest%%/*}
			_cr_rest=${_cr_rest#*/}
			_cr_t=d
			;;
		*)
			_cr_comp=$_cr_rest
			_cr_rest=
			_cr_t=$3
			;;
		esac
		: >"$SCAN_TMP/res.next"
		while IFS= read -r _cr_p; do
			find "$_cr_base${_cr_p:+/$_cr_p}/" -mindepth 1 -maxdepth 1 -type "$_cr_t" \
				-iname "$_cr_comp" ! -name "*$NL*" ! -name "*$TAB*" -printf '%f\n' 2>/dev/null |
				LC_ALL=C sort | CR_P=$_cr_p awk '{ p = ENVIRON["CR_P"]; print (p == "" ? "" : p "/") $0 }' \
				>>"$SCAN_TMP/res.next"
		done <"$SCAN_TMP/res.cur"
		mv -f "$SCAN_TMP/res.next" "$SCAN_TMP/res.cur"
	done
	grep -v '^$' "$SCAN_TMP/res.cur"
	return 0
}

# add_group PATH CATEGORY PRESELECT USER LABEL: record a pass A candidate.
add_group() {
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(tsv_clean "$4")" "$(tsv_clean "$5")" \
		>>"$SCAN_TMP/a.cand"
}

# add_rule_matches MNT BASE KIND CATEGORY PRESELECT PATTERN LABEL USER LABELPREFIX
# BASE is relative to MNT ("" = volume root).
add_rule_matches() {
	_am_mnt=$1 _am_base=$2 _am_kind=$3 _am_cat=$4 _am_pre=$5 _am_pat=$6 _am_label=$7
	_am_user=$8 _am_prefix=$9
	_am_abs=$_am_mnt${_am_base:+/$_am_base}
	case $_am_kind in
	dir | file)
		if [ "$_am_pat" = . ]; then
			printf '\n' >"$SCAN_TMP/matches"
		else
			_am_t=d
			[ "$_am_kind" = file ] && _am_t=f
			ci_resolve "$_am_abs" "$_am_pat" "$_am_t" >"$SCAN_TMP/matches"
		fi
		;;
	find)
		eval "set -- $(prunes "$_am_mnt" "$OS_HINT" a)"
		find "$_am_abs/" -xdev "$@" -type f -iname "$_am_pat" ! -name "*$NL*" \
			! -name "*$TAB*" -printf '%P\n' 2>/dev/null | LC_ALL=C sort >"$SCAN_TMP/matches"
		;;
	*) return 0 ;;
	esac
	_am_n=0
	_am_total=$(grep -c '' "$SCAN_TMP/matches")
	while IFS= read -r _am_m; do
		_am_n=$((_am_n + 1))
		if [ -z "$_am_m" ]; then _am_path=$_am_base; else _am_path=${_am_base:+$_am_base/}$_am_m; fi
		[ -n "$_am_path" ] || continue
		_am_b=${_am_path##*/}
		case $_am_label in
		*%b*) _am_l=${_am_label%%"%b"*}$_am_b${_am_label#*"%b"} ;;
		*)
			_am_l=$_am_label
			[ "$_am_total" -gt 1 ] && [ "$_am_n" -gt 1 ] && _am_l="$_am_l ($_am_n)"
			;;
		esac
		if [ "$_am_user" = - ]; then
			_am_full=$_am_l
		else
			_am_full="${_am_prefix:+$_am_prefix }$_am_user / $_am_l"
		fi
		add_group "$_am_path" "$_am_cat" "$_am_pre" "$_am_user" "$_am_full"
	done <"$SCAN_TMP/matches"
}

# rules SCOPE: locations.conf lines of SCOPE, as tab separated trimmed fields.
rules() {
	conf_lines "$RETRO_LIB/locations.conf" | awk -F '|' -v s="$1" '{
		for (i = 1; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
		if ($1 != s) next
		printf "%s", $2
		for (i = 3; i <= 7; i++) printf "\t%s", ($i == "" ? "" : $i)
		printf "\n"
	}'
}

# skipped_profile FAMILY NAME: NAME is in the skip list of FAMILY.
skipped_profile() {
	_sp_name=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
	while IFS="$TAB" read -r _sp_match _sp_k _sp_c _sp_p _sp_pat _sp_l; do
		list_has "$_sp_match" "$1" || continue
		_sp_pat=$(printf '%s' "$_sp_pat" | tr '[:upper:]' '[:lower:]')
		# shellcheck disable=SC2254
		case $_sp_name in
		$_sp_pat) return 0 ;;
		esac
	done <"$SCAN_TMP/rules.skip"
	return 1
}

# pass_a MNT DEV: collect and count profile groups. Rows on stdout.
pass_a() {
	_pa_mnt=$1 _pa_dev=$2
	: >"$SCAN_TMP/a.cand"
	: >"$SCAN_TMP/a.roots"
	: >"$SCAN_TMP/a.skipped"
	# Profiles.
	while IFS="$TAB" read -r _pa_match _pa_family _pa_c _pa_p _pa_pat _pa_prefix; do
		list_has "$_pa_match" "$OS_HINT" || continue
		ci_resolve "$_pa_mnt" "$_pa_pat" d >"$SCAN_TMP/profiles"
		while IFS= read -r _pa_prof; do
			_pa_user=${_pa_prof##*/}
			if skipped_profile "$_pa_family" "$_pa_user"; then
				log DEBUG "scan $_pa_dev: not a user profile: $_pa_prof"
				printf '%s\n' "$_pa_prof" >>"$SCAN_TMP/a.skipped"
				continue
			fi
			log INFO "scan $_pa_dev: profile $_pa_prof ($_pa_family)"
			for _pa_scope in bucket whole; do
				while IFS="$TAB" read -r _pr_match _pr_kind _pr_cat _pr_pre _pr_pat _pr_label; do
					list_has "$_pr_match" "$_pa_family" || continue
					add_rule_matches "$_pa_mnt" "$_pa_prof" "$_pr_kind" "$_pr_cat" "$_pr_pre" \
						"$_pr_pat" "$_pr_label" "$_pa_user" "$_pa_prefix"
				done <"$SCAN_TMP/rules.$_pa_scope"
			done
		done <"$SCAN_TMP/profiles"
	done <"$SCAN_TMP/rules.root"
	# Locations outside the profiles.
	while IFS="$TAB" read -r _ps_match _ps_kind _ps_cat _ps_pre _ps_pat _ps_label; do
		list_has "$_ps_match" "$OS_HINT" || continue
		add_rule_matches "$_pa_mnt" "" "$_ps_kind" "$_ps_cat" "$_ps_pre" "$_ps_pat" \
			"$_ps_label" - ""
	done <"$SCAN_TMP/rules.system"
	# First rule wins when two rules name the same path.
	awk -F '\t' '!seen[$1]++' "$SCAN_TMP/a.cand" >"$SCAN_TMP/a.groups"
	[ -s "$SCAN_TMP/a.groups" ] || return 0
	# Outermost paths: the find start points, and what pass B must prune.
	awk -F '\t' '{ P[$1] = 1 } END {
		for (p in P) {
			q = p; top = 1
			while ((i = match(q, /\/[^\/]*$/)) > 0) { q = substr(q, 1, i - 1); if (q in P) { top = 0; break } }
			if (top) print p
		}
	}' "$SCAN_TMP/a.groups" | LC_ALL=C sort >"$SCAN_TMP/a.roots"
	_pa_starts=
	while IFS= read -r _pa_r; do
		_pa_starts="$_pa_starts $(shquote "$_pa_mnt/$_pa_r")"
	done <"$SCAN_TMP/a.roots"
	eval "find $_pa_starts -xdev $(prunes "$_pa_mnt" "$OS_HINT" a) -type f -printf '%s %p\\0'" \
		2>>"$SCAN_TMP/find.err" |
		LC_ALL=C gawk -v mnt="$_pa_mnt" -v dev="$_pa_dev" -v catfile="$RETRO_LIB/categories.conf" \
			-v grpfile="$SCAN_TMP/a.groups" -v skipfile="$SCAN_TMP/skipped" \
			-f "$RETRO_LIB/scan-common.awk" -f "$RETRO_LIB/scan-a.awk"
}

# pass_b MNT DEV LETTER VOLNAME: extension sweep. Rows on stdout.
pass_b() {
	_pb_used=$(df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%.0f", $3 * 1024 }')
	cat "$SCAN_TMP/a.roots" "$SCAN_TMP/a.skipped" >"$SCAN_TMP/b.prune" 2>/dev/null
	eval "find $(shquote "$1/") -xdev $(prunes "$1" "$OS_HINT" b "$SCAN_TMP/b.prune") -type f -printf '%s %P\\0'" \
		2>>"$SCAN_TMP/find.err" |
		LC_ALL=C gawk -v dev="$2" -v letter="$3" -v volname="$4" -v used="${_pb_used:-0}" \
			-v maxgroups="${RETRO_MAX_GROUPS:-200}" \
			-v catfile="$RETRO_LIB/categories.conf" -v blkfile="$SCAN_TMP/a.roots" \
			-v skipfile="$SCAN_TMP/skipped" -v loosefile="$SCAN_TMP/loose" \
			-v progfile="$SCAN_PROGRESS" \
			-f "$RETRO_LIB/scan-common.awk" -f "$RETRO_LIB/scan-b.awk"
}

# drive_letters: "dev<TAB>letter" guesses for Windows file systems: C: for the first
# Windows system volume, then D:, E:, ... in volumes.tsv order.
drive_letters() {
	awk -F '\t' '
		function win(t) { return t ~ /^(ntfs|ntfs3|ntfs-3g|fuseblk|vfat|fat|fat32|msdos|exfat)$/ }
		{ dev[NR] = $1; t[NR] = $2; os[NR] = $6 }
		END {
			sys = 0
			for (i = 1; i <= NR; i++) if (os[i] == "winxp" || os[i] == "win7") { sys = i; break }
			l = (sys ? 4 : 3)
			if (sys) print dev[sys] "\tC"
			for (i = 1; i <= NR; i++) {
				if (i == sys || !win(t[i])) continue
				if (l > 26) break
				printf "%s\t%c\n", dev[i], 64 + l
				l++
			}
		}' "$1"
}

# scan_volume DEV FSTYPE LABEL MNT OS LETTER: both passes for one volume.
scan_volume() {
	_sv_dev=$1 _sv_mnt=$4 _sv_letter=$6
	OS_HINT=$5
	_sv_name=$3
	[ "$_sv_name" = - ] && _sv_name=${_sv_dev##*/}
	if [ ! -d "$_sv_mnt" ]; then
		log WARN "scan $_sv_dev: mountpoint $_sv_mnt missing, skipped"
		return 0
	fi
	log INFO "scan $_sv_dev: pass A (profiles), os_hint=$OS_HINT"
	printf '%s\t%d\n' "$_sv_dev" 2 >>"$SCAN_PROGRESS"
	pass_a "$_sv_mnt" "$_sv_dev" >>"$SCAN_TMP/rows"
	printf '%s\t%d\n' "$_sv_dev" 30 >>"$SCAN_PROGRESS"
	log INFO "scan $_sv_dev: pass B (sweep)"
	: >"$SCAN_TMP/loose"
	pass_b "$_sv_mnt" "$_sv_dev" "$_sv_letter" "$_sv_name" >>"$SCAN_TMP/rows"
	while IFS="$TAB" read -r _sv_n _sv_d; do
		log WARN "scan $_sv_dev: $_sv_n matching files directly in '$_sv_d' are not offered (not a folder group)"
	done <"$SCAN_TMP/loose"
	printf '%s\t%d\n' "$_sv_dev" 100 >>"$SCAN_PROGRESS"
}

scan_main() {
	_vol=${1:-$RETRO_RUN/volumes.tsv}
	_out=${2:-$RETRO_RUN/scan.tsv}
	[ -r "$_vol" ] || die "no volume list: $_vol"
	rm -rf "$SCAN_TMP"
	mkdir -p "$SCAN_TMP" || die "cannot create $SCAN_TMP"
	: >"$SCAN_PROGRESS"
	: >"$SCAN_TMP/rows"
	: >"$SCAN_TMP/skipped"
	: >"$SCAN_TMP/find.err"
	for _s in root skip bucket whole system; do rules "$_s" >"$SCAN_TMP/rules.$_s"; done
	drive_letters "$_vol" >"$SCAN_TMP/letters"
	log INFO "scan: start ($(grep -c '' "$_vol") volumes)"
	while IFS="$TAB" read -r _dev _fs _label _size _mnt _os; do
		[ -n "$_dev" ] || continue
		_letter=$(awk -F '\t' -v d="$_dev" '$1 == d { print $2 }' "$SCAN_TMP/letters")
		scan_volume "$_dev" "$_fs" "$_label" "$_mnt" "${_os:-data}" "$_letter"
	done <"$_vol"
	while IFS= read -r _sk; do
		log WARN "scan: SKIPPED path with a tab or newline in its name: $_sk"
	done <"$SCAN_TMP/skipped"
	if [ -s "$SCAN_TMP/find.err" ]; then
		log WARN "scan: find reported $(grep -c '' "$SCAN_TMP/find.err") errors (first: $(head -n 1 "$SCAN_TMP/find.err"))"
	fi
	# Order: dev, pass A before B, bytes descending, path; then number the groups.
	LC_ALL=C sort -t "$TAB" -k1,1 -k2,2 -k8,8nr -k6,6 "$SCAN_TMP/rows" |
		awk -F '\t' '{ printf "g%04d\t%s\n", NR, $0 }' | write_atomic "$_out"
	log INFO "scan: done, $(grep -c '' "$_out") groups ($(grep -c "${TAB}A$TAB" "$_out") profile, $(grep -c "${TAB}B$TAB" "$_out") sweep)"
	printf 'ALL\t100\n' >>"$SCAN_PROGRESS"
	[ "$RETRO_DEBUG" = 1 ] || rm -rf "$SCAN_TMP"
	return 0
}

# Run only when executed, not when sourced by another script or a test.
case ${0##*/} in
20-scan.sh) scan_main "$@" ;;
esac
