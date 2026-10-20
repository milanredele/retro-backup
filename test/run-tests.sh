#!/bin/sh
# run-tests.sh: client tests (rootfs/opt/retro) in an alpine container (busybox ash + the GNU
# tools Tiny Core gets from tcz extensions). On the host it builds test/Dockerfile.client and
# re-runs itself inside with --inside; the repository is mounted read-only at /src. Then
# test/devices-test.sh runs in a --privileged container (loop devices) unless
# RETRO_TEST_NO_PRIVILEGED=1.
#   static     shellcheck -s sh, sh -n (busybox ash)
#   units      sanitising, cmdline, sizes, os_hint, json, selection, checklist arguments
#   scan       20-scan.sh on the fixtures (test/fixtures/make-fixtures.sh): pass A and B groups
#   copy-usb   40-copy.sh to a directory: byte-exact, mtimes, MANIFEST md5s, renames, log
#   net        40-copy.sh to test/fake-helper.py: one valid tar per group, manifest last,
#              contents, resume, log; 50-net.sh CLI; UDP beacon with busybox nc
#   dialog     real dialog in a pty parses the checklist arguments; UI flow with a stub
#   big        (RETRO_TEST_BIG=1) 1 million files: time and gawk memory
set -u

if [ "${1:-}" != --inside ]; then
	REPO=$(cd "$(dirname "$0")/.." && pwd)
	echo "building test image..."
	docker build -q -t retro-client-test -f "$REPO/test/Dockerfile.client" "$REPO/test" >/dev/null || exit 1
	docker run --rm -e RETRO_TEST_BIG="${RETRO_TEST_BIG:-0}" -v "$REPO:/src:ro" retro-client-test sh /src/test/run-tests.sh --inside
	rc=$?
	# 10-devices.sh needs real block devices: loop devices in a privileged container.
	if [ "${RETRO_TEST_NO_PRIVILEGED:-0}" != 1 ]; then
		docker run --rm --privileged -v "$REPO:/src:ro" retro-client-test sh /src/test/devices-test.sh || rc=1
	fi
	exit $rc
fi

SRC=/src
export RETRO_HOME=$SRC/rootfs/opt/retro
T=$(mktemp -d /tmp/retro-test.XXXXXX)
RETRO_RUN="$T/run" RETRO_SRC_ROOT="$T/fx" RETRO_DST="$T/dst" RETRO_LOG_TTY='' RETRO_CMDLINE="$T/cmdline"
export RETRO_RUN RETRO_SRC_ROOT RETRO_DST RETRO_LOG_TTY RETRO_CMDLINE
# The copy destination is a plain directory here, not a mounted file system.
RETRO_DST_ANY=1
export RETRO_DST_ANY
mkdir -p "$RETRO_RUN" "$RETRO_DST"
: >"$RETRO_CMDLINE"
TAB=$(printf '\t')
PASS=0
FAIL=0
HELPER_PID=
BEACON_PID=

ok() {
	PASS=$((PASS + 1))
	echo ok >>"$T/tally" # counted from the file at the end: several sections run in subshells
	printf '  ok   %s\n' "$*"
}
fail() {
	FAIL=$((FAIL + 1))
	echo fail >>"$T/tally"
	printf '  FAIL %s\n' "$*"
}
check() { # check DESCRIPTION COMMAND...
	_d=$1
	shift
	if "$@" >/dev/null 2>&1; then ok "$_d"; else fail "$_d"; fi
}
eq() { # eq DESCRIPTION GOT WANT
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}
section() { printf '\n== %s\n' "$*"; }
cleanup() {
	[ -n "$HELPER_PID" ] && kill "$HELPER_PID" 2>/dev/null
	[ -n "$BEACON_PID" ] && kill "$BEACON_PID" 2>/dev/null
}
trap cleanup EXIT

# --------------------------------------------------------------------------- static
section static
SCRIPTS=$(ls "$RETRO_HOME"/*.sh "$RETRO_HOME"/lib/*.sh "$RETRO_HOME"/lib/i18n/*.sh)
if (cd "$RETRO_HOME" && shellcheck -s sh -x -P SCRIPTDIR:SCRIPTDIR/lib ./*.sh lib/*.sh lib/i18n/*.sh) >"$T/shellcheck.out" 2>&1; then
	ok "shellcheck -s sh clean ($(echo "$SCRIPTS" | wc -l) files)"
else
	fail "shellcheck: $(head -n 30 "$T/shellcheck.out")"
fi
for f in $SCRIPTS "$SRC"/test/*.sh "$SRC"/test/fixtures/*.sh; do
	busybox sh -n "$f" 2>"$T/n.err" || fail "sh -n $f: $(cat "$T/n.err")"
done
ok "busybox sh -n parses every script"
for f in "$RETRO_HOME"/*.sh; do
	[ -x "$f" ] || fail "not executable: $f"
done
for f in "$RETRO_HOME"/lib/*.awk; do
	case $f in */scan-common.awk | */fsname.awk) continue ;; esac
	gawk -o/dev/null -f "$RETRO_HOME/lib/scan-common.awk" -f "$RETRO_HOME/lib/fsname.awk" -f "$f" \
		</dev/null >"$T/awk.err" 2>&1 || fail "gawk $f: $(head -n 3 "$T/awk.err")"
done
ok "awk programs compile"

