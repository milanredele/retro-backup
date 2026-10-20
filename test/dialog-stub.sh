#!/bin/sh
# dialog-stub.sh: stand-in for dialog in UI tests (30-ui.sh honours $DIALOG).
# Every call's arguments are saved NUL-separated in $STUB_DIR/call.<n>, and its box type is
# appended to $STUB_DIR/calls. Gauges save their stdin in $STUB_DIR/gauge.<n>; textboxes
# copy the file to $STUB_DIR/textbox.<n>; infoboxes return 0. Every other box pops the next
# line of $STUB_DIR/queue ("box<TAB>exit-status<TAB>output", \n allowed in output) and
# fails with 99 when the box type differs from the scripted one.
D=${STUB_DIR:?}
n=$(($(cat "$D/n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$D/n"
printf '%s\0' "$@" >"$D/call.$n"
box=
prev=
for a in "$@"; do
	case $a in
	--checklist | --menu | --yesno | --msgbox | --infobox | --gauge | --inputbox | --textbox)
		box=${a#--}
		;;
	esac
	[ "$prev" = --textbox ] && cp "$a" "$D/textbox.$n" 2>/dev/null
	prev=$a
done
echo "$n $box" >>"$D/calls"
case $box in
gauge)
	cat >"$D/gauge.$n"
	exit 0
	;;
infobox | textbox) exit 0 ;;
esac
line=$(head -n 1 "$D/queue" 2>/dev/null)
sed -i '1d' "$D/queue" 2>/dev/null
TAB=$(printf '\t')
want=${line%%"$TAB"*}
rest=${line#*"$TAB"}
rc=${rest%%"$TAB"*}
out=${rest#*"$TAB"}
[ "$rest" = "$rc" ] && out=
if [ "$want" != "$box" ]; then
	echo "STUB MISMATCH call $n: script wants '$want', UI shows '$box'" >>"$D/errors"
	exit 99
fi
[ -n "$out" ] && printf '%b\n' "$out"
exit "$rc"
