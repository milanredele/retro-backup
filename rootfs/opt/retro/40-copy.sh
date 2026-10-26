#!/bin/sh
# 40-copy.sh: copy the selected groups (selection.txt) to the destination (dest.conf) in the
# layout of CONTRACTS.md section 3, with MANIFEST.tsv (md5 of the source), the session log
# and scan.tsv. usb/disk: rsync (PLAN.md 6.3) plus a cp loop for names that must be renamed;
# net: one tar stream per group POSTed to the helper (section 4), manifest as last member,
# resuming from GET /resume.
# RETRO_GAUGE=1: progress in dialog --gauge protocol on stdout; otherwise plain lines.
# RETRO_DST_ANY=1 (tests only): accept a destination directory that is not a mountpoint.
# Result counters go to $RETRO_RUN/copy.result (key=value).
# shellcheck source=lib/common.sh
. "${RETRO_HOME:-/opt/retro}/lib/common.sh"
# shellcheck source=50-net.sh
. "$RETRO_HOME/50-net.sh"

CP_TMP=$RETRO_RUN/copy.tmp
GAUGE=${RETRO_GAUGE:-0}
TAR=${RETRO_TAR:-tar}
NET_RETRIES=${RETRO_NET_RETRIES:-3}
# Largest member busybox tar can write (ustar size field, 8 GiB - 1).
TAR_MAX=8589934591

C_GROUPS=0 C_FILES=0 C_BYTES=0 C_FAILED=0 C_RENAMED=0 C_SKIPPED=0 C_MISMATCH=0
DONE_BYTES=0 TOTAL_BYTES=0 N_GROUPS=0 I_GROUP=0

# progress PERCENT TEXT
progress() {
	if [ "$GAUGE" = 1 ]; then
		printf 'XXX\n%d\n%s\nXXX\n' "$1" "$2"
	else
		printf '[%3d%%] %s\n' "$1" "$(printf '%s' "$2" | head -n 1)"
	fi
}

# pct DONE: overall percentage.
pct() {
	awk -v d="$1" -v t="$TOTAL_BYTES" 'BEGIN { p = (t > 0) ? int(d * 100 / t) : 0; if (p > 100) p = 100; print p }'
}

# add A B: big-number addition (sizes beyond 2^31 on 32-bit shells).
add() {
	awk -v a="$1" -v b="$2" 'BEGIN { printf "%.0f\n", a + b }'
}

# vol_field DEV N: field N of the volumes.tsv line for DEV.
vol_field() {
	awk -F '\t' -v d="$1" -v n="$2" '$1 == d { print $n; exit }' "$RETRO_RUN/volumes.tsv"
}