# --------------------------------------------------------------------------- fixtures
section fixtures
sh "$SRC/test/fixtures/make-fixtures.sh" "$RETRO_SRC_ROOT" >"$T/expect.txt" || fail "make-fixtures.sh"
eq "fixture expectations printed" "$(grep -c '^EXPECT' "$T/expect.txt")" 28
X=$RETRO_SRC_ROOT
expect_files() { awk -v k="$1" '$2 == k { print $3 }' "$T/expect.txt"; }
expect_bytes() { awk -v k="$1" '$2 == k { print $4 }' "$T/expect.txt"; }
snapshot() { (cd "$X" && find . -printf '%p %s %T@ %m %y\n' | LC_ALL=C sort && find . -type f -exec md5sum {} + | LC_ALL=C sort) | md5sum; }
SNAP0=$(snapshot)
{
	printf '/dev/sda1\tntfs3\tSYSTEM\t80026361856\t%s\twinxp\n' "$X/xp"
	printf '/dev/sdb1\tntfs3\t-\t250059350016\t%s\twin7\n' "$X/win7"
	printf '/dev/sdc1\text3\t-\t40007761920\t%s\tlinux\n' "$X/linux"
	printf '/dev/sdd1\tvfat\tCANON\t2000000000\t%s\tdata\n' "$X/camera"
} >"$RETRO_RUN/volumes.tsv"

# --------------------------------------------------------------------------- units
section units
(
	. "$RETRO_HOME/lib/common.sh"
	eq "sanitize_name accents and spaces" "$(sanitize_name 'Jóska gépe (régi)!')" "Joska_gepe_regi"
	eq "sanitize_name max 40" "$(sanitize_name 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH' | wc -c)" 41
	eq "sanitize_name fallback" "$(sanitize_name '%%%' sda1)" "sda1"
	printf 'quiet base retro.dest=http://10.0.0.5:8080 retro.debug noswap\n' >"$T/cl"
	eq "retro_param value" "$(RETRO_CMDLINE=$T/cl retro_param retro.dest x)" "http://10.0.0.5:8080"
	eq "retro_param bare flag" "$(RETRO_CMDLINE=$T/cl retro_param retro.debug 0)" "1"
	eq "retro_param default" "$(RETRO_CMDLINE=$T/cl retro_param retro.lang en)" "en"
	eq "human_bytes 0" "$(human_bytes 0)" "0 B"
	eq "human_bytes 1536" "$(human_bytes 1536)" "1.5 KB"
	eq "human_bytes 5e9" "$(human_bytes 5000000000)" "4.7 GB"
	eq "human_duration" "$(human_duration 4830)" "1 h 20 min"
	eq "os_hint xp" "$(detect_os_hint "$X/xp")" winxp
	eq "os_hint win7 (Documents and Settings is a junction there)" "$(detect_os_hint "$X/win7")" win7
	eq "os_hint linux" "$(detect_os_hint "$X/linux")" linux
	eq "os_hint camera" "$(detect_os_hint "$X/camera")" data
	clean() { printf '%s\n' "$1" | LC_ALL=C gawk -f "$RETRO_LIB/fsname.awk" -e '{ print fs_clean_path($0) }'; }
	eq "fs names: illegal characters" "$(clean 'a/report: final?.txt')" "a/report_ final_.txt"
	eq "fs names: trailing dot in a directory" "$(clean 'drafts./idea.txt')" "drafts_/idea.txt"
	eq "fs names: <>|\" and trailing space" "$(clean 'x<y>|"z /b')" "x_y___z_/b"
	eq "fs names: UTF-8 untouched" "$(clean 'Fotók 2007/árvíztűrő.jpg')" "Fotók 2007/árvíztűrő.jpg"
	eq "glob_escape" "$(glob_escape 'a[1]*?')" 'a\[1\]\*\?'
	printf '{"files":[{"path":"a/J\\u00f3ska.txt","size":12,"md5":"0a"},{"md5":"0b","path":"b c","size":3}]}' |
		LC_ALL=C gawk -f "$RETRO_LIB/json.awk" >"$T/json.out"
	eq "json.awk decodes \\u escapes" "$(sed -n 1p "$T/json.out")" "files.0.path${TAB}a/Jóska.txt"
	eq "json.awk key order" "$(grep -c '^files\.1\.' "$T/json.out")" 3
)
# ui_geometry: dialog sizes follow the terminal (no tty here, so $LINES / $COLUMNS decide).
geom() { # geom LINES COLUMNS ("-" for unset)
	(
		LINES=$1 COLUMNS=$2
		[ "$1" = - ] && unset LINES COLUMNS TERM
		. "$RETRO_HOME/lib/common.sh"
		ui_geometry
		echo "$UI_LINES $UI_COLS big $UI_H_BIG $UI_W_BIG $UI_L_BIG med $UI_H_MED $UI_W_MED $UI_L_MED"
	) </dev/null 2>/dev/null
}
eq "ui_geometry 100x37 (800x600 framebuffer)" "$(geom 37 100)" "37 100 big 35 96 27 med 24 90 16"
eq "ui_geometry 128x48 is capped" "$(geom 48 128)" "48 128 big 44 120 36 med 24 90 16"
eq "ui_geometry 80x25 keeps the old sizes" "$(geom 25 80)" "25 80 big 23 76 15 med 18 70 10"
eq "ui_geometry 80x24" "$(geom 24 80)" "24 80 big 22 76 14 med 17 70 9"
eq "ui_geometry clamps to 80x24" "$(geom 10 40)" "24 80 big 22 76 14 med 17 70 9"
eq "ui_geometry without any size source" "$(geom - -)" "24 80 big 22 76 14 med 17 70 9"

