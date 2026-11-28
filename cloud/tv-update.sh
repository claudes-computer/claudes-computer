#!/bin/bash
# Updates the TV app on every TV that is on, with the published release (the one people install from the README).
# Only GitHub signs releases, so the TV always accepts it: Android refuses an update signed by anyone else, and the
# installed app keeps working if that ever happens.
# The TV receives the whole file through the app's own private service (tailnet port 6084), then Android asks the
# person at the TV to press Install (or a home computer installs it; see CLAUDE.md).
# Usage: tv-update.sh [--only TV-NAME] [FILE.apk]
#        no FILE: the latest release; FILE: a specific file (for testing on your own TV only)
D=/opt/ccrd; TS="$D/tailscale --socket=$D/ts.sock"
REPO=${CCRD_REPO:-claudes-computer/claudes-computer}
c(){ env -u no_proxy -u NO_PROXY curl -s --socks5-hostname 127.0.0.1:1055 "$@"; }

ONLY=; [ "$1" = --only ] && { ONLY=$2; shift 2; }
if [ -n "$1" ]; then
  apk=$1
else
  apk=$D/tv/release.apk; mkdir -p $D/tv
  echo "Downloading the latest release..."
  curl -fsSL -o "$apk.part" "https://github.com/$REPO/releases/latest/download/claudes-computer.apk" \
    && mv "$apk.part" "$apk" || { echo "Couldn't download the release from github.com/$REPO."; exit 1; }
fi
[ -s "$apk" ] || { echo "No app file at $apk."; exit 1; }

# No TV on the private network (the app is closed, or a TV restarted)? Open the app through the home computer first.
if [ -z "$($D/tv-keep.sh tvs)" ] && grep -q '^CCRD_HOME_BOX=.' $D/ccrd.conf 2>/dev/null; then
  echo "No TV is reachable; opening the app through the home computer..."; $D/tv-open.sh && sleep 25
fi

n=0
for ip in $($TS status --json | python3 -c '
import json, sys
for p in json.load(sys.stdin).get("Peer", {}).values():
    if p.get("HostName", "").startswith("ccrd-tv") and p.get("Online"): print(p["TailscaleIPs"][0])'); do
  name=$($TS status --json | python3 -c "import json,sys; print(next(p['DNSName'].split('.')[0] for p in json.load(sys.stdin)['Peer'].values() if '$ip' in p['TailscaleIPs']))" 2>/dev/null)
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
  n=$((n+1))
  now=$(c -m 15 http://$ip:6084/tv/report | python3 -c 'import json,sys; a=json.load(sys.stdin)["app"]; print(a["id"], a.get("build",""))' 2>/dev/null)
  if [ -z "$now" ]; then
    echo "$name: the app isn't answering (closed, or too old to update itself). Open it, or install the release once"
    echo "  with Downloader: github.com/$REPO/releases/latest"; continue
  fi
  echo "$name (app ${now#* }): sending the update... $(c -m 300 -T "$apk" http://$ip:6084/tv/update)"
done
[ $n = 0 ] && echo "No TV${ONLY:+ named $ONLY} is on right now. Turn it on and open Claude's Computer, then try again."
exit 0
