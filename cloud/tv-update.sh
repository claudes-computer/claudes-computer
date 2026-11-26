#!/bin/bash
# Sends the newest TV app to every TV that is on, through the app's own private service (tailnet port 6084).
# The TV receives the whole file first, then Android asks whoever is at the TV to confirm the update.
# Usage: tv-update.sh [apk]      default: /opt/ccrd/tv/cc.apk (cc-old.apk for a TV whose app has an older id)
D=/opt/ccrd; TS="$D/tailscale --socket=$D/ts.sock"
c(){ env -u no_proxy -u NO_PROXY curl -s --socks5-hostname 127.0.0.1:1055 "$@"; }
for ip in $($TS status --json | python3 -c '
import json, sys
for p in json.load(sys.stdin).get("Peer", {}).values():
    if p.get("HostName") == "ccrd-tv" and p.get("Online"): print(p["TailscaleIPs"][0])'); do
  id=$(c -m 15 http://$ip:6084/tv/report | python3 -c 'import json,sys; d=json.load(sys.stdin)["app"]; print(d["id"], d["version"])' 2>/dev/null)
  [ -z "$id" ] && { echo "$ip: this TV's app is too old to update itself; install the new one with Downloader once"; continue; }
  apk=${1:-$D/tv/cc.apk}; [ -z "$1" ] && [ "${id%% *}" != dev.ccrd.tv ] && apk=$D/tv/cc-old.apk
  echo "$ip (${id}): sending $(basename $apk)... $(c -m 300 -T "$apk" http://$ip:6084/tv/update)"
done