# --------------------------------------------------------------------------- scan
section scan
sh "$RETRO_HOME/20-scan.sh" >"$T/scan.out" 2>&1 || fail "20-scan.sh exit status: $(tail -n 3 "$T/scan.out")"
S=$RETRO_RUN/scan.tsv
LOG=$RETRO_RUN/retro-backup.log
check "scan.tsv written" test -s "$S"
eq "scan.tsv has 10 columns everywhere" "$(awk -F '\t' 'NF != 10' "$S" | wc -l)" 0
eq "scan.progress ends with ALL 100" "$(tail -n 1 "$RETRO_RUN/scan.progress")" "ALL${TAB}100"
row() { awk -F '\t' -v d="$1" -v p="$2" '$2 == d && $7 == p' "$S"; }
gid() { row "$1" "$2" | cut -f1; }
# group DEV PATH PASS CATEGORY FILES PRESELECT KEY: assert one scan.tsv line (bytes from KEY)
group() {
	_r=$(row "$1" "$2")
	if [ -z "$_r" ]; then
		fail "group $1:$2 missing"
		return
	fi
	_want="$3 $4 $5 $(expect_bytes "$7") $6"
	_got=$(printf '%s\n' "$_r" | awk -F '\t' '{ print $3, $4, $8, $9, $10 }')
	if [ "$_got" = "$_want" ] && [ "$(expect_files "$7")" = "$5" ]; then
		ok "group $2 ($3, $4, $5 files, $(expect_bytes "$7") bytes)"
	else
		fail "group $1:$2: got '$_got', want '$_want' (fixture says $(expect_files "$7") files)"
	fi
}
J="Documents and Settings/Jóska"
OEP="$J/Local Settings/Application Data/Identities/{3F2A1B4C-1111-2222-3333-444455556666}/Microsoft/Outlook Express"
group /dev/sda1 "$J/My Documents" A documents 26 1 xp_mydocs
group /dev/sda1 "$OEP" A email 5 1 xp_oe
group /dev/sda1 "$J/Local Settings/Application Data/Microsoft/Outlook/outlook.pst" A email 1 1 xp_pst
group /dev/sda1 "$J/Application Data/Microsoft/Address Book" A email 1 1 xp_wab
group /dev/sda1 "$J/Desktop" A photos 3 1 xp_desktop
group /dev/sda1 "$J/Favorites" A other 4 1 xp_favorites
group /dev/sda1 "Documents and Settings/All Users/Documents" A documents 1 1 xp_shared
group /dev/sda1 "Fotók 2007" B photos 60 0 xp_fotok
group /dev/sda1 "Munka" B documents 13 0 xp_munka
group /dev/sdb1 "Users/Anna/Documents" A documents 7 1 w7_docs
group /dev/sdb1 "Users/Anna/Documents/Outlook Files/x.pst" A email 1 1 w7_pst
group /dev/sdb1 "Users/Anna/Pictures" A photos 12 1 w7_pics
group /dev/sdb1 "Users/Anna/AppData/Local/Microsoft/Outlook/Anna & Béla.pst" A email 1 1 w7_pst2
group /dev/sdb1 "Users/Anna/Videos" A videos 2 1 w7_videos
group /dev/sdb1 "Users/Anna/Downloads" A documents 2 1 w7_downloads
group /dev/sdb1 "Users/Anna/AppData/Local/Microsoft/Windows Live Mail" A email 6 1 w7_wlm
group /dev/sdb1 "Users/Anna/AppData/Roaming/Thunderbird/Profiles" A email 5 1 w7_tb
group /dev/sdb1 "Users/Public" A photos 3 1 w7_public
group /dev/sdb1 "Windows.old/Users/Old/Documents" A documents 4 1 w7_old_docs
group /dev/sdc1 "home/milan/Pictures" A photos 10 1 l_pics
group /dev/sdc1 "home/milan/Documents" A documents 7 1 l_docs
group /dev/sdc1 "home/milan/.thunderbird" A email 3 1 l_tb
group /dev/sdc1 "home/milan/Maildir" A email 4 1 l_maildir
group /dev/sdc1 "home/milan/.mozilla/firefox" A other 1 1 l_ff
group /dev/sdc1 "var/mail/milan" A email 1 1 l_mbox
group /dev/sdc1 "srv/zene" B music 3 0 l_zene
group /dev/sdd1 "DCIM" B photos 53 0 cam_dcim
eq "labels: Outlook Express" "$(row /dev/sda1 "$OEP" | cut -f6)" "Jóska / Outlook Express mail"
eq "labels: Windows.old" "$(row /dev/sdb1 "Windows.old/Users/Old/Documents" | cut -f6)" "Windows.old / Old / Documents"
eq "labels: sweep with drive letter" "$(row /dev/sda1 "Fotók 2007" | cut -f6)" 'C:\Fotók 2007'
eq "labels: camera card is E:" "$(row /dev/sdd1 DCIM | cut -f6)" 'E:\DCIM'
eq "user column" "$(row /dev/sdb1 Users/Anna/Pictures | cut -f5) $(row /dev/sda1 Munka | cut -f5)" "Anna -"
eq "whole profile offered, not ticked" "$(row /dev/sda1 "$J" | cut -f3,4,10 | tr '\t' ' ')" "A other 0"
eq "no group in system areas" "$(cut -f7 "$S" | grep -ciE '^(windows|winnt|program files|programdata|recycler|\$recycle\.bin|system volume information|usr|lib|var/cache|windows\.old/windows|windows\.old/program files)(/|$)')" 0
eq "no group for non-user profiles" "$(cut -f7 "$S" | grep -cE '(Default User|LocalService|NetworkService|Users/Default|All Users/Application Data)')" 0
eq "junctions ignored (My Documents link, Documents and Settings on win7)" "$(awk -F '\t' '$2 == "/dev/sdb1" && ($7 ~ /^Documents and Settings/ || $7 ~ /My Documents/)' "$S" | wc -l)" 0
eq "Temp / Temporary Internet Files / caches not counted" "$(row /dev/sda1 "$J" | cut -f8)" 43
eq "tab-named file absent from scan.tsv" "$(grep -c 'vázlat' "$S")" 0
check "tab-named file logged" grep -qF 'SKIPPED path with a tab or newline in its name: Munka/jelentés\tvázlat.doc' "$LOG"
check "loose file in the volume root logged" grep -q "1 matching files directly in '/'" "$LOG"
eq "group ids are g0001.. in order" "$(cut -f1 "$S" | awk '{ if ($0 != sprintf("g%04d", NR)) bad++ } END { print bad + 0 }')" 0
eq "order: dev, A before B, bytes descending" "$(awk -F '\t' '{
	k = $2 SUBSEP $3
	if (NR > 1 && ($2 < pd || ($2 == pd && $3 < pp) || (k == pk && $9 + 0 > pb + 0))) bad++
	pd = $2; pp = $3; pk = k; pb = $9 } END { print bad + 0 }' "$S")" 0
