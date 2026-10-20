#!/bin/sh
# 50-net.sh: network helpers for the "net" destination (PLAN.md 10.3, CONTRACTS.md section 4).
# Sourced by 30-ui.sh and 40-copy.sh; also a small CLI for tests:
#   50-net.sh up | discover | status URL | free URL | probe URL [SECONDS]
#   50-net.sh resume URL MACHINE VOLUME GROUP | log URL MACHINE FILE
# Plain HTTP on the LAN, no TLS, no compression (CPU bound on old machines).
# shellcheck source=lib/common.sh
. "${RETRO_HOME:-/opt/retro}/lib/common.sh"

NET_SYS=${RETRO_SYS_NET:-/sys/class/net}
BEACON_PORT=9999

# net_ifaces: wired interfaces (eth*, en*).
net_ifaces() {
	for _i in "$NET_SYS"/eth* "$NET_SYS"/en*; do
		[ -e "$_i" ] && printf '%s\n' "${_i##*/}"
	done
	return 0
}

# net_addr IFACE: its IPv4 address (busybox and net-tools ifconfig formats).
net_addr() {
	ifconfig "$1" 2>/dev/null | sed -n -e 's/.*inet addr:\([0-9.]*\).*/\1/p' \
		-e 's/.*inet \([0-9.]*\) .*/\1/p' | head -n 1
}

# net_has_addr: some wired interface has an IPv4 address.
net_has_addr() {
	for _i in $(net_ifaces); do
		[ -n "$(net_addr "$_i")" ] && return 0
	done
	return 1
}

# net_up: bring up the wired interfaces with busybox udhcpc unless one already has an address.
net_up() {
	if net_has_addr; then
		log DEBUG "net: already configured"
		return 0
	fi
	for _i in $(net_ifaces); do
		ifconfig "$_i" up 2>/dev/null
		log INFO "net: DHCP on $_i"
		if udhcpc -i "$_i" -n -q -t 4 -T 3 >>"$RETRO_RUN/net.err" 2>&1; then
			log INFO "net: $_i has address $(net_addr "$_i")"
			return 0
		fi
		log WARN "net: no DHCP answer on $_i"
	done
	log ERROR "net: no network address (cable plugged in? DHCP server or helper in direct-cable mode?)"
	return 1
}

# net_beacon: broadcast RETRO-HELPER? to UDP 9999 and print the helper URL from the answer.
# Uses socat when present, else two busybox nc processes sharing a local port (one sends the
# broadcast from that port, one listens on it for the unicast answer). Fails quietly when
# neither works; the user can then type the address.
net_beacon() {
	_bf=$RETRO_RUN/beacon.reply
	: >"$_bf"
	if have socat; then
		printf 'RETRO-HELPER?' | timeout 4 socat -T 3 - \
			"UDP-DATAGRAM:255.255.255.255:$BEACON_PORT,broadcast" >"$_bf" 2>/dev/null
	elif have nc; then
		_bport=$((40000 + $$ % 20000))
		timeout 4 nc -u -l -p "$_bport" >"$_bf" 2>/dev/null &
		_bl=$!
		sleep 1
		printf 'RETRO-HELPER?' | timeout 2 nc -u -b -w 1 -p "$_bport" 255.255.255.255 \
			"$BEACON_PORT" >/dev/null 2>&1
		wait "$_bl" 2>/dev/null
	else
		return 1
	fi
	_bu=$(tr -d '\r' <"$_bf" | sed -n 's/^RETRO-HELPER \(http[^ ]*\).*/\1/p' | head -n 1)
	[ -n "$_bu" ] || return 1
	printf '%s\n' "${_bu%/}"
}

# net_status URL: the URL answers like a retro-helper.
net_status() {
	curl -sS -m 5 "$1/status" 2>/dev/null | grep -q '"retro-helper"'
}

