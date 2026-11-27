#!/bin/bash
# Starts (or repairs) every piece of the desktop. Safe to run repeatedly: each piece is started only if it
# isn't running. keepawake.sh runs this every 30 seconds while someone is watching.
D=/opt/ccrd
# One run at a time: a "desktop on" from the TV can arrive while keepawake.sh is running this. The second waits.
# One copy at a time. flock holds the lock and runs this script as its child without passing the lock on, so
# the programs this starts (screen, desktop, stream) don't keep holding it after the script ends.
[ -z "$DESKTOP_ON_LOCKED" ] && exec env DESKTOP_ON_LOCKED=1 flock -w 300 -o /tmp/desktop-on.lock "$0" "$@"
# CCRD_NAME=Work desktop-on.sh: this session's computer is "Work" (ccrd-work on the tailnet; computer-name.sh).
# Remembered in ccrd.conf; CCRD_NAME= (empty) makes it the first computer again.
if [ -n "${CCRD_NAME+set}" ]; then
  touch $D/ccrd.conf; sed -i '/^CCRD_NAME=/d' $D/ccrd.conf
  [ -n "$CCRD_NAME" ] && printf 'CCRD_NAME=%q\n' "$CCRD_NAME" >> $D/ccrd.conf
fi
. $D/ccrd.conf 2>/dev/null
[ -n "$HTTPS_PROXY" ] && echo "HTTPS_PROXY=$HTTPS_PROXY" > $D/proxy.env

# ---- The desktop's user -------------------------------------------------------------------------------------
# The desktop runs as a normal user ("desk"), not as root: apps like VLC refuse root, and it keeps the desktop
# away from this machine's own keys. It starts from a clean environment, so none of this machine's own settings
# or keys leak into it.
U=desk
H=/home/$U
R=/run/user/$(id -u $U)
mkdir -p $R && chown $U:$U $R && chmod 700 $R
as() {
  (cd $H && exec runuser -u $U -- env -i \
    HOME=$H USER=$U LOGNAME=$U SHELL=/bin/bash LANG=C.UTF-8 XDG_RUNTIME_DIR=$R DISPLAY=:1 \
    PATH=$D/pybin:/usr/local/bin:/usr/bin:/bin:/usr/games \
    XCURSOR_THEME=Adwaita XCURSOR_SIZE=48 \
    ${HTTPS_PROXY:+HTTPS_PROXY=$HTTPS_PROXY https_proxy=$HTTPS_PROXY NO_PROXY=localhost,127.0.0.1} \
    "$@")
}
[ -x $D/fix-python-apps.sh ] && $D/fix-python-apps.sh

# ---- Tailscale ----------------------------------------------------------------------------------------------
TS="$D/tailscale --socket=$D/ts.sock"
start_tailscaled() {
  pgrep -x tailscaled >/dev/null && return
  # --no-logs-no-support: don't upload Tailscale's diagnostic logs to Tailscale (their support then has none).
  # CCRD_STATE_DIR: where the Tailscale identity is kept (the Docker image keeps it in its /state volume).
  local S=${CCRD_STATE_DIR:-$D}
  (setsid $D/tailscaled --tun=userspace-networking --statedir=$S/tsvar --state=$S/ts.state \
    --socket=$D/ts.sock --socks5-server=localhost:1055 --no-logs-no-support >/tmp/tsd.log 2>&1 &)
}

# ---- A fresh machine: get on the tailnet first, then bring files and settings back before the desktop starts --
# Once per machine. (If the TV wasn't on yet, save.sh tries the restore again later, before its first backup.)
if [ ! -f $D/first-start-done ]; then
  start_tailscaled
  sleep 6
  $D/ts-join.sh
  timeout 120 $D/restore.sh >/dev/null 2>&1
  date > $D/first-start-done
fi

# ---- Clock: your time zone (CCRD_TZ in ccrd.conf; otherwise home-route.sh asks the TV for its own) -------------
[ -n "$CCRD_TZ" ] && [ -f "/usr/share/zoneinfo/$CCRD_TZ" ] && ln -sf "/usr/share/zoneinfo/$CCRD_TZ" /etc/localtime

# ---- Swap (8 GB file), so big apps don't run the machine out of memory --------------------------------------
if ! swapon --show | grep -q /swapfile; then
  [ -f /swapfile ] || { fallocate -l 8G /swapfile && chmod 600 /swapfile && mkswap -q /swapfile; }
  swapon /swapfile
  sysctl -qw vm.swappiness=20
fi 2>/dev/null

# ---- Screen, desktop, sound, printing -----------------------------------------------------------------------
pgrep -x Xvfb >/dev/null || { (as setsid Xvfb :1 -screen 0 1920x1080x24 >/tmp/xvfb.log 2>&1 &); sleep 2; }
# Sound first, so the panel's volume control finds it when the desktop starts.
pgrep -x pulseaudio >/dev/null || as pulseaudio --start --exit-idle-time=-1 2>/dev/null
pgrep -x xfce4-session >/dev/null || (as setsid dbus-launch startxfce4 >/tmp/xfce.log 2>&1 &)