# machine_name: <machine> of the destination tree, decided once per session.
# Linux: /etc/hostname of a linux volume. Otherwise <label-or-dev>-<YYYYMMDD-HHMM> of the
# system volume (the first volume with an OS, else the first volume). Reading the Windows
# ComputerName needs a registry hive parser, which is not cheap; not done.
machine_name() {
	if [ -s "$RETRO_RUN/machine" ]; then
		cat "$RETRO_RUN/machine"
		return 0
	fi
	_mn=
	while IFS="$TAB" read -r _d _f _l _s _m _o; do
		if [ "$_o" = linux ] && [ -r "$_m/etc/hostname" ]; then
			_mn=$(sanitize_name "$(head -n 1 "$_m/etc/hostname")" "")
			[ -n "$_mn" ] && break
		fi
	done <"$RETRO_RUN/volumes.tsv"
	if [ -z "$_mn" ]; then
		_sys=$(awk -F '\t' '$6 != "data" { print; exit }' "$RETRO_RUN/volumes.tsv")
		[ -n "$_sys" ] || _sys=$(head -n 1 "$RETRO_RUN/volumes.tsv")
		_l=$(tsv_field "$_sys" 3)
		_d=$(tsv_field "$_sys" 1)
		[ "$_l" = - ] && _l=${_d##*/}
		_mn=$(sanitize_name "$(printf '%s' "$_l" | cut -c1-26)-$(date +%Y%m%d-%H%M)" pc)
	fi
	printf '%s\n' "$_mn" | tee "$RETRO_RUN/machine"
}

# volume_name DEV: <volume>: sanitised label, else device name; "-<dev>" added when two
# volumes would get the same name.
volume_name() {
	_vn_l=$(vol_field "$1" 3)
	[ "$_vn_l" = - ] && _vn_l=${1##*/}
	_vn=$(sanitize_name "$_vn_l" "${1##*/}")
	_dups=0
	while IFS="$TAB" read -r _d _f _l _s _m _o; do
		[ "$_d" = "$1" ] && continue
		[ "$_l" = - ] && _l=${_d##*/}
		[ "$(sanitize_name "$_l" "${_d##*/}")" = "$_vn" ] && _dups=1
	done <"$RETRO_RUN/volumes.tsv"
	[ $_dups = 1 ] && _vn=$(sanitize_name "$_vn-${1##*/}" "${1##*/}")
	printf '%s\n' "$_vn"
}

# clean_path PATH: destination form of a relative path (lib/fsname.awk).
clean_path() {
	printf '%s\n' "$1" | LC_ALL=C gawk -f "$RETRO_LIB/fsname.awk" -e '{ print fs_clean_path($0) }'
}

# build_list MNT PATH OS MODE OUT: the files of a group, "size\tmtime\tsrc\tdst" per line,
# paths relative to the volume. MODE usb: dst follows the exFAT/NTFS name rules, and
# names that would collide on a case-insensitive file system get "~2", "~3"...;
# MODE net: dst = src (the helper applies the same rules). Names with a tab or newline are
# skipped (logged). Uses the same excludes as pass A.
build_list() {
	_bl_mnt=$1 _bl_path=$2 _bl_os=$3 _bl_mode=$4 _bl_out=$5
	: >"$CP_TMP/skipped"
	(cd "$_bl_mnt" && eval "find $(shquote "./$_bl_path") -xdev $(prunes "$_bl_mnt" "$_bl_os" a) \
		-type f -printf '%s\\t%T@\\t%p\\0'") 2>>"$CP_TMP/find.err" |
		LC_ALL=C gawk -v mode="$_bl_mode" -v skipfile="$CP_TMP/skipped" \
			-f "$RETRO_LIB/scan-common.awk" -f "$RETRO_LIB/fsname.awk" -e '
			BEGIN { RS = "\0"; FS = "\t" }
			{
				i1 = index($0, "\t"); rest = substr($0, i1 + 1); i2 = index(rest, "\t")
				size = substr($0, 1, i1 - 1); mt = int(substr(rest, 1, i2 - 1)); p = substr(rest, i2 + 1)
				sub(/^\.\//, "", p)
				if (p ~ /[\t\n\r]/) { print visible(p) > skipfile; next }
				d = (mode == "usb") ? fs_clean_path(p) : p
				printf "%s\t%s\t%d\t%s\t%s\n", tolower(d), size, mt, p, d
			}' |
		LC_ALL=C sort -t "$TAB" -k1,1 |
		LC_ALL=C awk -F '\t' -v mode="$_bl_mode" '
			function suffixed(d, n,    dir, b, e) {
				dir = ""; b = d
				if (match(d, /\/[^\/]*$/)) { dir = substr(d, 1, RSTART); b = substr(d, RSTART + 1) }
				e = ""
				if (match(b, /\.[^.]+$/) && RSTART > 1) { e = substr(b, RSTART); b = substr(b, 1, RSTART - 1) }
				return dir b "~" n e
			}
			{
				if (mode == "usb" && $1 == last) { n++; d = suffixed($5, n) } else { n = 1; d = $5 }
				last = $1
				printf "%s\t%s\t%s\t%s\n", $2, $3, $4, d
			}' >"$_bl_out"
	while IFS= read -r _bl_s; do
		log WARN "copy: SKIPPED path with a tab or newline in its name: $_bl_s"
		C_SKIPPED=$((C_SKIPPED + 1))
	done <"$CP_TMP/skipped"
}

# md5_manifest MNT LIST OUT UNREAD: md5 of every source file of LIST, in LIST order, as
# MANIFEST lines "dst\tsize\tmtime\tmd5"; files md5sum could not read go to UNREAD.
md5_manifest() {
	_mm_mnt=$1 _mm_list=$2
	awk -F '\t' '{ print $3 }' "$_mm_list" | tr '\n' '\0' |
		(cd "$_mm_mnt" && xargs -0 -r md5sum --) 2>>"$CP_TMP/md5.err" |
		LC_ALL=C gawk -v listfile="$_mm_list" -v unread="$4" '
			function unesc(s,    o, i, c) {
				o = ""
				for (i = 1; i <= length(s); i++) {
					c = substr(s, i, 1)
					if (c == "\\") { i++; c = substr(s, i, 1); if (c == "n") c = "\n"; else if (c == "r") c = "\r" }
					o = o c
				}
				return o
			}
			{
				line = $0; esc = 0
				if (substr(line, 1, 1) == "\\") { esc = 1; line = substr(line, 2) }
				h = substr(line, 1, 32); name = substr(line, 35)
				if (esc) name = unesc(name)
				while ((getline row < listfile) > 0) {
					split(row, f, "\t")
					if (f[3] == name) { printf "%s\t%s\t%s\t%s\n", f[4], f[1], f[2], h; break }
					print row > unread
				}
			}
			END { while ((getline row < listfile) > 0) print row > unread }' >"$3"
}

# rsync_progress: turn rsync --info=progress2 output into gauge updates.
rsync_progress() {
	RP_HEAD=$1 LC_ALL=C awk -v done_b="$DONE_BYTES" -v total="$TOTAL_BYTES" -v gauge="$GAUGE" \
		-v errs="$C_FAILED" '
		BEGIN { RS = "[\r\n]+"; last = -1; head = ENVIRON["RP_HEAD"] }
		/^ *[0-9][0-9,]* +[0-9]+%/ {
			b = $1; gsub(/,/, "", b)
			p = (total > 0) ? int((done_b + b) * 100 / total) : 0
			if (p > 100) p = 100
			if (gauge == 1 && (p != last || file != shown)) {
				printf "XXX\n%d\n%s\n%s\n%s: %s\nXXX\n", p, head, substr(file, 1, 70), ENVIRON["T_COPY_ERRORS"], errs
				fflush(); last = p; shown = file
			}
			next
		}
		NF { file = $0 }'
}

# copy_files_cp MNT VD LIST: cp loop (renamed files, or everything when rsync is missing).
copy_files_cp() {
	_cf_mnt=$1 _cf_vd=$2
	while IFS="$TAB" read -r _cf_size _cf_mt _cf_src _cf_dst <&4; do
		_cf_to=$_cf_vd/$_cf_dst
		mkdir -p "${_cf_to%/*}" 2>>"$CP_TMP/cp.err"
		if cp "$_cf_mnt/$_cf_src" "$_cf_to" 2>>"$CP_TMP/cp.err" &&
			touch -r "$_cf_mnt/$_cf_src" "$_cf_to" 2>>"$CP_TMP/cp.err"; then
			if [ "$_cf_src" != "$_cf_dst" ]; then
				log INFO "RENAMED $CUR_VOL/$_cf_src -> $CUR_VOL/$_cf_dst"
				C_RENAMED=$((C_RENAMED + 1))
			fi
		fi
	done 4<"$3"
}

# copy_group_disk ROW: one group to a usb/disk destination.
copy_group_disk() {
	IFS="$TAB" read -r _g _dev _pass _cat _user _label _path _files _bytes _pre <<EOF_ROW
$1
EOF_ROW
	_mnt=$(vol_field "$_dev" 5)
	_os=$(vol_field "$_dev" 6)
	CUR_VOL=$(volume_name "$_dev")
	_vd=$DEST_ROOT/$CUR_VOL
	mkdir -p "$_vd" || { log ERROR "copy: cannot create $_vd"; return 1; }
	_head="$T_COPY_GROUP $I_GROUP/$N_GROUPS: $_label"
	progress "$(pct "$DONE_BYTES")" "$_head"
	log INFO "copy: group $_g ($_label): $_dev:$_path -> $CUR_VOL/"
	build_list "$_mnt" "$_path" "$_os" usb "$CP_TMP/list"
	awk -F '\t' '$3 == $4' "$CP_TMP/list" >"$CP_TMP/list.same"
	awk -F '\t' '$3 != $4' "$CP_TMP/list" >"$CP_TMP/list.renamed"
	: >"$CP_TMP/rsync.err"
	if have rsync && [ -s "$CP_TMP/list.same" ]; then
		awk -F '\t' '{ print $3 }' "$CP_TMP/list.same" | tr '\n' '\0' >"$CP_TMP/list0"
		{
			rsync -t --modify-window=2 --no-perms --no-owner --no-group --partial -8 \
				--ignore-errors --info=progress2 --out-format='%n' --from0 \
				--files-from="$CP_TMP/list0" "$_mnt/" "$_vd/" </dev/null 2>"$CP_TMP/rsync.err"
			echo $? >"$CP_TMP/rsync.rc"
		} | T_COPY_ERRORS=$T_COPY_ERRORS rsync_progress "$_head"
		_rc=$(cat "$CP_TMP/rsync.rc")
		[ "$_rc" = 0 ] || log WARN "copy: rsync exit code $_rc for group $_g: $(head -n 3 "$CP_TMP/rsync.err" | tr '\n' ' ')"
	elif [ -s "$CP_TMP/list.same" ]; then
		copy_files_cp "$_mnt" "$_vd" "$CP_TMP/list.same"
	fi
	copy_files_cp "$_mnt" "$_vd" "$CP_TMP/list.renamed"
	# What is really on the destination now (catches write errors and a full disk).
	_gdst=$(clean_path "$_path")
	awk -F '\t' '{ printf "%s\t%s\n", $4, $1 }' "$CP_TMP/list" | LC_ALL=C sort >"$CP_TMP/expected"
	(cd "$_vd" && find "./$_gdst" -type f -printf '%p\t%s\n' 2>/dev/null) | sed 's|^\./||' |
		LC_ALL=C sort >"$CP_TMP/actual"
	LC_ALL=C comm -23 "$CP_TMP/expected" "$CP_TMP/actual" >"$CP_TMP/missing"
	# Manifest: md5 of the source; files missing on the destination are left out.
	: >"$CP_TMP/unread"
	md5_manifest "$_mnt" "$CP_TMP/list" "$CP_TMP/man.all" "$CP_TMP/unread"
	LC_ALL=C awk -F '\t' 'FILENAME == ARGV[1] { M[$1] = 1; next } !($1 in M)' "$CP_TMP/missing" \
		"$CP_TMP/man.all" >"$CP_TMP/man.ok"
	while IFS="$TAB" read -r _m_dst _m_size; do
		log ERROR "FAILED $CUR_VOL/$_m_dst (not copied: unreadable source or write error)"
	done <"$CP_TMP/missing"
	while IFS="$TAB" read -r _u_size _u_mt _u_src _u_dst; do
		grep -qxF "$_u_dst$TAB$_u_size" "$CP_TMP/missing" ||
			log ERROR "FAILED $CUR_VOL/$_u_src (copied but the source could not be read again for the checksum)"
	done <"$CP_TMP/unread"
	_n_all=$(grep -c '' "$CP_TMP/list")
	_n_ok=$(grep -c '' "$CP_TMP/man.ok")
	_b_ok=$(awk -F '\t' '{ s += $2 } END { printf "%.0f", s }' "$CP_TMP/man.ok")
	merge_manifest "$_vd/MANIFEST.tsv" "$CP_TMP/man.ok"
	C_FILES=$((C_FILES + _n_ok))
	C_FAILED=$((C_FAILED + _n_all - _n_ok))
	C_BYTES=$(add "$C_BYTES" "$_b_ok")
	C_GROUPS=$((C_GROUPS + 1))
	log INFO "copy: group $_g done: $_n_ok of $_n_all files, $(human_bytes "$_b_ok")"
}

# merge_manifest MANIFEST NEW: add NEW lines; for a path listed twice the newest line wins.
merge_manifest() {
	touch "$1"
	LC_ALL=C sort -s -t "$TAB" -k1,1 "$1" "$2" |
		LC_ALL=C awk -F '\t' '$1 != last && NR > 1 { print prev } { prev = $0; last = $1 } END { if (NR) print prev }' \
			>"$1.new" && mv -f "$1.new" "$1"
}

# copy_group_net ROW: one group to the helper as a tar stream.
copy_group_net() {
	IFS="$TAB" read -r _g _dev _pass _cat _user _label _path _files _bytes _pre <<EOF_ROW
$1
EOF_ROW
	_mnt=$(vol_field "$_dev" 5)
	_os=$(vol_field "$_dev" 6)
	CUR_VOL=$(volume_name "$_dev")
	_head="$T_COPY_GROUP $I_GROUP/$N_GROUPS: $_label"
	progress "$(pct "$DONE_BYTES")" "$_head
$T_COPY_CHECKSUMS"
	log INFO "copy: group $_g ($_label): $_dev:$_path -> $NET_URL $MACHINE/$CUR_VOL/"
	build_list "$_mnt" "$_path" "$_os" net "$CP_TMP/list"
	awk -F '\t' -v max="$TAR_MAX" '$1 + 0 > max { print $3 > "/dev/stderr"; next } { print }' \
		"$CP_TMP/list" >"$CP_TMP/list.ok" 2>"$CP_TMP/toobig"
	while IFS= read -r _tb; do
		log ERROR "FAILED $CUR_VOL/$_tb (larger than 8 GiB: busybox tar cannot send it, copy it to a USB disk instead)"
	done <"$CP_TMP/toobig"
	: >"$CP_TMP/unread"
	md5_manifest "$_mnt" "$CP_TMP/list.ok" "$CP_TMP/man.all" "$CP_TMP/unread"
	while IFS="$TAB" read -r _u_size _u_mt _u_src _u_dst; do
		log ERROR "FAILED $CUR_VOL/$_u_src (unreadable source)"
	done <"$CP_TMP/unread"
	_n_all=$(grep -c '' "$CP_TMP/list")
	_try=1
	_ok=0
	while [ "$_try" -le "$NET_RETRIES" ]; do
		net_resume "$NET_URL" "$MACHINE" "$CUR_VOL" "$_g" >"$CP_TMP/resume" || : >"$CP_TMP/resume"
		LC_ALL=C awk -F '\t' 'FILENAME == ARGV[1] { H[$1] = $2 "\t" $3; next } !(($1 in H) && H[$1] == $2 "\t" $4)' \
			"$CP_TMP/resume" "$CP_TMP/man.all" >"$CP_TMP/man.send"
		_n_have=$(($(grep -c '' "$CP_TMP/man.all") - $(grep -c '' "$CP_TMP/man.send")))
		[ "$_n_have" -gt 0 ] && log INFO "copy: group $_g: $_n_have files already on the helper (resume)"
		if [ ! -s "$CP_TMP/man.send" ]; then
			_ok=1
			_resp=
			break
		fi
		_send_b=$(awk -F '\t' '{ s += $2 } END { printf "%.0f", s }' "$CP_TMP/man.send")
		net_send_group "$_mnt" "$_path" "$_g" "$_head" "$_send_b"
		_rc=$?
		if [ $_rc = 0 ] && grep -q '"received"' "$CP_TMP/resp.json"; then
			_ok=1
			_resp=$CP_TMP/resp.json
			break
		fi
		log WARN "copy: upload of group $_g failed (attempt $_try, curl exit $_rc$(head -c 200 "$CP_TMP/curl.err" 2>/dev/null | tr '\n' ' ')), retrying"
		_try=$((_try + 1))
		sleep 3
	done
	C_GROUPS=$((C_GROUPS + 1))
	if [ $_ok != 1 ]; then
		log ERROR "copy: group $_g could not be sent to $NET_URL"
		C_FAILED=$((C_FAILED + _n_all))
		return 1
	fi
	_mis=0
	if [ -n "$_resp" ]; then
		net_json <"$_resp" >"$CP_TMP/resp.tsv"
		_mis=$(awk -F '\t' '$1 ~ /^mismatched\.[0-9]+$/' "$CP_TMP/resp.tsv" | grep -c '')
		awk -F '\t' '$1 ~ /^mismatched\.[0-9]+$/ { print $2 }' "$CP_TMP/resp.tsv" |
			while IFS= read -r _mp; do
				log ERROR "MISMATCH $CUR_VOL/$_mp (md5 differs on the helper, stored as .CORRUPT)"
			done
		awk -F '\t' '$1 ~ /^renamed\.[0-9]+\.0$/ { o = $2 } $1 ~ /^renamed\.[0-9]+\.1$/ { print o "\t" $2 }' \
			"$CP_TMP/resp.tsv" >"$CP_TMP/renamed"
		while IFS="$TAB" read -r _ro _rn; do
			log INFO "RENAMED $CUR_VOL/$_ro -> $CUR_VOL/$_rn"
			C_RENAMED=$((C_RENAMED + 1))
		done <"$CP_TMP/renamed"
		log INFO "copy: group $_g: helper received $(awk -F '\t' '$1 == "received" { print $2 }' "$CP_TMP/resp.tsv") files, verified $(awk -F '\t' '$1 == "verified" { print $2 }' "$CP_TMP/resp.tsv"), mismatched $_mis"
	fi
	_n_ok=$(($(grep -c '' "$CP_TMP/man.all") - _mis))
	_b_ok=$(awk -F '\t' '{ s += $2 } END { printf "%.0f", s }' "$CP_TMP/man.all")
	C_FILES=$((C_FILES + _n_ok))
	C_FAILED=$((C_FAILED + _n_all - _n_ok))
	C_MISMATCH=$((C_MISMATCH + _mis))
	C_BYTES=$(add "$C_BYTES" "$_b_ok")
}

# tar_flags: GNU tar must not interpret the -T list (busybox tar never does).
tar_flags() {
	if "$TAR" --version 2>/dev/null | grep -q GNU; then
		echo "--no-unquote --verbatim-files-from"
	fi
}

# net_send_group MNT PATH GROUP HEAD BYTES: stream man.send's files plus the manifest as one
# tar. The files are reached through a staging directory holding a symlink to the first
# component of PATH, so member names are volume-relative and the manifest (which cannot be
# written to the read-only source) can be the last member of the same archive.
net_send_group() {
	_st=$CP_TMP/stage
	rm -rf "$_st"
	mkdir -p "$_st"
	_top=${2%%/*}
	ln -s "$1/$_top" "$_st/$_top"
	cp "$CP_TMP/man.send" "$_st/.retro-manifest.tsv"
	{
		awk -F '\t' '{ print $1 }' "$CP_TMP/man.send"
		echo .retro-manifest.tsv
	} >"$CP_TMP/tarlist"
	: >"$CP_TMP/pv.out"
	: >"$CP_TMP/curl.err"
	rm -f "$CP_TMP/resp.json" "$CP_TMP/net.rc"
	_url="$NET_URL/upload?machine=$MACHINE&volume=$CUR_VOL&group=$3"
	_meter="cat"
	have pv && _meter="pv -n -b -i 1"
	(
		cd "$_st" || exit 1
		# shellcheck disable=SC2046
		"$TAR" -c -f - $(tar_flags) -T "$CP_TMP/tarlist" 2>>"$CP_TMP/tar.err" |
			$_meter 2>"$CP_TMP/pv.out" |
			curl -sS -X POST -T - -H 'Content-Type: application/x-tar' -H 'Expect:' \
				--speed-limit 1 --speed-time 120 -o "$CP_TMP/resp.json" "$_url" 2>"$CP_TMP/curl.err"
		echo $? >"$CP_TMP/net.rc"
	) &
	_bg=$!
	while kill -0 "$_bg" 2>/dev/null; do
		_sent=$(tail -n 1 "$CP_TMP/pv.out" 2>/dev/null)
		[ -n "$_sent" ] || _sent=0
		if [ "$GAUGE" = 1 ]; then
			progress "$(pct "$(add "$DONE_BYTES" "$_sent")")" "$4
$T_COPY_SENT: $(human_bytes "$_sent") / $(human_bytes "$5")"
		fi
		sleep 1
	done
	wait "$_bg" 2>/dev/null
	rm -rf "$_st"
	return "$(cat "$CP_TMP/net.rc" 2>/dev/null || echo 1)"
}

# finish_disk: session log and scan.tsv onto the destination, sync, unmount.
finish_disk() {
	mkdir -p "$DEST_ROOT"
	cp "$RETRO_RUN/scan.tsv" "$DEST_ROOT/scan.tsv" 2>/dev/null
	write_result
	log INFO "copy: finished: $C_FILES files ($(human_bytes "$C_BYTES")) in $C_GROUPS groups, $C_FAILED failed, $C_RENAMED renamed, $C_SKIPPED skipped"
	append_log_since "$RETRO_RUN/log.sent.disk" "$DEST_ROOT/retro-backup.log"
	sync
	if is_mountpoint "$RETRO_DST" && [ "${RETRO_NO_UMOUNT:-0}" != 1 ]; then
		if umount "$RETRO_DST" 2>>"$CP_TMP/umount.err"; then
			log INFO "copy: $RETRO_DST unmounted, safe to remove"
			echo "unmounted=1" >>"$RETRO_RUN/copy.result"
		else
			log WARN "copy: could not unmount $RETRO_DST: $(tail -n 1 "$CP_TMP/umount.err")"
			echo "unmounted=0" >>"$RETRO_RUN/copy.result"
		fi
	fi
}

# finish_net: session log (with scan.tsv appended: the API has no other place for it).
finish_net() {
	write_result
	log INFO "copy: finished: $C_FILES files ($(human_bytes "$C_BYTES")) in $C_GROUPS groups, $C_FAILED failed, $C_RENAMED renamed, $C_SKIPPED skipped, $C_MISMATCH mismatched"
	_lp=$CP_TMP/log.post
	log_since "$RETRO_RUN/log.sent.net" >"$_lp"
	if [ ! -e "$RETRO_RUN/scan.sent.net" ]; then
		{
			printf '\n===== scan.tsv =====\n'
			cat "$RETRO_RUN/scan.tsv"
			printf '===== end of scan.tsv =====\n'
		} >>"$_lp"
	fi
	if net_post_log "$NET_URL" "$MACHINE" "$_lp"; then
		wc -c <"$RETRO_LOG" | tr -d ' ' >"$RETRO_RUN/log.sent.net"
		touch "$RETRO_RUN/scan.sent.net"
	else
		log WARN "copy: could not send the log to $NET_URL"
	fi
}

# log_since OFFSETFILE: the part of the session log not sent yet.
log_since() {
	_off=$(cat "$1" 2>/dev/null || echo 0)
	tail -c +$((_off + 1)) "$RETRO_LOG" 2>/dev/null
}

# append_log_since OFFSETFILE TARGET: append the new part of the session log to TARGET.
append_log_since() {
	if log_since "$1" >>"$2"; then
		wc -c <"$RETRO_LOG" | tr -d ' ' >"$1"
	fi
}

write_result() {
	{
		echo "groups=$C_GROUPS"
		echo "files=$C_FILES"
		echo "bytes=$C_BYTES"
		echo "failed=$C_FAILED"
		echo "renamed=$C_RENAMED"
		echo "skipped=$C_SKIPPED"
		echo "mismatched=$C_MISMATCH"
		echo "machine=$MACHINE"
		echo "dest=$DEST_DESC"
	} >"$RETRO_RUN/copy.result"
}

# disk_probe DIR [SECONDS]: write throughput of DIR in bytes per second (fsync'd 4 MiB
# chunks for SECONDS, default 10), for the ETA on the confirm screen.
disk_probe() {
	_dp_f=$1/.retro-probe.$$
	_dp_t0=$(uptime_cs)
	_dp_end=$((_dp_t0 + ${2:-10} * 100))
	_dp_n=0
	while [ "$(uptime_cs)" -lt "$_dp_end" ]; do
		dd if=/dev/zero of="$_dp_f" bs=1048576 count=4 seek=$((_dp_n * 4)) conv=notrunc,fsync \
			2>/dev/null || break
		_dp_n=$((_dp_n + 1))
		[ "$_dp_n" -ge 256 ] && break
	done
	_dp_t1=$(uptime_cs)
	rm -f "$_dp_f"
	awk -v n="$_dp_n" -v t="$((_dp_t1 - _dp_t0))" 'BEGIN { if (t > 0) printf "%.0f\n", n * 4194304 * 100 / t; else print 0 }'
}

copy_main() {
	rm -rf "$CP_TMP"
	mkdir -p "$CP_TMP" || die "cannot create $CP_TMP"
	[ -s "$RETRO_RUN/selection.txt" ] || die "nothing selected ($RETRO_RUN/selection.txt is empty)"
	[ -s "$RETRO_RUN/scan.tsv" ] || die "no scan result"
	_type=$(dest_conf type)
	MACHINE=$(machine_name)
	selected_rows "$RETRO_RUN/scan.tsv" "$RETRO_RUN/selection.txt" >"$CP_TMP/rows"
	while IFS= read -r _sel; do
		grep -q "^$_sel$TAB" "$CP_TMP/rows" ||
			log INFO "copy: group $_sel lies inside another selected group and is copied with it"
	done <"$RETRO_RUN/selection.txt"
	N_GROUPS=$(grep -c '' "$CP_TMP/rows")
	TOTAL_BYTES=$(awk -F '\t' '{ s += $9 } END { printf "%.0f", s }' "$CP_TMP/rows")
	case $_type in
	usb | disk)
		# Never fill the RAM disk: the destination must be a mounted file system.
		if ! is_mountpoint "$RETRO_DST" && [ "${RETRO_DST_ANY:-0}" != 1 ]; then
			die "the destination $RETRO_DST is not mounted"
		fi
		DEST_ROOT=$RETRO_DST/BACKUP/$MACHINE
		DEST_DESC=$DEST_ROOT
		mkdir -p "$DEST_ROOT" || die "cannot write to $DEST_ROOT"
		;;
	net)
		NET_URL=$(dest_conf url)
		NET_URL=${NET_URL%/}
		[ -n "$NET_URL" ] || die "dest.conf has no url"
		DEST_DESC="$NET_URL BACKUP/$MACHINE"
		;;
	*) die "unknown destination type '$_type' in dest.conf" ;;
	esac
	log INFO "copy: $N_GROUPS groups, $(human_bytes "$TOTAL_BYTES"), to $DEST_DESC"
	I_GROUP=0
	while IFS= read -r _row <&3; do
		I_GROUP=$((I_GROUP + 1))
		if [ "$_type" = net ]; then
			copy_group_net "$_row"
		else
			copy_group_disk "$_row"
		fi
		DONE_BYTES=$(add "$DONE_BYTES" "$(tsv_field "$_row" 9)")
	done 3<"$CP_TMP/rows"
	progress 100 "$T_COPY_FINISHING"
	if [ "$_type" = net ]; then finish_net; else finish_disk; fi
	[ "$RETRO_DEBUG" = 1 ] || rm -rf "$CP_TMP"
	[ "$C_FAILED" = 0 ]
}

# Run only when executed, not when sourced by another script or a test.
case ${0##*/} in
40-copy.sh) copy_main "$@" ;;
esac
