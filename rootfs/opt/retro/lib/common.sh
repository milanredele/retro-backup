#!/bin/sh
# Common helpers for every retro-backup client script. POSIX sh, busybox-ash compatible.
# Sourced, never executed. Environment overrides (used by the tests):
#   RETRO_HOME      script directory            (default /opt/retro)
#   RETRO_RUN       runtime state directory     (default /run/retro)
#   RETRO_SRC_ROOT  prefix for source mounts    (default /mnt/src)
#   RETRO_DST       destination mountpoint      (default /mnt/dst)
#   RETRO_CMDLINE   kernel command line file    (default /proc/cmdline)
#   RETRO_LOG_TTY   extra log terminal          (default /dev/tty4, empty disables)

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

RETRO_HOME=${RETRO_HOME:-/opt/retro}
RETRO_LIB=$RETRO_HOME/lib
RETRO_RUN=${RETRO_RUN:-/run/retro}
RETRO_SRC_ROOT=${RETRO_SRC_ROOT:-/mnt/src}
RETRO_DST=${RETRO_DST:-/mnt/dst}
RETRO_CMDLINE=${RETRO_CMDLINE:-/proc/cmdline}
RETRO_LOG=$RETRO_RUN/retro-backup.log
RETRO_DEBUG_LOG=$RETRO_RUN/debug.log
RETRO_LOG_TTY=${RETRO_LOG_TTY-/dev/tty4}
export RETRO_HOME RETRO_LIB RETRO_RUN RETRO_SRC_ROOT RETRO_DST RETRO_CMDLINE RETRO_LOG_TTY

# shellcheck disable=SC2034 # used by the scripts sourcing this file
TAB=$(printf '\t')
# shellcheck disable=SC2034
NL='
'

mkdir -p "$RETRO_RUN" 2>/dev/null

# retro_param NAME DEFAULT: value of NAME=value on the kernel command line; a bare NAME gives 1.
retro_param() {
	_rp_v=
	if [ -r "$RETRO_CMDLINE" ]; then
		_rp_v=$(awk -v n="$1" '{
			for (i = 1; i <= NF; i++) {
				if ($i == n) { v = "1"; f = 1 }
				else if (index($i, n "=") == 1) { v = substr($i, length(n) + 2); f = 1 }
			}
		} END { if (f) print v }' "$RETRO_CMDLINE" 2>/dev/null)
	fi
	if [ -n "$_rp_v" ]; then printf '%s\n' "$_rp_v"; else printf '%s\n' "$2"; fi
}

RETRO_DEBUG=${RETRO_DEBUG:-$(retro_param retro.debug 0)}
RETRO_LANG=${RETRO_LANG:-$(retro_param retro.lang en)}

# log LEVEL MSG...: append a timestamped line to the session log and tty4.
# DEBUG lines only appear when retro.debug=1 (and then go to debug.log as well).
log() {
	_lv=$1
	shift
	if [ "$_lv" = DEBUG ] && [ "$RETRO_DEBUG" != 1 ]; then
		return 0
	fi
	_line="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) $_lv $*"
	if [ "$_lv" = DEBUG ]; then
		printf '%s\n' "$_line" >>"$RETRO_DEBUG_LOG" 2>/dev/null
	else
		printf '%s\n' "$_line" >>"$RETRO_LOG" 2>/dev/null
		[ "$RETRO_DEBUG" = 1 ] && printf '%s\n' "$_line" >>"$RETRO_DEBUG_LOG" 2>/dev/null
	fi
	if [ -n "$RETRO_LOG_TTY" ] && [ -w "$RETRO_LOG_TTY" ]; then
		printf '%s\r\n' "$_line" >"$RETRO_LOG_TTY" 2>/dev/null
	fi
	return 0
}