# First start on this machine: give the desktop its look (unless Drive already restored your settings).
if [ ! -f $D/look-applied ]; then
  for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x xfce4-panel >/dev/null && break; sleep 2; done
  [ -f $H/.config/xfce4/panel/whiskermenu-1.rc ] || as $D/apply-look.sh >/dev/null 2>&1
  date > $D/look-applied
fi

pgrep -x cupsd >/dev/null || /usr/sbin/cupsd 2>/dev/null

# Accessibility on, so Claude can drive the desktop by its structure (cloud/a11y.py) instead of by pictures.
(for i in $(seq 1 15); do
   P=$(pgrep -u $U -x xfce4-session | head -1); [ -n "$P" ] && break; sleep 2
 done
 DB=$(tr '\0' '\n' < /proc/$P/environ 2>/dev/null | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
 as env DBUS_SESSION_BUS_ADDRESS="$DB" busctl --user set-property org.a11y.Bus /org/a11y/bus org.a11y.Status IsEnabled b true
) >/dev/null 2>&1 &

# Desktop icons must be executable and carry XFCE's "trusted" mark (a Drive restore can drop both), or opening one asks about an "Untrusted application launcher".
# The mark can be lost when the machine restarts, so set it again once per boot (in the desktop's own session).
[ -f /run/ccrd-icons-trusted ] || (touch /run/ccrd-icons-trusted; for i in $(seq 1 15); do
   P=$(pgrep -u $U -x xfce4-session | head -1); [ -n "$P" ] && break; sleep 2
 done
 DB=$(tr '\0' '\n' < /proc/$P/environ 2>/dev/null | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
 for f in $H/Desktop/*.desktop; do
   [ -f "$f" ] && chmod 755 "$f" && as env DBUS_SESSION_BUS_ADDRESS="$DB" gio set -t string "$f" metadata::xfce-exe-checksum \
     "$(sha256sum "$f" | cut -d' ' -f1)" 2>/dev/null
 done) &

# Optional home printer (CCRD_PRINTER in ccrd.conf): printing can't use Tailscale's SOCKS port directly, so relay
# a local port to it.
if [ -n "$CCRD_PRINTER" ] && ! pgrep -f "^socat .*TCP-LISTEN:6631" >/dev/null; then
  (setsid socat --experimental TCP-LISTEN:6631,bind=127.0.0.1,reuseaddr,fork \
    SOCKS5-CONNECT:127.0.0.1:1055:$CCRD_PRINTER:631 >/tmp/printfwd.log 2>&1 &)
fi

# ---- The stream (Selkies) -----------------------------------------------------------------------------------
# Defaults from docs/measurements.md (1080p, 4 cores, no GPU):
# - software H.264 holds 30 fps at about a third of a core with sharp text; software AV1 needed over a core and
#   blurred scrolling text;
# - 5 Mbit/s holds 30 fps through Tailscale's public relays; with your own home relay (home/), 8000 is sharper.
# Override in ccrd.conf: CCRD_ENCODER (h264enc, av1enc, vp9enc), CCRD_FPS, CCRD_KBPS.
# The sidebar gives phones and tablets an on-screen keyboard button; the TV app hides it.
# CCRD_SIDEBAR=false turns it off for everyone (for a TV still on an older app).
# It listens on this machine only: Tailscale hands tailnet connections to it locally.
# --cursor-size is in points at 96 DPI and gets scaled by the desktop's 144 DPI: 32 makes 48 pixels, the same size the
# apps use (XCURSOR_SIZE=48). Left to itself it takes XCURSOR_SIZE and scales it to 72, so the pointer changed size
# every time it crossed from an app onto the desktop.
# --microphone-enabled / --microphone-on-start demand: the desktop always has a microphone (SelkiesVirtualMic); the
# TV is asked for its real mic only while an app records from it, and the TV app allows that only after Ctrl+Alt+M.
SELKIES="/opt/selkies/bin/selkies --addr 127.0.0.1 --port 6081 --mode websockets
  --encoder ${CCRD_ENCODER:-h264enc} --framerate ${CCRD_FPS:-30} --video-bitrate ${CCRD_KBPS:-5000}
  --rate-control-mode cbr --video-max-qp 32 --audio-enabled true --microphone-enabled true --microphone-on-start demand
  --enable-basic-auth false --enable-resize false
  --ui-show-sidebar ${CCRD_SIDEBAR:-true} --ui-show-connection-indicator false --ui-show-logo false
  --ui-show-core-buttons false --use-browser-cursors true --cursor-size 32"
# The TV app's installer file rides along with the stream's web pages, so a TV can fetch it with Downloader from
# itself: http://127.0.0.1:16082/assets/tv.apk (through the running app; no laptop, nothing public).
/opt/ccrd/patch-selkies-audio.sh >/dev/null 2>&1   # a sound cushion for Wi-Fi (see that file)
# Snappy first launches: a machine that woke from a pause has lost its file cache, so each app's first start reads
# it from a slow network disk (seconds). Read the big apps into memory once per wake, quietly in the background.
if [ ! -f /tmp/ccrd-warm ]; then
  touch /tmp/ccrd-warm
  (nice -n 19 ionice -c3 find /opt/google/chrome /opt/firefox /usr/lib/libreoffice /usr/lib/x86_64-linux-gnu \
     /usr/share/fonts /usr/share/icons -type f -size -200M -exec cat {} + >/dev/null 2>&1 &)
  # The Local AI extra (if installed): its model takes minutes to load from a cold disk, so start it now, not on the
  # first question.
  [ -x /opt/llm/start.sh ] && ! curl -s --noproxy '*' -m 2 http://127.0.0.1:8088/v1/models >/dev/null && \
    as bash -c 'mkdir -p ~/.cache; nice -n 10 nohup /opt/llm/bin/python -m llama_cpp.server --config_file /opt/llm/models.json > ~/.cache/local-ai.log 2>&1 &'
fi
for w in /opt/selkies/lib/python3*/site-packages/selkies/selkies_web/assets; do
  [ -f $D/tv/cc.apk ] && cp -u $D/tv/cc.apk $w/tv.apk; [ -f $D/tv/cc-old.apk ] && cp -u $D/tv/cc-old.apk $w/tv-old.apk
done 2>/dev/null
pgrep -f "^/opt/selkies/bin/python3 /opt/selkies/bin/selkies" >/dev/null \
  || (as setsid $SELKIES >/tmp/selkies.log 2>&1 &)

# ---- On the tailnet -----------------------------------------------------------------------------------------
start_tailscaled
# Signed in under another name than this computer's (it was just named or renamed): take the new name.
want=$($D/computer-name.sh)
have=$($TS status --json 2>/dev/null | python3 -c 'import json,sys; print((json.load(sys.stdin).get("Self") or {}).get("HostName",""))' 2>/dev/null)
[ -n "$have" ] && [ "$have" != "$want" ] && $TS set --hostname="$want" >/dev/null 2>&1
# Signed out (an ephemeral machine Tailscale removed while it slept)? Sign back in with the saved key, if any.
(sleep 4; $D/ts-join.sh >/dev/null 2>&1) &
# Your home: browse through the TV's internet connection and reach the home network through it.
(sleep 10; $D/home-route.sh >/tmp/home-route.log 2>&1) &

# Settings for the TV app (house name for the home relay), reachable over the tailnet on port 6083.
mkdir -p $D/tv
pgrep -f "^python3 -m http.server 6083" >/dev/null \
  || (setsid python3 -m http.server 6083 --bind 127.0.0.1 --directory $D/tv >/tmp/tvconfig.log 2>&1 &)

# HTTPS address on the tailnet (https://<name>.<tailnet>.ts.net), so any browser on your Tailscale can open the
# desktop: phones and tablets need a secure address to play the stream. Tailnet-only, certificate from Tailscale.
(sleep 8; $TS serve status 2>/dev/null | grep -q 6081 \
  || $TS serve --bg --https=443 http://127.0.0.1:6081 >/dev/null 2>&1) &

# Selkies creates its own "output" sound device and streams that one: make it the default.
for i in 1 2 3 4 5; do
  as pactl list short sinks 2>/dev/null | grep -qw output && { as pactl set-default-sink output;
    as pactl set-default-source SelkiesVirtualMic 2>/dev/null; break; }   # the TV's mic, when it sends one
  sleep 2
done

# ---- One line for whoever ran this (Claude reads it): is the desktop reachable from the TV? ------------------
# (Tailscale takes a few seconds to settle after it starts: wait for a real answer.)
for i in 1 2 3 4 5 6 7 8; do
  state=$($TS status --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("BackendState", ""), (d.get("Self") or {}).get("DNSName", "").split(".")[0])' 2>/dev/null)
  case "$state" in Running*|NeedsLogin*|NeedsMachineAuth*) break;; esac
  sleep 2
done
# Check what was started rather than assume it.
broken=""
pgrep -x Xvfb >/dev/null || broken="$broken the virtual screen (/tmp/xvfb.log),"
pgrep -x xfce4-session >/dev/null || broken="$broken the desktop (/tmp/xfce.log),"
# (After a cold boot the stream can take most of a minute to answer.)
for i in $(seq 1 20); do
  curl -s -m 3 -o /dev/null http://127.0.0.1:6081/ && stream=ok && break
  sleep 3
done
[ "$stream" = ok ] || broken="$broken the stream (/tmp/selkies.log),"
if [ -n "$broken" ]; then
  echo "desktop NOT fully up. Didn't start:${broken%,}"
  exit 1
fi
case "$state" in
  Running*) echo "desktop up; on your Tailscale as ${state#Running }";;
  *) echo "desktop up, but not signed in to Tailscale yet: run $D/tailscale-up.sh and give the user the link it prints";;
esac
exit 0