eq "no B group overlaps an A group, B groups never nest" "$(awk -F '\t' '
	{ D[NR] = $2; P[NR] = $3; R[NR] = $7 }
	END {
		for (i = 1; i <= NR; i++) for (j = 1; j <= NR; j++) {
			if (i == j || D[i] != D[j] || P[i] != "B") continue
			a = R[i]; b = R[j]
			if (a == b || index(b, a "/") == 1 || index(a, b "/") == 1) bad++
		}
		print bad + 0
	}' "$S")" 0
eq "label with & and accents" "$(row /dev/sdb1 "Users/Anna/AppData/Local/Microsoft/Outlook/Anna & Béla.pst" | cut -f6)" "Anna / Anna & Béla.pst"
eq "group count" "$(grep -c '' "$S")" 36
# Group cap: three mixed subfolders of one folder become one group when the cap is 2.
mkdir -p "$T/cap/vol/Mentés/képek" "$T/cap/vol/Mentés/zene" "$T/cap/vol/Mentés/iratok" "$T/cap/run"
for i in 1 2 3; do
	: >"$T/cap/vol/Mentés/képek/$i.jpg"
	: >"$T/cap/vol/Mentés/zene/$i.mp3"
	: >"$T/cap/vol/Mentés/iratok/$i.doc"
done
printf '/dev/sde1\text4\t-\t1\t%s\tdata\n' "$T/cap/vol" >"$T/cap/run/volumes.tsv"
RETRO_RUN=$T/cap/run sh "$RETRO_HOME/20-scan.sh" >/dev/null 2>&1
eq "without a cap: one group per subfolder" "$(cut -f7 "$T/cap/run/scan.tsv" | sort | tr '\n' '|')" "Mentés/iratok|Mentés/képek|Mentés/zene|"
RETRO_MAX_GROUPS=2 RETRO_RUN=$T/cap/run sh "$RETRO_HOME/20-scan.sh" >/dev/null 2>&1
eq "with RETRO_MAX_GROUPS=2: merged into the parent" "$(cut -f7,8 "$T/cap/run/scan.tsv" | tr '\t\n' ' |')" "Mentés 9|"

# --------------------------------------------------------------------------- selection
section selection
(
	. "$RETRO_HOME/lib/common.sh"
	printf '%s\n%s\n%s\n' "$(gid /dev/sdb1 Users/Anna/Documents)" "$(gid /dev/sdb1 "Users/Anna/Documents/Outlook Files/x.pst")" \
		"$(gid /dev/sda1 Munka)" >"$T/sel"
	eq "selected_rows drops a group inside another selected group" "$(selected_rows "$S" "$T/sel" | cut -f7 | tr '\n' '|')" "Munka|Users/Anna/Documents|"
	eq "selected_rows keeps it when alone" "$(gid /dev/sdb1 "Users/Anna/Documents/Outlook Files/x.pst" | selected_rows "$S" - | cut -f7)" "Users/Anna/Documents/Outlook Files/x.pst"
)