# net_json: flatten JSON on stdin (lib/json.awk).
net_json() {
	LC_ALL=C gawk -f "$RETRO_LIB/json.awk"
}

# net_free URL: free bytes on the helper's destination.
net_free() {
	curl -sS -m 10 "$1/free" 2>/dev/null | net_json | awk -F '\t' '$1 == "free_bytes" { print $2; exit }'
}

# net_discover: helper URL from retro.dest= or the beacon; checks that it answers.
net_discover() {
	_nu=$(retro_param retro.dest "")
	if [ -n "$_nu" ]; then
		_nu=${_nu%/}
		log INFO "net: helper from the kernel command line: $_nu"
	else
		_nu=$(net_beacon) || _nu=
		[ -n "$_nu" ] && log INFO "net: helper answered the beacon: $_nu"
	fi
	[ -n "$_nu" ] || return 1
	if net_status "$_nu"; then
		printf '%s\n' "$_nu"
		return 0
	fi
	log WARN "net: $_nu does not answer /status"
	return 1
}

# net_probe URL [SECONDS]: upload junk to the helper's probe sink for SECONDS (default 10)
# and print the throughput in bytes per second (0 on failure).
net_probe() {
	_pd=$RETRO_RUN/probe.d
	rm -rf "$_pd"
	mkdir -p "$_pd"
	# A sparse 4 GiB file: costs no RAM in tmpfs, reads as zeros; one valid tar member.
	dd of="$_pd/_probe.bin" bs=1048576 seek=4096 count=0 2>/dev/null
	_pr=$(cd "$_pd" && tar -cf - _probe.bin 2>/dev/null |
		curl -s -m "${2:-10}" -X POST -T - -H 'Content-Type: application/x-tar' -o /dev/null \
			-w '%{size_upload} %{time_total}' \
			"$1/upload?machine=_probe&volume=_probe&group=_probe" 2>/dev/null)
	rm -rf "$_pd"
	printf '%s\n' "$_pr" | awk '{ if ($2 > 0) printf "%.0f\n", $1 / $2; else print 0 }'
}

# net_resume URL MACHINE VOLUME GROUP: files the helper already has, "path\tsize\tmd5".
net_resume() {
	curl -sS -f -m 30 "$1/resume?machine=$2&volume=$3&group=$4" 2>/dev/null | net_json |
		awk -F '\t' '
			$1 ~ /^files\.[0-9]+\./ {
				k = $1; sub(/^files\./, "", k); i = k; sub(/\..*$/, "", i); f = k; sub(/^[0-9]+\./, "", f)
				if (i != cur) { flush(); cur = i }
				V[f] = $2
			}
			function flush() { if (V["path"] != "") printf "%s\t%s\t%s\n", V["path"], V["size"], V["md5"]; delete V }
			END { flush() }'
}

# net_post_log URL MACHINE FILE: append FILE to BACKUP/<machine>/retro-backup.log.
net_post_log() {
	curl -sS -f -m 60 -X POST -H 'Content-Type: text/plain; charset=utf-8' --data-binary "@$3" \
		"$1/log?machine=$2" >/dev/null 2>>"$RETRO_RUN/net.err"
}

net_cli() {
	_cmd=${1:-}
	[ $# -gt 0 ] && shift
	case $_cmd in
	up) net_up ;;
	discover) net_discover ;;
	beacon) net_beacon ;;
	status) net_status "$1" && echo ok ;;
	free) net_free "$1" ;;
	probe) net_probe "$1" "${2:-10}" ;;
	resume) net_resume "$1" "$2" "$3" "$4" ;;
	log) net_post_log "$1" "$2" "$3" ;;
	*)
		echo "usage: ${0##*/} up|discover|beacon|status URL|free URL|probe URL [S]|resume URL M V G|log URL M FILE" >&2
		return 2
		;;
	esac
}

# Run only when executed, not when sourced by another script or a test.
case ${0##*/} in
50-net.sh) net_cli "$@" ;;
esac
