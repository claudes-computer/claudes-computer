#!/bin/bash
# Keeps small sign-in files on your TV (the Claude's Computer app's safe, tailnet port 6084), so a replaced cloud
# machine can get them back. The TV only answers the desktop: a device named "ccrd" that belongs to the same
# Tailscale user as the TV.
#   tv-keep.sh put NAME FILE    store FILE on every TV that's on right now
#   tv-keep.sh get NAME FILE    fetch NAME from the first TV that has it
#   tv-keep.sh tvs              list the TVs that are on
D=/opt/ccrd; TS="$D/tailscale --socket=$D/ts.sock"
tvs(){ $TS status --json 2>/dev/null | python3 -c '
import json, sys
for p in (json.load(sys.stdin).get("Peer") or {}).values():
    if p.get("Online") and p.get("HostName", "").lower() == "ccrd-tv" and p.get("TailscaleIPs"):
        print(p["TailscaleIPs"][0])'; }
c(){ env -u no_proxy -u NO_PROXY curl -s -m 15 --socks5-hostname 127.0.0.1:1055 "$@"; }   # no_proxy would send 100.x around Tailscale
case "$1" in
  put) n=0; for ip in $(tvs); do c -f -X PUT --data-binary @"$3" "http://$ip:6084/keep/$2" -o /dev/null && n=$((n+1)); done
       echo "stored on $n TV(s)"; [ $n -gt 0 ];;
  get) for ip in $(tvs); do (umask 077; c -f "http://$ip:6084/keep/$2" -o "$3.new") && [ -s "$3.new" ] && mv "$3.new" "$3" && exit 0; rm -f "$3.new"; done
       exit 1;;
  tvs) tvs;;       # the tailnet addresses of the TVs that are on (used by home-route.sh and house-check.sh)
  *) echo "usage: $0 put|get NAME FILE | tvs"; exit 2;;
esac