# --------------------------------------------------------------------------- copy to a usb/disk destination
section copy-usb
SEL_KEYS="sda1:$J/My Documents|sda1:$OEP|sda1:$J/Local Settings/Application Data/Microsoft/Outlook/outlook.pst|sda1:Fotók 2007|sda1:Munka|sdb1:Users/Anna/Documents|sdb1:Users/Anna/Documents/Outlook Files/x.pst|sdc1:home/milan/Documents|sdc1:home/milan/Maildir|sdd1:DCIM"
select_groups() { # select_groups "dev:path|dev:path..." -> selection.txt
	echo "$1" | tr '|' '\n' | while IFS= read -r _k; do gid "/dev/${_k%%:*}" "${_k#*:}"; done >"$RETRO_RUN/selection.txt"
}
select_groups "$SEL_KEYS"
eq "selection has 10 groups" "$(grep -c '^g' "$RETRO_RUN/selection.txt")" 10
printf 'type=usb\npath=%s\n' "$RETRO_DST" >"$RETRO_RUN/dest.conf"
RETRO_DST_ANY=0 sh "$RETRO_HOME/40-copy.sh" >"$T/copy0.out" 2>&1
eq "refuses an unmounted usb destination (would fill the RAM disk)" "$?" 1
check "and says why" grep -q 'is not mounted' "$T/copy0.out"
sh "$RETRO_HOME/40-copy.sh" >"$T/copy.out" 2>&1
eq "40-copy.sh exit status" "$?" 0
M=$(cat "$RETRO_RUN/machine")
eq "machine name from the linux /etc/hostname" "$M" milan-pc
B=$RETRO_DST/BACKUP/$M
eq "result counters" "$(grep -E '^(groups|failed|renamed|skipped)=' "$RETRO_RUN/copy.result" | tr '\n' ' ')" "groups=9 failed=0 renamed=6 skipped=1 "
check "x.pst inside Documents copied with it (logged)" grep -q 'lies inside another selected group' "$LOG"
check "session log on the destination" test -s "$B/retro-backup.log"
check "scan.tsv on the destination" cmp "$S" "$B/scan.tsv"
check "RENAMED report: final?.txt" grep -qF 'RENAMED sdc1/home/milan/Documents/report: final?.txt -> sdc1/home/milan/Documents/report_ final_.txt' "$LOG"
check "RENAMED Maildir names with ':' (illegal on exFAT)" grep -qF 'RENAMED sdc1/home/milan/Maildir/cur/1199999999.M1P1.milan-pc:2,S -> sdc1/home/milan/Maildir/cur/1199999999.M1P1.milan-pc_2,S' "$LOG"
check "RENAMED backslash" grep -qF 'RENAMED sdc1/home/milan/Documents/back\slash & co.txt -> sdc1/home/milan/Documents/back_slash & co.txt' "$LOG"
check "RENAMED directory with a trailing dot" grep -qF 'RENAMED sdc1/home/milan/Documents/drafts./idea.txt -> sdc1/home/milan/Documents/drafts_/idea.txt' "$LOG"
# verify_tree VOL MNT PATH: every source file (minus tab names) byte-exact with its mtime
verify_tree() {
	(cd "$2" && find "./$3" -type f -printf '%P\n') | sed "s|^|$3/|; s|^$3/\$||" >/dev/null
	(cd "$2" && find "./$3" -type f -printf '%p\n') | sed 's|^\./||' | grep -v "$TAB" |
		LC_ALL=C gawk -f "$RETRO_HOME/lib/fsname.awk" -e '{ print $0 "\t" fs_clean_path($0) }' >"$T/tree"
	_bad=0
	_n=0
	while IFS="$TAB" read -r _s _d; do
		_n=$((_n + 1))
		if ! cmp -s "$2/$_s" "$B/$1/$_d"; then
			_bad=$((_bad + 1))
			echo "    differs: $1/$_d"
		elif [ "$(stat -c %Y "$2/$_s")" != "$(stat -c %Y "$B/$1/$_d")" ]; then
			_bad=$((_bad + 1))
			echo "    mtime: $1/$_d"
		fi
	done <"$T/tree"
	if [ $_bad = 0 ] && [ $_n -gt 0 ]; then ok "byte-exact with mtimes: $1/$3 ($_n files)"; else fail "$1/$3: $_bad of $_n files differ"; fi
}
verify_tree SYSTEM "$X/xp" "$J/My Documents"
verify_tree SYSTEM "$X/xp" "$OEP"
verify_tree SYSTEM "$X/xp" "$J/Local Settings/Application Data/Microsoft/Outlook/outlook.pst"
verify_tree SYSTEM "$X/xp" "Fotók 2007"
verify_tree SYSTEM "$X/xp" "Munka"
verify_tree sdb1 "$X/win7" "Users/Anna/Documents"
verify_tree sdc1 "$X/linux" "home/milan/Documents"
verify_tree sdc1 "$X/linux" "home/milan/Maildir"
verify_tree CANON "$X/camera" "DCIM"
check "tab-named file not copied" test ! -e "$B/SYSTEM/Munka/jelentés${TAB}vázlat.doc"
check "file with a leading dash copied" cmp "$X/xp/Munka/-kezdő.txt" "$B/SYSTEM/Munka/-kezdő.txt"
# verify_manifest VOL: every MANIFEST line matches the destination file (md5, size)
verify_manifest() {
	_m=$B/$1/MANIFEST.tsv
	_bad=0
	_n=0
	while IFS="$TAB" read -r _p _s _t _h; do
		_n=$((_n + 1))
		[ "$(md5sum <"$B/$1/$_p" | cut -c1-32)" = "$_h" ] && [ "$(stat -c %s "$B/$1/$_p")" = "$_s" ] || _bad=$((_bad + 1))
	done <"$_m"
	_files=$(find "$B/$1" -type f ! -name MANIFEST.tsv | wc -l)
	if [ $_bad = 0 ] && [ "$_n" = "$_files" ]; then ok "MANIFEST.tsv of $1: $_n md5s match"; else fail "MANIFEST $1: $_bad bad of $_n lines, $_files files"; fi
}
verify_manifest SYSTEM
verify_manifest sdb1
verify_manifest sdc1
verify_manifest CANON
check "manifest names the renamed file by its new name" grep -qF "home/milan/Documents/report_ final_.txt$TAB" "$B/sdc1/MANIFEST.tsv"
eq "sources untouched" "$(snapshot)" "$SNAP0"
sh "$RETRO_HOME/40-copy.sh" >"$T/copy2.out" 2>&1
eq "second copy run exit status" "$?" 0
eq "manifest has no duplicate paths after a second run" "$(cut -f1 "$B/SYSTEM/MANIFEST.tsv" | sort | uniq -d | wc -l)" 0
eq "log on the destination appended, not overwritten" "$(grep -c 'copy: finished' "$B/retro-backup.log")" 2
select_groups "sda1:Fotók 2007|sdd1:DCIM"
RETRO_DST=$T/dst-gauge RETRO_GAUGE=1 sh "$RETRO_HOME/40-copy.sh" >"$T/gauge.out" 2>&1
eq "gauge copy exit status" "$?" 0
eq "gauge protocol: XXX blocks are balanced" "$(($(grep -cx XXX "$T/gauge.out") % 2))" 0
eq "gauge percentages never go down and end at 100" "$(awk 'p == 1 { if ($0 + 0 < last) bad++; last = $0 + 0; p = 0 } $0 == "XXX" { n++; p = (n % 2 == 1) } END { print bad + 0, last }' "$T/gauge.out")" "0 100"
check "gauge shows the label with its backslash" grep -qF 'C:\Fotók 2007' "$T/gauge.out"
check "gauge shows rsync's current file" grep -q '^Fotók 2007/.*\.JPG$' "$T/gauge.out"