# die MSG: log an error, print it on stderr and exit 1.
die() {
	log ERROR "$*"
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# shquote WORD: print WORD single-quoted for eval.
shquote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# glob_escape STR: escape fnmatch metacharacters so find -path/-name match STR literally.
glob_escape() {
	printf '%s' "$1" | sed 's/[][\\*?]/\\&/g'
}

# sanitize_name STR [FALLBACK]: machine/volume names for the destination tree
# (CONTRACTS.md section 3): accents transliterated, everything outside [A-Za-z0-9._-]
# becomes '_', runs of '_' collapsed, leading/trailing '_' and '.' removed, max 40 chars.
sanitize_name() {
	_sn=$(printf '%s' "$1" | LC_ALL=C sed \
		-e 's/á/a/g;s/é/e/g;s/í/i/g;s/ó/o/g;s/ö/o/g;s/ő/o/g;s/ú/u/g;s/ü/u/g;s/ű/u/g' \
		-e 's/Á/A/g;s/É/E/g;s/Í/I/g;s/Ó/O/g;s/Ö/O/g;s/Ő/O/g;s/Ú/U/g;s/Ü/U/g;s/Ű/U/g' \
		-e 's/ä/a/g;s/Ä/A/g;s/ß/ss/g;s/à/a/g;s/è/e/g;s/ç/c/g;s/ñ/n/g;s/ø/o/g;s/å/a/g' \
		-e 's/č/c/g;s/š/s/g;s/ž/z/g;s/ř/r/g;s/ě/e/g;s/ł/l/g;s/ę/e/g;s/ą/a/g;s/ś/s/g' |
		LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | LC_ALL=C tr -s '_' |
		LC_ALL=C sed -e 's/^[_.]*//' -e 's/[_.]*$//' | LC_ALL=C cut -c1-40)
	if [ -z "$_sn" ]; then
		_sn=$(printf '%s' "${2:-unnamed}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | LC_ALL=C cut -c1-40)
	fi
	printf '%s\n' "$_sn"
}

# human_bytes N: 1024-based human readable size ("1.5 GB"). Works beyond 2^31.
human_bytes() {
	awk -v n="${1:-0}" 'BEGIN {
		split("B KB MB GB TB PB", u, " "); i = 1
		while (n >= 1024 && i < 6) { n /= 1024; i++ }
		if (i == 1) printf "%d %s\n", n, u[i]
		else if (n < 10) printf "%.1f %s\n", n, u[i]
		else printf "%d %s\n", n + 0.5, u[i]
	}'
}

# human_duration SECONDS: "1 h 20 min", "5 min", "40 s".
human_duration() {
	awk -v s="${1:-0}" 'BEGIN {
		s = int(s + 0.5)
		if (s >= 3600) printf "%d h %d min\n", int(s / 3600), int((s % 3600) / 60)
		else if (s >= 60) printf "%d min\n", int((s + 30) / 60)
		else printf "%d s\n", s
	}'
}

# --- tsv helpers. Fields never contain tabs or newlines; empty values are written as "-". ---

# tsv_field LINE N: field N (1-based) of a tab-separated LINE.
tsv_field() {
	printf '%s\n' "$1" | awk -F '\t' -v n="$2" '{ print $n; exit }'
}

# tsv_lookup FILE KEYCOL KEY: first line of FILE whose field KEYCOL equals KEY.
tsv_lookup() {
	awk -F '\t' -v c="$2" -v k="$3" '$c == k { print; exit }' "$1" 2>/dev/null
}

# tsv_clean STR: make a value safe for a tsv field (tabs/newlines -> space, empty -> "-").
tsv_clean() {
	_tc=$(printf '%s' "$1" | tr '\t\n\r' '   ')
	[ -n "$_tc" ] || _tc=-
	printf '%s\n' "$_tc"
}

# conf_lines FILE: configuration lines without comments and blank lines.
conf_lines() {
	sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"
}

# uptime_cs: monotonic time in centiseconds (from /proc/uptime).
uptime_cs() {
	awk '{ printf "%d\n", $1 * 100 }' /proc/uptime 2>/dev/null || echo 0
}

# write_atomic FILE: copy stdin to FILE via a temporary file in the same directory.
write_atomic() {
	cat >"$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}

# ci_has DIR NAME TYPE: DIR has an entry NAME (case-insensitive) of find -type TYPE (d or f).
# Symlinks (and NTFS junctions, which the kernel drivers show as symlinks) do not count.
ci_has() {
	[ -n "$(find "$1/" -mindepth 1 -maxdepth 1 -type "${3:-d}" -iname "$(glob_escape "$2")" \
		-print -quit 2>/dev/null)" ]
}

# detect_os_hint MNT: winxp, win7, linux, macos or data (CONTRACTS.md section 2).
detect_os_hint() {
	if ci_has "$1" Users && ci_has "$1" Windows; then
		echo win7
	elif ci_has "$1" "Documents and Settings"; then
		echo winxp
	elif ci_has "$1" Users && [ -d "$1/System/Library" ]; then
		echo macos
	elif [ -d "$1/etc" ] && { [ -d "$1/home" ] || [ -d "$1/root" ]; }; then
		echo linux
	else
		echo data
	fi
}

# list_has LIST ITEM: comma separated LIST contains ITEM (or is "*").
list_has() {
	case ",$1," in
	*",$2,"* | ",*,") return 0 ;;
	esac
	return 1
}

# build_prunes MNT: shell-quoted find primaries "\( ... \) -prune -o" from excludes.conf, for
# use with eval. BP_OS = os_hint; BP_MODE a = iname rules only (pass A and the copy stage),
# b = all rules plus the volume-relative paths listed in the file BP_EXTRA (pass B).
build_prunes() {
	_bp_first=1
	_bp_out=
	_bp_mnt=$(glob_escape "$1")
	while read -r _bp_os _bp_kind _bp_pat; do
		list_has "$_bp_os" "${BP_OS:-data}" || continue
		case $_bp_kind in
		iname) _bp_expr="-iname $(shquote "$_bp_pat")" ;;
		ipath)
			[ "$BP_MODE" = b ] || continue
			_bp_expr="-ipath $(shquote "$_bp_mnt/$_bp_pat")"
			;;
		*) continue ;;
		esac
		if [ $_bp_first = 1 ]; then _bp_out="$_bp_expr"; else _bp_out="$_bp_out -o $_bp_expr"; fi
		_bp_first=0
	done <<EOF_EXCLUDES
