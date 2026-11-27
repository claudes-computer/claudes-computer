#!/bin/bash
# Runs the published desktop image (ghcr.io/claudes-computer/claudes-computer) without Docker, from a folder that
# survives the machine being replaced. For sandboxes where you're root but only your home folder is kept, and
# Docker isn't there: the image is unpacked into that folder once, then each start is a chroot into it.
#
#   run-from-image.sh            start (the first time: downloads and unpacks the image, about 3 GB)
#   run-from-image.sh --update   get the newest image first (keeps the Tailscale identity and the desktop's files)
#   run-from-image.sh status     READY / SIGN IN / NOT UP, like the start
#   run-from-image.sh stop       stop everything running from the image
#
# Settings (environment): CCRD_ROOT (default ~/ccrd-root), CCRD_NAME, CCRD_TZ, CCRD_KBPS, CCRD_FPS, CCRD_TS_AUTHKEY,
# HTTPS_PROXY, CCRD_IMPORT_STATE. Behind a proxy that refuses Tailscale's own upgrades, also TS_CONTROL_WEBSOCKET=1 TS_DERP_WEBSOCKET=1.
# Must run as root. Output of the desktop's start-up: $CCRD_ROOT/start.log.
R=${CCRD_ROOT:-$HOME/ccrd-root}; F=$R/rootfs
IMAGE=${CCRD_IMAGE:-ghcr.io/claudes-computer/claudes-computer:latest}
[ "$(id -u)" = 0 ] || { echo "run-from-image.sh must run as root"; exit 1; }

inside(){ for p in /proc/[0-9]*; do [ "$(readlink $p/root 2>/dev/null)" = "$F" ] && echo ${p#/proc/}; done; }
unmount(){ for m in $(awk -v f="$F" '$2 ~ "^"f"/" {print $2}' /proc/mounts | sort -r); do umount -l "$m" 2>/dev/null; done; }
SVC=ccrd-desktop
has_systemd(){ [ -d /run/systemd/system ] && command -v systemd-run >/dev/null; }
stop(){ has_systemd && [ -z "$CCRD_IN_SERVICE" ] && { systemctl stop $SVC 2>/dev/null; systemctl reset-failed $SVC 2>/dev/null; }
  local p; p=$(inside); [ -n "$p" ] && { kill $p 2>/dev/null; sleep 3; p=$(inside); [ -n "$p" ] && kill -9 $p 2>/dev/null; }; unmount; }
TS="chroot $F /opt/ccrd/tailscale --socket=/opt/ccrd/ts.sock"
status(){
  for i in $(seq 1 ${1:-1}); do
    if $TS status >/dev/null 2>&1; then echo "READY: on Tailscale as $(chroot $F /opt/ccrd/computer-name.sh 2>/dev/null) ($($TS ip -4 2>/dev/null))"; return 0; fi
    link=$(grep -o 'https://login.tailscale.com/[^ ]*' $R/start.log 2>/dev/null | tail -1)
    [ -n "$link" ] && { echo "SIGN IN: $link"; return 0; }
    [ "${1:-1}" -gt 1 ] && sleep 5
  done
  echo "NOT UP. Last lines of $R/start.log:"; tail -15 $R/start.log 2>/dev/null; return 1
}
# A few short lines for an agent whose tools only show it a summary of long output.
report(){
  local up m
  echo "uptime_min=$(awk '{print int($1/60)}' /proc/uptime) mem_avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) home_free_gb=$(df -BG --output=avail $R 2>/dev/null | tail -1 | tr -dc 0-9)"
  echo "unpacked=$([ -x $F/opt/ccrd/desktop-on.sh ] && echo yes || echo no) mounts=$(grep -c " $F/" /proc/1/mounts 2>/dev/null) service=$(has_systemd && systemctl is-active $SVC 2>/dev/null || echo none) perms=$(stat -c %a $F 2>/dev/null)/$(stat -c %a $F/usr/bin/env 2>/dev/null)"
  up=""; for x in Xvfb xfce4-session selkies tailscaled pulseaudio; do pgrep -f "$x" >/dev/null && up="$up $x=up" || up="$up $x=DOWN"; done; echo "running:$up"
  echo "tailscale: $($TS status >/dev/null 2>&1 && echo "signed in as $($TS ip -4 2>/dev/null)" || echo "not signed in")"
  echo "desktop_page=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:6081/)"
  for l in xvfb xfce selkies tsd; do m=$(grep -iE "error|fatal|cannot|denied|fail" $R/tmp/$l.log 2>/dev/null | tail -1 | cut -c1-150); [ -n "$m" ] && echo "$l.log: $m"; done
  m=$(grep -iE "error|fail|couldn|NOT UP" $R/start.log 2>/dev/null | tail -1 | cut -c1-150); [ -n "$m" ] && echo "start.log: $m"
  return 0
}
case "$1" in stop) stop; echo stopped; exit 0;; status) status; exit;; report) report; exit 0;; esac