DP=$(. "$RETRO_HOME/40-copy.sh"; disk_probe "$T/dst-gauge" 1)
if [ "${DP:-0}" -gt 0 ] 2>/dev/null; then ok "disk_probe (ETA on the confirm screen): $DP bytes/s"; else fail "disk_probe gave '$DP'"; fi
check "disk_probe removes its file" sh -c "! ls -a '$T/dst-gauge' | grep -q retro-probe"

# --------------------------------------------------------------------------- network destination
section net
HP=18080
URL=http://127.0.0.1:$HP
python3 "$SRC/test/fake-helper.py" $HP "$T/helper" >"$T/helper.out" 2>&1 &
HELPER_PID=$!
i=0
while ! curl -s "$URL/status" >/dev/null 2>&1 && [ $i -lt 50 ]; do
	sleep 0.1
	i=$((i + 1))
done
eq "50-net.sh status" "$(sh "$RETRO_HOME/50-net.sh" status "$URL")" ok
eq "50-net.sh free" "$(sh "$RETRO_HOME/50-net.sh" free "$URL")" 123456789012
P=$(sh "$RETRO_HOME/50-net.sh" probe "$URL" 2)
if [ "${P:-0}" -gt 1000000 ] 2>/dev/null; then ok "50-net.sh probe: $P bytes/s"; else fail "probe gave '$P'"; fi
check "probe hit the helper's discard sink" grep -q 'machine=_probe.*probe bytes=' "$T/helper/requests.log"
printf 'quiet retro.dest=%s/\n' "$URL" >"$RETRO_CMDLINE"
eq "discover from retro.dest" "$(sh "$RETRO_HOME/50-net.sh" discover)" "$URL"
: >"$RETRO_CMDLINE"
python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('', 9999))
while True:
    d, a = s.recvfrom(1500)
    if d.startswith(b'RETRO-HELPER?'):
        s.sendto(b'RETRO-HELPER $URL', a)
