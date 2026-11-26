#!/bin/bash
# Lets the TV wake this computer with a PIN, without a phone. The wake is one of Claude Code's scheduled tasks,
# tied to this session, that says "desktop on"; its API trigger gives it a web address and a token that can only
# start that task. Claude creates the task and runs this script with the task's id; you generate the token on
# claude.ai (Scheduled tasks, the task, Edit, + API, Generate token) and paste it into the box this script opens on
# the desktop, never into chat. The token is then kept on your TV (the app's safe) and here, readable by root only.
#   wake-token.sh trig_...        ask for the token on the desktop and hand it to the TVs that are on
#   wake-token.sh --push          hand the saved token to the TVs again (a TV that was off, or a new one)
D=/opt/ccrd; F=$D/wake.json
if [ "$1" != "--push" ]; then
  case "$1" in trig_*) ;; *) echo "usage: $0 trig_<task id> | --push"; exit 2;; esac
  pgrep -x xfce4-session >/dev/null || { echo "the desktop isn't running: say \"desktop on\" first"; exit 1; }
  # The box runs as the desktop user, on the desktop's screen; only what was typed comes back.
  TOK=$(runuser -u desk -- env -i DISPLAY=:1 HOME=/home/desk XDG_RUNTIME_DIR=/run/user/$(id -u desk) PATH=/usr/bin:/bin \
    zenity --entry --hide-text --title="Wake from the TV" --width=760 \
    --text="Paste the token from claude.ai here (it starts with sk-ant-).\nIt can only start the wake task; it is stored on your TV and on this computer." 2>/dev/null) || { echo "CANCELLED"; exit 1; }
  TOK=$(printf '%s' "$TOK" | tr -d ' \n\r')
  case "$TOK" in sk-ant-*) ;; *) echo "that doesn't look like a token (it should start with sk-ant-)"; exit 1;; esac
  (umask 077; printf '{"fire_url": "https://api.anthropic.com/v1/claude_code/routines/%s/fire", "token": "%s"}\n' "$1" "$TOK" > $F)
  unset TOK
fi
[ -f $F ] || { echo "no wake token saved yet"; exit 1; }
"$(dirname "$0")/tv-keep.sh" put wake.json $F && echo "WAKE_READY: on the TV's asleep screen, press OK and choose a PIN" \
  || echo "saved, but no TV is on right now: open the app on the TV, then run $0 --push"
