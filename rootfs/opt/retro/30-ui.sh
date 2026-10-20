#!/bin/sh
# 30-ui.sh: the dialog screens (PLAN.md 6.2).
#   30-ui.sh scan   scanning gauge (runs 20-scan.sh)
#   30-ui.sh main   overview checklist -> details / menu -> destination -> confirm (with a
#                   10 s speed probe) -> copy gauge (40-copy.sh) -> summary
# Writes selection.txt and dest.conf (CONTRACTS.md section 2). Esc on any screen asks, then
# opens a shell; "exit" returns to the screen. DIALOG overrides the dialog binary (tests).
# shellcheck source=lib/common.sh
. "${RETRO_HOME:-/opt/retro}/lib/common.sh"
# shellcheck source=50-net.sh
. "$RETRO_HOME/50-net.sh"
# shellcheck source=40-copy.sh
. "$RETRO_HOME/40-copy.sh"

DIALOG=${DIALOG:-dialog}
UI_LOCALE=${RETRO_UI_LOCALE:-C.UTF-8}
UI_TMP=$RETRO_RUN/ui.tmp
CHECKED=$RETRO_RUN/ui.checked
mkdir -p "$UI_TMP"
ui_geometry

# dlg ARGS...: dialog with the common options; result on stdout, exit status kept.
dlg() {
	LC_ALL=$UI_LOCALE "$DIALOG" --backtitle "$T_BACKTITLE" --cr-wrap --stdout "$@"
}

# ui_escape: after Esc, offer a shell; returns when the user comes back.
ui_escape() {
	if dlg --title "$T_ESC_TITLE" --yesno "$T_ESC_TEXT" 9 "$UI_W_MED"; then
		clear
		printf '%s\n' "$T_SHELL_HINT"
		log INFO "ui: user opened a shell"
		/bin/sh -i
		log INFO "ui: user left the shell"
	fi
	return 0
}

ui_msg() { # ui_msg TITLE TEXT
	dlg --title "$1" --msgbox "$2" 12 "$UI_W_MED"
	[ $? = 255 ] && ui_escape
	return 0
}

# --------------------------------------------------------------------------- scanning

# ui_scan_progress PID: gauge lines from scan.progress while PID runs.
ui_scan_progress() {
	_nv=$(grep -c '' "$RETRO_RUN/volumes.tsv" 2>/dev/null)
	[ "${_nv:-0}" -gt 0 ] || _nv=1
	while kill -0 "$1" 2>/dev/null; do
		_last=$(tail -n 1 "$RETRO_RUN/scan.progress" 2>/dev/null)
		_dev=${_last%%"$TAB"*}
		_p=${_last##*"$TAB"}
		case $_p in '' | *[!0-9]*) _p=0 ;; esac
		_idx=$(awk -F '\t' -v d="$_dev" '$1 == d { print NR; exit }' "$RETRO_RUN/volumes.tsv" 2>/dev/null)
		[ -n "$_idx" ] || _idx=1
		_lab=$(vol_field "$_dev" 3 2>/dev/null)
		printf 'XXX\n%d\n%s %s %s\n(%s/%s)\nXXX\n' $((((_idx - 1) * 100 + _p) / _nv)) \
			"$T_SCAN_VOLUME" "${_dev:-...}" "$([ "${_lab:--}" != - ] && printf '(%s)' "$_lab")" "$_idx" "$_nv"
		sleep 1
	done
	printf 'XXX\n100\n%s\nXXX\n' "$T_SCAN_VOLUME"
}

ui_scan() {
	: >"$RETRO_RUN/scan.progress"
	sh "$RETRO_HOME/20-scan.sh" >/dev/null 2>>"$RETRO_RUN/scan.err" &
	_sp=$!
	ui_scan_progress "$_sp" | dlg --title "$T_SCAN_TITLE" --gauge "$T_SCAN_START" 9 "$UI_W_MED" 0
	wait "$_sp"
	_rc=$?
	rm -f "$CHECKED"
	return $_rc
}

# --------------------------------------------------------------------------- overview