" &
BEACON_PID=$!
sleep 0.5
eq "UDP beacon (busybox nc)" "$(sh "$RETRO_HOME/50-net.sh" beacon)" "$URL"
eq "discover via the beacon" "$(sh "$RETRO_HOME/50-net.sh" discover)" "$URL"
kill "$BEACON_PID" 2>/dev/null
BEACON_PID=
check "client tar is busybox tar (as on Tiny Core)" sh -c '! tar --version 2>/dev/null | grep -q GNU'
select_groups "sda1:$J/My Documents|sda1:$OEP|sdc1:home/milan/Documents|sdd1:DCIM|sda1:Fotók 2007"
printf 'type=net\nurl=%s\n' "$URL" >"$RETRO_RUN/dest.conf"
: >"$T/helper/requests.log"
sh "$RETRO_HOME/40-copy.sh" >"$T/net.out" 2>&1
eq "40-copy.sh (net) exit status" "$?" 0
eq "one upload per group" "$(grep -c 'POST /upload?machine=milan-pc' "$T/helper/requests.log")" 5
eq "every upload is one valid tar ending with .retro-manifest.tsv" "$(grep 'POST /upload?machine=milan-pc' "$T/helper/requests.log" | grep -c 'last=.retro-manifest.tsv problems=none')" 5
for tf in "$T"/helper/uploads/*.tar; do
	[ "$(busybox tar -tf "$tf" | tail -n 1)" = .retro-manifest.tsv ] || fail "busybox tar -t: last member of $tf"
done
ok "busybox tar -t lists the manifest last in every upload"
HB=$T/helper/BACKUP/$M
# verify_net VOL MNT PATH
verify_net() {
	(cd "$2" && find "./$3" -type f -printf '%p\n') | sed 's|^\./||' | grep -v "$TAB" |
		LC_ALL=C gawk -f "$RETRO_HOME/lib/fsname.awk" -e '{ print $0 "\t" fs_clean_path($0) }' >"$T/tree"
	_bad=0
	_n=0
	while IFS="$TAB" read -r _s _d; do
		_n=$((_n + 1))
		cmp -s "$2/$_s" "$HB/$1/$_d" || { _bad=$((_bad + 1)); echo "    differs: $1/$_d"; }
	done <"$T/tree"
	if [ $_bad = 0 ] && [ $_n -gt 0 ]; then ok "received byte-exact: $1/$3 ($_n files)"; else fail "net $1/$3: $_bad of $_n differ"; fi
}
verify_net SYSTEM "$X/xp" "$J/My Documents"
verify_net SYSTEM "$X/xp" "$OEP"
verify_net sdc1 "$X/linux" "home/milan/Documents"
verify_net CANON "$X/camera" DCIM
verify_net SYSTEM "$X/xp" "Fotók 2007"
eq "no .CORRUPT files on the helper" "$(find "$HB" -name '*.CORRUPT' | wc -l)" 0
check "renames reported by the helper are logged" grep -qF 'RENAMED sdc1/home/milan/Documents/report: final?.txt -> sdc1/home/milan/Documents/report_ final_.txt' "$LOG"
check "log posted to the helper" grep -q 'copy: finished' "$HB/retro-backup.log"
check "scan.tsv appended to the posted log" grep -q '===== scan.tsv =====' "$HB/retro-backup.log"
: >"$T/helper/requests.log"
sh "$RETRO_HOME/40-copy.sh" >"$T/net2.out" 2>&1
eq "resume run exit status" "$?" 0
eq "resume: nothing sent again" "$(grep -c 'POST /upload' "$T/helper/requests.log")" 0
check "resume: logged as already on the helper" grep -q 'files already on the helper (resume)' "$LOG"
check "resume asked GET /resume" grep -q 'GET /resume?machine=milan-pc&volume=SYSTEM&group=' "$T/helper/requests.log"
eq "sources untouched after the net copy" "$(snapshot)" "$SNAP0"

# --------------------------------------------------------------------------- dialog
section dialog
. "$RETRO_HOME/lib/common.sh"
CK=$T/checked.none
(
	. "$RETRO_HOME/30-ui.sh"
	ui_checklist_items "$S" "$CK" >"$T/items"
	printf '%s\n%s\n' "$(gid /dev/sda1 Munka)" "$(gid /dev/sdd1 DCIM)" >"$T/checked"
	ui_checklist_items "$S" "$T/checked" >"$T/items2"
	UI_W_BIG=96 ui_checklist_items "$S" "$CK" >"$T/items3"
)
eq "checklist items: 3 lines per group" "$(grep -c '' "$T/items")" $(($(grep -c '' "$S") * 3))
eq "checklist status column is on/off" "$(awk 'NR % 3 == 0 && $0 != "on" && $0 != "off"' "$T/items" | wc -l)" 0
eq "checklist: preselect column honoured" "$(awk 'NR % 3 == 1 { t = $0 } NR % 3 == 0 && $0 == "on" { print t }' "$T/items" | tr '\n' ' ')" "$(awk -F '\t' '$10 == 1 { printf "%s ", $1 }' "$S")"
eq "checklist: ticked set overrides preselect" "$(awk 'NR % 3 == 1 { t = $0 } NR % 3 == 0 && $0 == "on" { print t }' "$T/items2" | tr '\n' ' ')" "$(tr '\n' ' ' <"$T/checked")"
eq "checklist text fits 66 columns" "$(awk 'NR % 3 == 2' "$T/items" | LC_ALL=C.UTF-8 gawk 'length($0) > 66' | wc -l)" 0
eq "checklist text on 100 columns: name column 20 wider" "$(awk 'NR % 3 == 2' "$T/items3" | LC_ALL=C.UTF-8 gawk 'length($0) > m { m = length($0) } END { print m }')" 84
# Real dialog in a pseudo-terminal: Enter must return exactly the preselected tags,
# Details (help button) must return "HELP <tag>" followed by the ticked tags.
cat >"$T/run-dialog.py" <<'EOF'
import os, pty, sys, time, select
keys = [k.encode().decode('unicode_escape').encode() for k in sys.argv[1].split('|')]
args = sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    if os.environ.get('PTY_SIZE'):
        import fcntl, struct, termios
        rows, cols = (int(v) for v in os.environ['PTY_SIZE'].split('x'))
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    os.environ['TERM'] = 'xterm'
    os.environ['LC_ALL'] = 'C.UTF-8'
    out = os.open(os.environ['OUTFILE'], os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    if out != 3:
        os.dup2(out, 3)
    os.set_inheritable(3, True)
    os.execvp('dialog', ['dialog', '--output-fd', '3'] + args)
def drain(t):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                os.read(fd, 65536)
            except OSError:
                return
drain(1.0)
for k in keys:
    os.write(fd, k)
    drain(0.3)
drain(0.5)
_, st = os.waitpid(pid, 0)
print(os.waitstatus_to_exitcode(st))
EOF
set --
while IFS= read -r l; do set -- "$@" "$l"; done <"$T/items"
OPTS="--no-tags --separate-output --help-button --help-label Details --help-status --extra-button --extra-label All/None --cancel-label Menu"
# shellcheck disable=SC2086
RC=$(OUTFILE=$T/dlg.out python3 "$T/run-dialog.py" '\r' $OPTS --checklist "$T_LIST_TEXT" 23 78 15 "$@")
eq "real dialog accepts the checklist (Enter -> exit 0)" "$RC" 0
eq "real dialog returns the preselected tags" "$(tr '\n' ' ' <"$T/dlg.out")" "$(awk -F '\t' '$10 == 1 { printf "%s ", $1 }' "$S")"
# shellcheck disable=SC2086
RC=$(OUTFILE=$T/dlg.out python3 "$T/run-dialog.py" '\x1bOB| |\t|\t|\t|\r' $OPTS --checklist "$T_LIST_TEXT" 23 78 15 "$@")
eq "real dialog: Details button exit status" "$RC" 2
eq "real dialog: Details output starts with HELP <highlighted tag>" "$(head -n 1 "$T/dlg.out")" "HELP g0002"
eq "real dialog: Details output then lists the ticked tags (g0002 unticked by space)" "$(sed 1d "$T/dlg.out" | tr '\n' ' ')" "$(awk -F '\t' '$10 == 1 && $1 != "g0002" { printf "%s ", $1 }' "$S")"
# The same with the sizes ui_geometry gives on 80x24 and on a 100x37 framebuffer console.
# shellcheck disable=SC2086
RC=$(PTY_SIZE=24x80 OUTFILE=$T/dlg.out python3 "$T/run-dialog.py" '\r' $OPTS --checklist "$T_LIST_TEXT" 22 76 14 "$@")
eq "real dialog on 80x24 with the ui_geometry sizes" "$RC $(tr '\n' ' ' <"$T/dlg.out")" "0 $(awk -F '\t' '$10 == 1 { printf "%s ", $1 }' "$S")"
set --
while IFS= read -r l; do set -- "$@" "$l"; done <"$T/items3"
# shellcheck disable=SC2086
RC=$(PTY_SIZE=37x100 OUTFILE=$T/dlg.out python3 "$T/run-dialog.py" '\r' $OPTS --checklist "$T_LIST_TEXT" 35 96 27 "$@")
eq "real dialog on 100x37 with the ui_geometry sizes" "$RC $(tr '\n' ' ' <"$T/dlg.out")" "0 $(awk -F '\t' '$10 == 1 { printf "%s ", $1 }' "$S")"

# UI flow with the stub: scan gauge, then details, all/none, select, net destination,
# confirm, copy gauge, summary -> power off (disabled).
STUB_DIR="$T/stub" DIALOG="$SRC/test/dialog-stub.sh" RETRO_NO_POWER=1 RETRO_PROBE_SECONDS=1
export STUB_DIR DIALOG RETRO_NO_POWER RETRO_PROBE_SECONDS
mkdir -p "$STUB_DIR"
sh "$RETRO_HOME/30-ui.sh" scan >/dev/null 2>"$T/ui-scan.err"
eq "UI scan gauge exit status" "$?" 0
check "UI scan gauge got progress lines" grep -q '^XXX' "$STUB_DIR/gauge.1"
G1=$(gid /dev/sda1 "$J/My Documents")
G2=$(gid /dev/sda1 Munka)
G3=$(gid /dev/sdc1 home/milan/.thunderbird)
{
	printf 'checklist\t2\tHELP %s\\n%s\\n%s\n' "$G2" "$G2" "$G3"
	printf 'checklist\t3\t\n'
	printf 'checklist\t0\t%s\\n%s\\n%s\n' "$G1" "$G2" "$G3"
	printf 'menu\t0\tnet\n'
	printf 'yesno\t0\t\n'
	printf 'menu\t0\tpoweroff\n'
} >"$STUB_DIR/queue"
printf 'retro.dest=%s\n' "$URL" >"$RETRO_CMDLINE"
rm -rf "$T/helper/BACKUP"
sh "$RETRO_HOME/30-ui.sh" main >"$T/ui.out" 2>"$T/ui.err"
eq "UI main flow ends with power off" "$(tail -n 1 "$T/ui.out")" "would poweroff"
check "stub saw no unexpected screen" test ! -s "$STUB_DIR/errors"
eq "UI wrote selection.txt" "$(tr '\n' ' ' <"$RETRO_RUN/selection.txt")" "$G1 $G2 $G3 "
eq "UI wrote dest.conf" "$(tr '\n' ' ' <"$RETRO_RUN/dest.conf")" "type=net url=$URL "
eq "copy from the UI: no failures" "$(sed -n 's/^failed=//p' "$RETRO_RUN/copy.result")" 0
check "details screen listed the largest files" grep -q 'Largest files' "$STUB_DIR"/textbox.*
calls_of() { awk -v b="$1" '$2 == b { print $1 }' "$STUB_DIR/calls"; }
C2=$(calls_of checklist | sed -n 2p)
tr '\0' '\n' <"$STUB_DIR/call.$C2" >"$T/c2"
check "after Details the cursor stays on the group" grep -qx -- "$G2" "$T/c2"
check "after Details the ticks come from --help-status" sh -c "grep -A2 -x -- '$G3' '$T/c2' | sed -n 3p | grep -qx on && grep -A2 -x -- '$G1' '$T/c2' | sed -n 3p | grep -qx off"
C3=$(calls_of checklist | sed -n 3p)
eq "All/None ticks everything" "$(tr '\0' '\n' <"$STUB_DIR/call.$C3" | grep -cx off)" 0
GA=$(calls_of gauge | tail -n 1)
check "copy gauge reached 100%" grep -qx 100 "$STUB_DIR/gauge.$GA"
check "files arrived at the helper through the UI" test -s "$T/helper/BACKUP/$M/sdc1/home/milan/.thunderbird/xyz.default/prefs.js"
: >"$RETRO_CMDLINE"

# --------------------------------------------------------------------------- big (optional)
if [ "${RETRO_TEST_BIG:-0}" = 1 ]; then
	section "big: 1 million files in 55 000 directories"
	python3 -c "
import os
exts = ['jpg', 'doc', 'mp3', 'dll', 'txt', 'avi']
for a in range(5000):
    for b in range(10):
        d = '$T/big/vol/Archívum %04d/sub%02d' % (a, b)
        os.makedirs(d)
        for c in range(20):
            open('%s/f%03d.%s' % (d, c, exts[(a * 10 + b) % 6]), 'w').close()
"
	mkdir -p "$T/big/run"
	printf '/dev/sdz1\text4\tBIG\t1\t%s\tdata\n' "$T/big/vol" >"$T/big/run/volumes.tsv"
	_t0=$(date +%s)
	RETRO_RUN=$T/big/run sh "$RETRO_HOME/20-scan.sh" >/dev/null 2>&1 &
	_pid=$!
	_max=0
	while kill -0 $_pid 2>/dev/null; do
		for _p in $(pgrep gawk); do
			_h=$(awk '/VmHWM/ { print $2 }' "/proc/$_p/status" 2>/dev/null)
			[ -n "$_h" ] && [ "$_h" -gt $_max ] && _max=$_h
		done
		sleep 0.2
	done
	echo "  scan took $(($(date +%s) - _t0)) s, gawk peak RSS $_max kB"
	if [ "$_max" -lt 65536 ]; then ok "gawk stays under 64 MB"; else fail "gawk peak $_max kB"; fi
	eq "group cap: 5000 top folders" "$(grep -c '' "$T/big/run/scan.tsv")" 5000
	rm -rf "$T/big"
fi

# --------------------------------------------------------------------------- done
PASS=$(grep -c "^ok" "$T/tally" 2>/dev/null || echo 0)
FAIL=$(grep -c "^fail" "$T/tally" 2>/dev/null || echo 0)
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
