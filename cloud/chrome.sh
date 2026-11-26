#!/bin/bash
# Chrome on the desktop. It browses through your home connection when that works right now (Tailscale exit node,
# reached through the local SOCKS port :1055), and through this machine's own web proxy otherwise.
[ -f /opt/ccrd/proxy.env ] && . /opt/ccrd/proxy.env
# Started from outside the desktop (by Claude, a script), Chrome would miss the session's sound and accessibility
# bus: take them from the running desktop session.
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] && s=$(pgrep -u "$(id -u)" -x xfce4-session | head -1); then
  export $(tr '\0' '\n' < /proc/$s/environ | grep ^DBUS_SESSION_BUS_ADDRESS=)
fi
PROFILE=$HOME/.claude-desktop-chrome

if curl -s -m 5 -o /dev/null --socks5-hostname 127.0.0.1:1055 https://www.gstatic.com/generate_204; then
  PX="socks5://127.0.0.1:1055"
else
  PX="$HTTPS_PROXY"
fi

if ! pgrep -f "google/chrome/chrome " >/dev/null; then
  # Chrome isn't running, so a leftover lock is stale (the machine was restarted under it).
  rm -f $PROFILE/Singleton*
  # The machine sleeps and restarts without closing Chrome: mark the last session as closed normally, so Chrome
  # doesn't open with a "Restore pages? Chrome didn't shut down correctly" popup.
  PREFS=$PROFILE/Default/Preferences
  [ -f "$PREFS" ] && sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/; s/"exited_cleanly":false/"exited_cleanly":true/' "$PREFS"
fi

export PULSE_LATENCY_MSEC=60
exec /opt/google/chrome/google-chrome --start-maximized --test-type --force-device-scale-factor=1.25 --force-renderer-accessibility \
  --no-first-run --no-default-browser-check --user-data-dir=$PROFILE \
  ${PX:+--proxy-server=$PX} --proxy-bypass-list="localhost;127.0.0.1;*.ts.net;100.*" "$@"