# ui_checklist_items SCAN CHECKED: dialog --checklist items (tag, text, on|off), one per
# line. CHECKED lists ticked group ids; when it does not exist the preselect column decides.
# The name column is 32 wide on 80 columns and takes the extra width of a bigger screen.
ui_checklist_items() {
	_ck=$2
	[ -e "$_ck" ] || _ck=/dev/null
	LC_ALL=$UI_LOCALE gawk -F '\t' -v use_pre="$([ -e "$2" ] && echo 0 || echo 1)" \
		-v cats="$T_CATEGORIES" -v namew="$((32 + ${UI_W_BIG:-76} - 76))" '
		function human(n,    u, i) {
			split("B KB MB GB TB", u, " "); i = 1
			while (n >= 1024 && i < 5) { n /= 1024; i++ }
			if (i == 1) return sprintf("%d %s", n, u[i])
			return sprintf(n < 10 ? "%.1f %s" : "%.0f %s", n, u[i])
		}
		function fit(s, w) { return length(s) <= w ? s : substr(s, 1, w - 1) "~" }
		BEGIN { fmt = "%-5s %-" namew "s %-9s %6d %8s"; n = split(cats, c, " "); for (i = 1; i <= n; i++) { split(c[i], kv, ":"); CN[kv[1]] = kv[2] } }
		FILENAME == ARGV[1] { ON[$1] = 1; next }
		NF >= 10 {
			dev = $2; sub(/^.*\//, "", dev)
			cat = ($4 in CN) ? CN[$4] : $4
			text = sprintf(fmt, fit(dev, 5), fit($6, namew), fit(cat, 9), $8, human($9))
			on = use_pre ? ($10 == 1) : ($1 in ON)
			print $1; print text; print (on ? "on" : "off")
		}' "$_ck" "$1"
}

# ui_set_checked FILE: replace the ticked set.
ui_set_checked() {
	grep '^g[0-9]' "$1" >"$CHECKED.new" 2>/dev/null
	mv -f "$CHECKED.new" "$CHECKED"
}

# ui_details GROUP: the 20 largest files of a group.
ui_details() {
	_row=$(tsv_lookup "$RETRO_RUN/scan.tsv" 1 "$1")
	[ -n "$_row" ] || return 0
	_mnt=$(vol_field "$(tsv_field "$_row" 2)" 5)
	_path=$(tsv_field "$_row" 7)
	{
		printf '%s\n\n' "$(tsv_field "$_row" 6)"
		printf '%s: %s\n' "$T_DETAILS_PATH" "$(tsv_field "$_row" 2):/$_path"
		printf '%s: %s    %s: %s\n\n' "$T_DETAILS_FILES" "$(tsv_field "$_row" 8)" "$T_DETAILS_SIZE" \
			"$(human_bytes "$(tsv_field "$_row" 9)")"
		printf '%s:\n' "$T_DETAILS_TOP"
		eval "find $(shquote "$_mnt/$_path") -xdev $(prunes "$_mnt" "$(vol_field "$(tsv_field "$_row" 2)" 6)" a) \
			-type f -printf '%s\\t%P\\n'" 2>/dev/null | LC_ALL=C awk -F '\t' '
			{
				if (n < 20) { n++; S[n] = $1 + 0; P[n] = $2; next }
				m = 1; for (i = 2; i <= n; i++) if (S[i] < S[m]) m = i
				if ($1 + 0 > S[m]) { S[m] = $1 + 0; P[m] = $2 }
			}
			END {
				for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
					if (S[j] > S[i]) { t = S[i]; S[i] = S[j]; S[j] = t; t = P[i]; P[i] = P[j]; P[j] = t }
				for (i = 1; i <= n; i++) printf "%10.1f KB  %s\n", S[i] / 1024, (P[i] == "" ? "(this file)" : P[i])
			}'
	} >"$UI_TMP/details"
	dlg --title "$T_DETAILS_TITLE" --exit-label OK --textbox "$UI_TMP/details" "$UI_H_BIG" "$UI_W_BIG"
	[ $? = 255 ] && ui_escape
	return 0
}

# ui_menu: the Cancel button of the overview. Returns 0 to go back, 2 to rescan.
ui_menu() {
	_c=$(dlg --title "$T_MENU_TITLE" --no-tags --menu "" 14 "$UI_W_MED" 6 \
		back "$T_MENU_BACK" rescan "$T_MENU_RESCAN" shell "$T_MENU_SHELL" log "$T_MENU_LOG" \
		poweroff "$T_MENU_POWEROFF" reboot "$T_MENU_REBOOT")
	_rc=$?
	[ $_rc = 255 ] && { ui_escape; return 0; }
	case $_c in
	rescan) return 2 ;;
	shell)
		clear
		printf '%s\n' "$T_SHELL_HINT"
		/bin/sh -i
		;;
	log) dlg --title "$T_MENU_LOG" --textbox "$RETRO_LOG" "$UI_H_BIG" "$UI_W_BIG" ;;
	poweroff | reboot) ui_power "$_c" ;;
	esac
	return 0
}