# ---- Get the image (first time, or --update) ---------------------------------------------------------------
if [ ! -x $F/opt/ccrd/desktop-on.sh ] || [ "$1" = --update ]; then
  echo "Getting the desktop image (about 1.3 GB to download, 3.2 GB unpacked)..."
  command -v skopeo >/dev/null && command -v umoci >/dev/null \
    || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq skopeo umoci >/dev/null; } \
    || { echo "Couldn't install skopeo and umoci (needed to unpack the image)"; exit 1; }
  mkdir -p $R && stop
  export TMPDIR=$R/.tmp; rm -rf $TMPDIR $R/.oci $R/.new; mkdir -p $TMPDIR
  skopeo copy -q "docker://$IMAGE" "oci:$R/.oci:latest" && umoci unpack --image "$R/.oci:latest" $R/.new >/dev/null \
    || { echo "Couldn't download or unpack $IMAGE"; rm -rf $TMPDIR $R/.oci $R/.new; exit 1; }
  # Keep what belongs to this computer: the Tailscale identity (/state) and the desktop user's files.
  if [ -d $F ]; then
    for k in state home/desk; do [ -d $F/$k ] && { rm -rf $R/.new/rootfs/$k; mv $F/$k $R/.new/rootfs/$k; }; done
    rm -rf $R/.old; mv $F $R/.old
  fi
  mv $R/.new/rootfs $F; rm -rf $R/.new $R/.oci $R/.old $TMPDIR; unset TMPDIR
  echo "Unpacked into $F"
fi

# A Tailscale identity from an earlier install on this machine (CCRD_IMPORT_STATE=its state folder): same computer.
if [ -n "$CCRD_IMPORT_STATE" ] && [ -f "$CCRD_IMPORT_STATE/ts.state" ] && [ ! -f $F/state/ts.state ]; then
  mkdir -p $F/state && cp -a "$CCRD_IMPORT_STATE/." $F/state/ && echo "Kept the Tailscale identity from $CCRD_IMPORT_STATE"
fi

# ---- Start --------------------------------------------------------------------------------------------------
chmod 755 $F   # some home folders unpack it without "others may enter", and the desktop runs as an ordinary user
if [ -n "$(inside)" ] && $TS status >/dev/null 2>&1; then echo "Already running."; status; exit; fi
# Where systemd runs the machine, the desktop runs as its service: it then outlives the command that started it
# (some sandboxes end everything a command started, and give each command its own view of the mounts).
if [ -z "$CCRD_IN_SERVICE" ] && has_systemd; then
  stop
  envs=(); for v in HOME CCRD_ROOT CCRD_IMAGE CCRD_NAME CCRD_TZ CCRD_KBPS CCRD_FPS CCRD_TS_AUTHKEY CCRD_IMPORT_STATE \
                    HTTPS_PROXY https_proxy TS_CONTROL_WEBSOCKET TS_DERP_WEBSOCKET; do [ -n "${!v}" ] && envs+=(-E "$v=${!v}"); done
  : > $R/start.log
  systemd-run --unit=$SVC --collect -p Restart=on-failure -p RestartSec=10 -E CCRD_IN_SERVICE=1 "${envs[@]}" \
    bash "$(readlink -f "$0")" >/dev/null 2>&1 || { echo "FAILED: couldn't start the systemd service $SVC"; exit 1; }
  echo "Starting as the systemd service $SVC (a minute or two)..."
  status 60; exit
fi
stop
mkdir -p $F/state $F/proc $F/sys $F/dev $F/run $F/tmp
mount -t proc proc $F/proc
mount --rbind /sys $F/sys && mount --make-rslave $F/sys
mount --rbind /dev $F/dev && mount --make-rslave $F/dev
mount -t tmpfs -o mode=755 tmpfs $F/run
# /tmp is a folder in the kept area, not memory: its logs survive for a look afterwards, and it costs no RAM.
rm -rf $R/tmp; mkdir -p $R/tmp; chmod 1777 $R/tmp; mount --bind $R/tmp $F/tmp
cp -L /etc/resolv.conf $F/etc/resolv.conf 2>/dev/null
cp -L /etc/hosts $F/etc/hosts 2>/dev/null
# This machine's proxy certificates: docker-start.sh trusts whatever is in this folder.
cp /usr/local/share/ca-certificates/*.crt $F/usr/local/share/ca-certificates/ 2>/dev/null
P=${HTTPS_PROXY:-$https_proxy}
: > $R/start.log
run_inside(){
  chroot $F /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
  LANG=C.UTF-8 CCRD_STATE_DIR=/state ${P:+HTTPS_PROXY=$P https_proxy=$P NO_PROXY=localhost,127.0.0.1} \
  ${TS_CONTROL_WEBSOCKET:+TS_CONTROL_WEBSOCKET=$TS_CONTROL_WEBSOCKET} ${TS_DERP_WEBSOCKET:+TS_DERP_WEBSOCKET=$TS_DERP_WEBSOCKET} \
  ${CCRD_NAME:+CCRD_NAME=$CCRD_NAME} ${CCRD_TZ:+CCRD_TZ=$CCRD_TZ} ${CCRD_KBPS:+CCRD_KBPS=$CCRD_KBPS} \
  ${CCRD_FPS:+CCRD_FPS=$CCRD_FPS} ${CCRD_TS_AUTHKEY:+CCRD_TS_AUTHKEY=$CCRD_TS_AUTHKEY} \
  /opt/claudes-computer/cloud/docker-start.sh >> $R/start.log 2>&1 < /dev/null
}
# In the service: stay in the foreground, so the service lives as long as the desktop.
[ -n "$CCRD_IN_SERVICE" ] && { run_inside; exit; }
run_inside & disown

echo "Starting (a minute or two)..."
status 60
