#!/bin/sh
# retro-main.sh: entry point on tty1 (started by inittab, respawned when it exits).
# Loop: 10-devices.sh -> 30-ui.sh scan (runs 20-scan.sh) -> 30-ui.sh main (checklist,
# destination, copy, summary). A failing step shows an error screen with retry / shell /
# power off. Safe to respawn: mounts are reused, a second instance waits for the first.
TERM=linux
export TERM
# shellcheck source=lib/common.sh
. "${RETRO_HOME:-/opt/retro}/lib/common.sh"

DIALOG=${DIALOG:-dialog}
UI_LOCALE=${RETRO_UI_LOCALE:-C.UTF-8}
LOCK=$RETRO_RUN/main.pid
ui_geometry

dlg() {
	LC_ALL=$UI_LOCALE "$DIALOG" --backtitle "$T_BACKTITLE" --cr-wrap --stdout "$@"
}

shell() {
	clear
	printf '%s\n' "$T_SHELL_HINT"
	/bin/sh -i
}

# step_failed STEP: error screen; returns when the user wants to retry.
step_failed() {
	log ERROR "main: step '$1' failed"
	while :; do
		_c=$(dlg --title "$T_ERROR_TITLE" --no-tags --menu "$T_ERROR_STEP $1\n\n$(tail -n 3 "$RETRO_LOG" 2>/dev/null)" \
			18 "$UI_W_BIG" 5 retry "$T_ERROR_RETRY" log "$T_MENU_LOG" shell "$T_MENU_SHELL" \
			poweroff "$T_MENU_POWEROFF" reboot "$T_MENU_REBOOT")
		case $_c in
		retry | "") return 0 ;;
		log) dlg --title "$T_MENU_LOG" --textbox "$RETRO_LOG" "$UI_H_BIG" "$UI_W_BIG" ;;
		shell) shell ;;
		poweroff | reboot)
			sync
			"$_c"
			sleep 30
			;;
		esac
	done
}

# no_volumes: nothing to scan; offer rescan, shell, power off.
no_volumes() {
	dlg --title "$T_ERROR_TITLE" --msgbox "$T_NO_VOLUMES" 14 "$UI_W_MED"
	step_failed devices
}

main() {
	mkdir -p "$RETRO_RUN" || exit 1
	if [ -s "$LOCK" ] && kill -0 "$(cat "$LOCK")" 2>/dev/null && [ "$(cat "$LOCK")" != $$ ]; then
		printf 'retro-backup is already running (pid %s); this console waits.\n' "$(cat "$LOCK")"
		sleep 10
		exit 0
	fi
	echo $$ >"$LOCK"
	trap 'rm -f "$LOCK"' EXIT
	trap 'exit 130' INT TERM HUP
	log INFO "main: start on $(tty 2>/dev/null), boot=$(retro_param retro.boot unknown), dest=$(retro_param retro.dest none)"
	while :; do
		if [ ! -f "$RETRO_RUN/stick.done" ]; then
			dlg --infobox "$T_STICK_WAIT" 5 "$UI_W_MED"
			sh "$RETRO_HOME/05-stick.sh" 2>>"$RETRO_RUN/stick.err" || log WARN "main: 05-stick.sh exited with $?"
			: >"$RETRO_RUN/stick.done"
		fi
		dlg --infobox "$T_DEVICES_WAIT" 5 "$UI_W_MED"
		if ! sh "$RETRO_HOME/10-devices.sh" 2>>"$RETRO_RUN/devices.err"; then
			step_failed devices
			continue
		fi
		if [ ! -s "$RETRO_RUN/volumes.tsv" ]; then
			no_volumes
			continue
		fi
		if ! sh "$RETRO_HOME/30-ui.sh" scan; then
			step_failed scan
			continue
		fi
		sh "$RETRO_HOME/30-ui.sh" main
		_rc=$?
		[ $_rc = 2 ] && continue
		[ $_rc = 0 ] || step_failed ui
	done
}

main "$@"