# ui_power poweroff|reboot: flush and unmount the destination first.
ui_power() {
	sync
	is_mountpoint "$RETRO_DST" && umount "$RETRO_DST" 2>/dev/null
	log INFO "ui: $1"
	sync
	if [ "${RETRO_NO_POWER:-0}" = 1 ]; then
		echo "would $1"
		exit 0
	fi
	"$1"
	sleep 30
}

# ui_overview: the checklist loop. Returns 0 with selection.txt written, 2 for a rescan.
ui_overview() {
	while :; do
		if [ ! -s "$RETRO_RUN/scan.tsv" ]; then
			ui_msg "$T_LIST_TITLE" "$T_NO_GROUPS"
			ui_menu
			[ $? = 2 ] && return 2
			continue
		fi
		ui_checklist_items "$RETRO_RUN/scan.tsv" "$CHECKED" >"$UI_TMP/items"
		set --
		while IFS= read -r _it; do set -- "$@" "$_it"; done <"$UI_TMP/items"
		_out=$(dlg --title "$T_LIST_TITLE" --no-tags --separate-output --help-button \
			--help-label "$T_LIST_DETAILS" --help-status --extra-button --extra-label "$T_LIST_ALL" \
			--ok-label "$T_LIST_OK" --cancel-label "$T_LIST_MENU" ${UI_DEFAULT:+--default-item "$UI_DEFAULT"} \
			--checklist "$T_LIST_TEXT" "$UI_H_BIG" "$UI_W_BIG" "$UI_L_BIG" "$@")
		_rc=$?
		printf '%s\n' "$_out" >"$UI_TMP/out"
		case $_rc in
		0)
			ui_set_checked "$UI_TMP/out"
			if [ ! -s "$CHECKED" ]; then
				ui_msg "$T_LIST_TITLE" "$T_LIST_EMPTY"
				continue
			fi
			cp "$CHECKED" "$RETRO_RUN/selection.txt"
			log INFO "ui: selected $(tr '\n' ' ' <"$CHECKED")"
			return 0
			;;
		2)
			# "HELP <tag>" first, then the ticked items (--help-status).
			UI_DEFAULT=$(sed -n 's/^HELP //p' "$UI_TMP/out" | head -n 1)
			grep -v '^HELP ' "$UI_TMP/out" >"$UI_TMP/out2"
			ui_set_checked "$UI_TMP/out2"
			ui_details "$UI_DEFAULT"
			;;
		3)
			_all=$(grep -c '' "$UI_TMP/items")
			if [ "$(grep -c '^g' "$UI_TMP/out")" -ge $((_all / 3)) ]; then
				: >"$CHECKED"
			else
				awk 'NR % 3 == 1' "$UI_TMP/items" >"$CHECKED"
			fi
			;;
		1)
			ui_set_checked "$UI_TMP/out"
			ui_menu
			[ $? = 2 ] && return 2
			;;
		*) ui_escape ;;
		esac
	done
}

# --------------------------------------------------------------------------- destination

# blk_label_dev LABEL: device holding a file system with LABEL.
blk_label_dev() {
	blkid -c /dev/null -t "LABEL=$1" -o device 2>/dev/null | head -n 1
}

