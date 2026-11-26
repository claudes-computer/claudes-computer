#!/bin/bash
# Uses the TV as this machine's way into your home: browsing goes out through your home internet (exit node), and
# your home network (printer, other devices) becomes reachable for Claude. The TV app offers both; you approve them
# once in the Tailscale admin console (README, step 3). Run by desktop-on.sh and keepawake.sh.
# If the home route in use is still online it is left alone (for example an always-on home computer).
#   home-route.sh          apply      home-route.sh --show   only print what it would do
D=/opt/ccrd; TS="$D/tailscale --socket=$D/ts.sock"; [ "$1" = "--show" ] && SHOW=1
pick=$($TS status --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
peers = list((d.get("Peer") or {}).values())
cur = [p for p in peers if p.get("ExitNode")]
if cur and cur[0].get("Online"):
    print("keep", cur[0].get("HostName", ""))
else:
    # An approved exit node shows up with ExitNodeOption. Prefer the TV app, the newest one that is on.
    c = [p for p in peers if p.get("Online") and p.get("ExitNodeOption") and p.get("TailscaleIPs")]
    tv = [p for p in c if p.get("HostName", "").lower() == "ccrd-tv"]
    best = (sorted(tv, key=lambda p: p.get("Created", ""))[-1:] or c[:1])
    print("use", best[0]["TailscaleIPs"][0], best[0].get("HostName", "")) if best else print("none")
' 2>/dev/null)
set -- $pick
case "$1" in
  keep) echo "home route: $2 (unchanged)";;
  use)  if [ "$SHOW" = 1 ]; then echo "home route: would use $3 ($2)"; else
          $TS set --exit-node="$2" --accept-routes=true >/dev/null 2>&1 && echo "home route: $3 ($2)" || echo "home route: couldn't set $3"; fi;;
  *)    echo "home route: none yet (open the TV app, and approve its exit node and home network in Tailscale)";;
esac

# The clock follows the house: unless CCRD_TZ is set, take the time zone from a TV that is on.
. $D/ccrd.conf 2>/dev/null
if [ -z "$CCRD_TZ" ] && [ "$SHOW" != 1 ]; then
  for ip in $($D/tv-keep.sh tvs); do
    tz=$(env -u no_proxy -u NO_PROXY curl -s -m 8 --socks5-hostname 127.0.0.1:1055 "http://$ip:6084/house/timezone" | tr -cd 'A-Za-z0-9_/+-')
    if [ -n "$tz" ] && [ -f "/usr/share/zoneinfo/$tz" ]; then
      [ "$(readlink /etc/localtime)" = "/usr/share/zoneinfo/$tz" ] || { ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime; echo "clock: $tz (from the TV)"; }
      break
    fi
  done
fi
