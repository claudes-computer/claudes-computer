#!/bin/bash
# Pin a desktop icon to the top-right corner in every screen size xfdesktop has seen (and the usual ones it hasn't).
# Usage: icon-top-right.sh /home/desk/Desktop/name.desktop   (run as root; xfdesktop is restarted if running)
F="$1"; U=desk; DIR=/home/$U/.config/xfce4/desktop; CELL=158   # xfdesktop's icon cell at the default 48px size
mkdir -p "$DIR"; chown $U: "$DIR"
P=$(pgrep -u $U -x xfdesktop | head -1); ENV=""
[ -n "$P" ] && { ENV=$(tr '\0' '\n' < /proc/$P/environ | grep -E '^(DISPLAY|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY)=' | paste -sd' ');
  runuser -u $U -- env $ENV xfdesktop --quit; sleep 1; }   # it writes positions on exit, so stop it first
for rc in "$DIR"/icons.screen0-*.rc "$DIR"/icons.screen0-1904x1064.rc "$DIR"/icons.screen0-1920x1080.rc; do
  W=$(basename "$rc" .rc | sed 's/.*-\([0-9]*\)x.*/\1/'); [ -n "$W" ] || continue
  python3 - "$rc" "$F" $(( W / CELL - 1 )) <<'PY'
import sys, configparser
rc, f, col = sys.argv[1], sys.argv[2], sys.argv[3]
c = configparser.RawConfigParser(); c.optionxform = str; c.read(rc)
if not c.has_section(f): c.add_section(f)
c.set(f, "row", "0"); c.set(f, "col", col)
with open(rc, "w") as o: c.write(o, space_around_delimiters=False)
PY
  chown $U: "$rc"
done
[ -n "$P" ] && runuser -u $U -- env $ENV setsid xfdesktop >/dev/null 2>&1 < /dev/null &
exit 0