# free_bytes DIR
free_bytes() {
	df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

# mount_rw DEV: mount a destination read-write at RETRO_DST.
mount_rw() {
	mkdir -p "$RETRO_DST"
	is_mountpoint "$RETRO_DST" && umount "$RETRO_DST" 2>/dev/null
	_t=$(blkid -c /dev/null -o value -s TYPE "$1" 2>/dev/null)
	: >"$UI_TMP/mount.err"
	have blockdev && blockdev --setrw "$1" 2>/dev/null
	case $_t in
	exfat) mount -t exfat -o rw,iocharset=utf8 "$1" "$RETRO_DST" 2>>"$UI_TMP/mount.err" ;;
	vfat) mount -t vfat -o rw,utf8,shortname=mixed "$1" "$RETRO_DST" 2>>"$UI_TMP/mount.err" ;;
	ntfs)
		mount -t ntfs3 -o rw,iocharset=utf8 "$1" "$RETRO_DST" 2>>"$UI_TMP/mount.err" ||
			ntfs-3g "$1" "$RETRO_DST" 2>>"$UI_TMP/mount.err"
		;;
	*) mount -t "$_t" -o rw "$1" "$RETRO_DST" 2>>"$UI_TMP/mount.err" ;;
	esac
	_rc=$?
	if [ $_rc = 0 ]; then
		log INFO "ui: destination $1 ($_t) mounted read-write at $RETRO_DST"
	else
		log ERROR "ui: cannot mount $1 ($_t) read-write: $(tail -n 1 "$UI_TMP/mount.err")"
	fi
	return $_rc
}

# dest_candidates: "dev\tsize\ttype\tlabel" of partitions that are neither sources nor ours.
dest_candidates() {
	for _b in /sys/class/block/*; do
		_n=${_b##*/}
		case $_n in
		sd* | hd* | nvme* | mmcblk* | vd*) ;;
		*) continue ;;
		esac
		_dev=/dev/$_n
		awk -F '\t' -v d="$_dev" '$1 == d { f = 1 } END { exit !f }' "$RETRO_RUN/volumes.tsv" && continue
		_t=$(blkid -c /dev/null -o value -s TYPE "$_dev" 2>/dev/null)
		case $_t in '' | swap | linux_raid_member | LVM2_member | crypto_LUKS | BitLocker) continue ;; esac
		_l=$(blkid -c /dev/null -o value -s LABEL "$_dev" 2>/dev/null)
		case $_l in RETROBOOT | RETRODATA) continue ;; esac
		_s=$(awk '{ printf "%.0f", $1 * 512 }' "$_b/size" 2>/dev/null)
		printf '%s\t%s\t%s\t%s\n' "$_dev" "$(human_bytes "${_s:-0}")" "$_t" "${_l:--}"
	done
}

ui_dest_disk() {
	ui_msg "$T_DEST_TITLE" "$T_DEST_PLUG"
	while :; do
		dest_candidates >"$UI_TMP/cands"
		set --
		while IFS="$TAB" read -r _d _s _t _l; do
			set -- "$@" "$_d" "$(printf '%-12s %9s  %-6s %s' "$_d" "$_s" "$_t" "$_l")"
		done <"$UI_TMP/cands"
		set -- "$@" refresh "$T_DEST_REFRESH"
		_c=$(dlg --title "$T_DEST_TITLE" --no-tags --menu "$T_DEST_PICK" "$UI_H_MED" "$UI_W_BIG" "$UI_L_MED" "$@")
		_rc=$?
		[ $_rc = 255 ] && { ui_escape; continue; }
		[ $_rc = 0 ] || return 1
		if [ "$_c" = refresh ]; then
			[ -s "$UI_TMP/cands" ] || ui_msg "$T_DEST_TITLE" "$T_DEST_NONE"
			continue
		fi
		if mount_rw "$_c"; then
			printf 'type=disk\npath=%s\ndev=%s\n' "$RETRO_DST" "$_c" >"$RETRO_RUN/dest.conf"
			return 0
		fi
		ui_msg "$T_DEST_TITLE" "$T_DEST_MOUNT_FAILED $_c\n$(tail -n 1 "$UI_TMP/mount.err")\n\n$T_DEST_NTFS_HINT"
	done
}