$(conf_lines "$RETRO_LIB/excludes.conf")
EOF_EXCLUDES
	if [ "$BP_MODE" = b ] && [ -n "$BP_EXTRA" ] && [ -s "$BP_EXTRA" ]; then
		while IFS= read -r _bp_r; do
			_bp_expr="-path $(shquote "$_bp_mnt/$(glob_escape "$_bp_r")")"
			if [ $_bp_first = 1 ]; then _bp_out="$_bp_expr"; else _bp_out="$_bp_out -o $_bp_expr"; fi
			_bp_first=0
		done <"$BP_EXTRA"
	fi
	[ -n "$_bp_out" ] && printf '\\( %s \\) -prune -o\n' "$_bp_out"
	return 0
}

# prunes MNT OS MODE [EXTRA]: wrapper setting the globals build_prunes reads.
prunes() {
	BP_OS=$2 BP_MODE=$3 BP_EXTRA=${4:-} build_prunes "$1"
}

# selected_rows [SCAN] [SELECTION]: scan.tsv rows of the selected groups in scan order,
# without groups whose path lies inside another selected group on the same volume (an email
# store inside Documents, a bucket inside "entire profile"): those are copied with it.
selected_rows() {
	awk -F '\t' 'FILENAME == ARGV[1] { S[$1] = 1; next }
		($1 in S) { n++; R[n] = $0; D[n] = $2; P[n] = $7 }
		END {
			for (i = 1; i <= n; i++) {
				inner = 0
				for (j = 1; j <= n; j++) {
					if (j == i || D[j] != D[i]) continue
					if (index(P[i], P[j] "/") == 1 || (P[i] == P[j] && j < i)) { inner = 1; break }
				}
				if (!inner) print R[i]
			}
		}' "${2:-$RETRO_RUN/selection.txt}" "${1:-$RETRO_RUN/scan.tsv}"
}

# is_mountpoint DIR: something is mounted at DIR.
is_mountpoint() {
	awk -v m="$1" '$2 == m { f = 1 } END { exit !f }' /proc/mounts 2>/dev/null
}

# dest_conf KEY: value of KEY in dest.conf.
dest_conf() {
	sed -n "s/^$1=//p" "$RETRO_RUN/dest.conf" 2>/dev/null | head -n 1
}

# ui_geometry: terminal size into UI_LINES / UI_COLS (at least 24x80) and the dialog box
# sizes derived from it. Size from, in order: stty size on /dev/tty, $LINES / $COLUMNS,
# tput, else 24x80. On 80x25 the boxes keep their old sizes (within a row or column).
#   UI_W_BIG UI_H_BIG UI_L_BIG  checklist, textboxes, summary (L = list rows = H - 8)
#   UI_H_MED UI_L_MED           destination and error menus (L = H - 8)
#   UI_W_MED                    message, yes/no, gauge, input and info boxes, small menus
_ui_num() { case $1 in '' | *[!0-9]*) return 1 ;; esac; }
# shellcheck disable=SC2034 # UI_* are used by the scripts sourcing this file
ui_geometry() {
	_gl=
	_gc=
	_gs=$(stty size 2>/dev/null </dev/tty) || _gs=
	read -r _gl _gc _gx <<EOS
$_gs
EOS
	if ! _ui_num "$_gl" || ! _ui_num "$_gc" || [ "$_gl" = 0 ] || [ "$_gc" = 0 ]; then
		_gl=${LINES:-}
		_gc=${COLUMNS:-}
	fi
	if ! _ui_num "$_gl" || ! _ui_num "$_gc"; then
		_gl=
		_gc=
		if have tput; then
			_gl=$(tput lines 2>/dev/null)
			_gc=$(tput cols 2>/dev/null)
		fi
	fi
	_ui_num "$_gl" || _gl=24
	_ui_num "$_gc" || _gc=80
	UI_LINES=$((_gl < 24 ? 24 : _gl))
	UI_COLS=$((_gc < 80 ? 80 : _gc))
	UI_W_BIG=$((UI_COLS - 4 > 120 ? 120 : UI_COLS - 4))
	UI_H_BIG=$((UI_LINES - 2 > 44 ? 44 : UI_LINES - 2))
	UI_L_BIG=$((UI_H_BIG - 8))
	UI_W_MED=$((UI_COLS - 10 > 90 ? 90 : UI_COLS - 10))
	UI_H_MED=$((UI_LINES - 7 > 24 ? 24 : UI_LINES - 7))
	UI_L_MED=$((UI_H_MED - 8))
	return 0
}

# i18n: UI strings live in lib/i18n/<lang>.sh as variables (T_*).
if [ -r "$RETRO_LIB/i18n/$RETRO_LANG.sh" ]; then
	# shellcheck source=i18n/en.sh
	. "$RETRO_LIB/i18n/$RETRO_LANG.sh"
else
	# shellcheck source=i18n/en.sh
	. "$RETRO_LIB/i18n/en.sh"
fi
