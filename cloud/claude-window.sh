#!/bin/bash
# Opens a page in a Chrome window on Claude's own workspace (the second one), so Claude can work in it without
# taking over the screen the person is using. Claude drives it through the accessibility tree (a11y.py), which
# works whether or not the window is on screen. Usage (as root): claude-window.sh URL
# The person can look in any time: the second workspace in the panel, or Ctrl+Alt+Right.
URL=${1:?usage: claude-window.sh URL}
S=$(pgrep -u desk -x xfce4-session | head -1) || { echo "the desktop isn't running"; exit 1; }
E=$(tr '\0' '\n' < /proc/$S/environ | grep -E '^(DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR)=')
run() { sudo -u desk env DISPLAY=:1 $E "$@"; }
before=$(run wmctrl -l | awk '{print $1}')
run setsid /opt/ccrd/chrome.sh --new-window "$URL" >/dev/null 2>&1 &
for i in $(seq 1 40); do
  new=$(run wmctrl -l | awk '{print $1}' | grep -vxF "$before" | head -1)
  [ -n "$new" ] && break; sleep 0.25
done
[ -z "$new" ] && { echo "no new window appeared"; exit 1; }
run wmctrl -i -r "$new" -t 1        # to Claude's workspace, without switching the person's view
run wmctrl -i -r "$new" -b add,maximized_vert,maximized_horz
echo "$new $(run wmctrl -l | awk -v w="$new" '$1==w {$1=$2=$3=""; print substr($0,4)}')"