# normalize_url TEXT: "1.2.3.4" -> http://1.2.3.4:8080
normalize_url() {
	_u=$(printf '%s' "$1" | tr -d ' ')
	case $_u in http://*) ;; *) _u=http://$_u ;; esac
	case ${_u#http://} in *:*) ;; *) _u=$_u:8080 ;; esac
	printf '%s\n' "${_u%/}"
}

ui_dest_net() {
	dlg --title "$T_DEST_TITLE" --infobox "$T_NET_WAIT" 5 "$UI_W_MED"
	if ! net_up; then
		ui_msg "$T_DEST_TITLE" "$T_NET_NOADDR"
	fi
	_url=$(net_discover) || _url=
	while [ -z "$_url" ]; do
		_in=$(dlg --title "$T_DEST_TITLE" --inputbox "$T_NET_ASK" 12 "$UI_W_MED" "")
		_rc=$?
		[ $_rc = 255 ] && { ui_escape; continue; }
		[ $_rc = 0 ] || return 1
		[ -n "$_in" ] || continue
		_try=$(normalize_url "$_in")
		if net_status "$_try"; then
			_url=$_try
			log INFO "net: helper typed by the user: $_url"
		else
			ui_msg "$T_DEST_TITLE" "$T_NET_BAD $_try"
		fi
	done
	printf 'type=net\nurl=%s\n' "$_url" >"$RETRO_RUN/dest.conf"
	return 0
}

# ui_dest: returns 0 with dest.conf written, 1 to go back to the list.
ui_dest() {
	while :; do
		set --
		_rd=$(blk_label_dev RETRODATA)
		[ -n "$_rd" ] && set -- usb "$T_DEST_RETRODATA"
		set -- "$@" disk "$T_DEST_DISK" net "$T_DEST_NET" back "$T_DEST_BACK"
		_c=$(dlg --title "$T_DEST_TITLE" --no-tags --menu "$T_DEST_TEXT" 13 "$UI_W_MED" 4 "$@")
		_rc=$?
		[ $_rc = 255 ] && { ui_escape; continue; }
		[ $_rc = 0 ] || return 1
		case $_c in
		usb)
			if mount_rw "$_rd"; then
				printf 'type=usb\npath=%s\ndev=%s\n' "$RETRO_DST" "$_rd" >"$RETRO_RUN/dest.conf"
				return 0
			fi
			ui_msg "$T_DEST_TITLE" "$T_DEST_MOUNT_FAILED $_rd\n$(tail -n 1 "$UI_TMP/mount.err")"
			;;
		disk) ui_dest_disk && return 0 ;;
		net) ui_dest_net && return 0 ;;
		*) return 1 ;;
		esac
	done
}

# --------------------------------------------------------------------------- confirm

# confirm_text: the confirm screen text; also sets CONFIRM_FITS=0|1.
confirm_text() {
	selected_rows "$RETRO_RUN/scan.tsv" "$RETRO_RUN/selection.txt" >"$UI_TMP/rows"
	_n=$(grep -c '' "$UI_TMP/rows")
	_files=$(awk -F '\t' '{ s += $8 } END { printf "%.0f", s }' "$UI_TMP/rows")
	_bytes=$(awk -F '\t' '{ s += $9 } END { printf "%.0f", s }' "$UI_TMP/rows")
	if [ "$(dest_conf type)" = net ]; then
		_free=$(net_free "$(dest_conf url)")
		_speed=$(net_probe "$(dest_conf url)" "${RETRO_PROBE_SECONDS:-10}")
	else
		_free=$(free_bytes "$RETRO_DST")
		_speed=$(disk_probe "$RETRO_DST" "${RETRO_PROBE_SECONDS:-10}")
	fi
	CONFIRM_FITS=1
	if [ -n "$_free" ] && [ "$(awk -v a="$_bytes" -v b="$_free" 'BEGIN { print (a > b) }')" = 1 ]; then
		CONFIRM_FITS=0
	fi
	printf '%s: %s %s, %s %s, %s\n' "$T_CONFIRM_GROUPS" "$_n" "$T_CONFIRM_GROUPS_UNIT" "$_files" \
		"$T_CONFIRM_FILES" "$(human_bytes "$_bytes")"
	printf '%s: %s\n' "$T_CONFIRM_FREE" "$([ -n "$_free" ] && human_bytes "$_free" || echo "$T_CONFIRM_UNKNOWN")"
	if [ "${_speed:-0}" -gt 0 ] 2>/dev/null; then
		printf '%s: %s/s\n' "$T_CONFIRM_SPEED" "$(human_bytes "$_speed")"
		printf '%s: %s\n' "$T_CONFIRM_ETA" "$(human_duration "$(awk -v b="$_bytes" -v s="$_speed" 'BEGIN { print b / s }')")"
	else
		printf '%s: %s\n' "$T_CONFIRM_ETA" "$T_CONFIRM_UNKNOWN"
	fi
	[ "$(dest_conf type)" = net ] && printf '\n%s\n' "$T_NET_PLAIN"
	[ $CONFIRM_FITS = 0 ] && printf '\n%s\n' "$T_CONFIRM_NOSPACE"
	return 0
}

