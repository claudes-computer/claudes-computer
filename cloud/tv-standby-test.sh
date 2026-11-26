#!/bin/bash
# Does a TV stay reachable while it's turned off? Watches it from here and says when its screen went off and
# whether (and when) it dropped off the private network.
#   tv-standby-test.sh [TV tailnet IP] [minutes, default 20]
# Start it, then turn the TV off with its remote. Prints one line per change and a verdict at the end.
D=/opt/ccrd; TS="$D/tailscale --socket=$D/ts.sock"
c(){ env -u no_proxy -u NO_PROXY curl -s --socks5-hostname 127.0.0.1:1055 "$@"; }
case "$1" in 100.*) IP=$1; shift;; *) IP=$($TS status --json | python3 -c '
import json, sys
print(next((p["TailscaleIPs"][0] for p in json.load(sys.stdin).get("Peer", {}).values() if p.get("HostName", "").startswith("ccrd-tv") and p.get("Online")), ""))');; esac
[ -z "$IP" ] && { echo "No TV is on. Open Claude's Computer on the TV first."; exit 1; }
MIN=${1:-20}
state(){   # "on" / "off" (screen) or "gone" (not answering)
  local r; r=$(c -m 8 "http://$IP:6084/tv/report" | python3 -c 'import json,sys; print("on" if json.load(sys.stdin)["tv"].get("screen_on") else "off")' 2>/dev/null)
  echo "${r:-gone}"
}
now(){ date '+%-I:%M:%S %p'; }
echo "$(now)  watching $IP for $MIN minutes. Turn the TV off with its remote."
last=""; offAt=0; goneAt=0; start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt $(( MIN * 60 )) ]; do
  s=$(state); t=$(date +%s)
  if [ "$s" != "$last" ]; then
    case "$s" in
      on)   echo "$(now)  screen on, reachable";;
      off)  echo "$(now)  screen off, still reachable"; [ $offAt = 0 ] && offAt=$t;;
      gone) echo "$(now)  not answering"; [ $goneAt = 0 ] && goneAt=$t;;
    esac
    last=$s
  fi
  sleep 20
done
if [ $offAt = 0 ] && [ $goneAt = 0 ]; then echo "VERDICT: the screen never went off; nothing tested."
elif [ $goneAt = 0 ]; then echo "VERDICT: PASS. Stayed reachable $(( ($(date +%s) - offAt) / 60 )) minutes with the screen off."
elif [ $offAt = 0 ]; then echo "VERDICT: dropped without ever reporting the screen off (turned off and cut off within 20 s, or unplugged)."
else echo "VERDICT: FAIL. Dropped $(( goneAt - offAt )) s after the screen went off."; fi