ui_confirm() {
	dlg --title "$T_CONFIRM_TITLE" --infobox "$T_CONFIRM_PROBE" 5 "$UI_W_MED"
	confirm_text >"$UI_TMP/confirm"
	log INFO "ui: confirm: $(tr '\n' ' ' <"$UI_TMP/confirm")"
	while :; do
		dlg --title "$T_CONFIRM_TITLE" --yes-label "$T_CONFIRM_START" --no-label "$T_CONFIRM_BACK" \
			--yesno "$(cat "$UI_TMP/confirm")" 14 "$UI_W_MED"
		case $? in
		0) return 0 ;;
		255) ui_escape ;;
		*) return 1 ;;
		esac
	done
}

# --------------------------------------------------------------------------- copy, summary

ui_copy() {
	log INFO "ui: copy started"
	RETRO_GAUGE=1 sh "$RETRO_HOME/40-copy.sh" 2>>"$RETRO_RUN/copy.err" |
		dlg --title "$T_COPY_TITLE" --gauge "$T_COPY_START" 10 "$UI_W_BIG" 0
	return 0
}

result() { sed -n "s/^$1=//p" "$RETRO_RUN/copy.result" 2>/dev/null | tail -n 1; }

summary_text() {
	printf '%s: %s %s, %s\n' "$T_SUM_COPIED" "$(result files)" "$T_CONFIRM_FILES" "$(human_bytes "$(result bytes)")"
	printf '%s: %s\n' "$T_SUM_FAILED" "$(result failed)"
	printf '%s: %s\n' "$T_SUM_RENAMED" "$(result renamed)"
	printf '%s: %s\n' "$T_SUM_SKIPPED" "$(result skipped)"
	[ "$(result mismatched)" != 0 ] && printf '%s: %s\n' "$T_SUM_MISMATCHED" "$(result mismatched)"
	printf '%s: %s\n' "$T_SUM_DEST" "$(result dest)"
	printf '%s: BACKUP/%s/retro-backup.log, MANIFEST.tsv\n' "$T_SUM_LOG" "$(result machine)"
	if [ "$(dest_conf type)" != net ]; then
		if [ "$(result unmounted)" = 1 ]; then printf '\n%s\n' "$T_SUM_SAFE"; else printf '\n%s\n' "$T_SUM_NOTSAFE"; fi
	fi
	return 0
}

# ui_summary: returns 0 for "copy more".
ui_summary() {
	summary_text >"$UI_TMP/summary"
	while :; do
		_c=$(dlg --title "$T_SUM_TITLE" --no-tags --cancel-label "$T_MENU_LOG" \
			--menu "$(cat "$UI_TMP/summary")" 22 "$UI_W_BIG" 4 more "$T_SUM_MORE" shell "$T_MENU_SHELL" \
			poweroff "$T_MENU_POWEROFF" reboot "$T_MENU_REBOOT")
		case $? in
		0) ;;
		1)
			dlg --title "$T_MENU_LOG" --textbox "$RETRO_LOG" "$UI_H_BIG" "$UI_W_BIG"
			continue
			;;
		*)
			ui_escape
			continue
			;;
		esac
		case $_c in
		more) return 0 ;;
		shell)
			clear
			printf '%s\n' "$T_SHELL_HINT"
			/bin/sh -i
			;;
		poweroff | reboot) ui_power "$_c" ;;
		esac
	done
}

ui_notes() {
	[ -s "$RETRO_RUN/devices.notes" ] || return 0
	ui_msg "$T_DEV_NOTES_TITLE" "$(cat "$RETRO_RUN/devices.notes")"
}

ui_main() {
	ui_notes
	while :; do
		ui_overview
		[ $? = 2 ] && return 2
		ui_dest || continue
		ui_confirm || continue
		ui_copy
		ui_summary
	done
}

# Run only when executed, not when sourced by another script or a test.
case ${0##*/} in
30-ui.sh)
	case ${1:-main} in
	scan) ui_scan ;;
	main) ui_main ;;
	*)
		echo "usage: ${0##*/} scan|main" >&2
		exit 2
		;;
	esac
	;;
esac
