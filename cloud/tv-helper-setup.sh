#!/bin/bash
# Sets up the repair helper on a TV, one step per run: it does what it can by itself, then prints the one thing the
# person has to do on the TV and stops. Run it again after each. Ends with what this TV can and can't do.
#   tv-helper-setup.sh [TV tailnet IP]                     next step (the only TV that's on, if no IP)
#   tv-helper-setup.sh [IP] terminal <code> <port>         the code and port from the TV's
#                                                          Developer options > Wireless debugging > Pair device with pairing code
#   tv-helper-setup.sh [IP] code <6 characters>            the remote-pairing code the TV shows (TVs without the terminal)
#   tv-helper-setup.sh [IP] basic                          skip the terminal on a TV that could have it
D=/opt/ccrd; TS="$D/tailscale --socket=$D/ts.sock"
c(){ env -u no_proxy -u NO_PROXY curl -s --socks5-hostname 127.0.0.1:1055 "$@"; }
case "$1" in 100.*) IP=$1; shift;; *) IP=$($TS status --json | python3 -c '
import json, sys
print(next((p["TailscaleIPs"][0] for p in json.load(sys.stdin).get("Peer", {}).values() if p.get("HostName") == "ccrd-tv" and p.get("Online")), ""))');; esac
[ -z "$IP" ] && { echo "No TV is on. Open Claude's Computer on the TV first."; exit 1; }
h(){ c -m 120 -X POST "http://$IP:6084/tv/helper" -G --data-urlencode "do=$1" --data-urlencode "arg=$2"; }
sh(){ h shell "$1"; }
rep=$(c -m 15 http://$IP:6084/tv/report)
[ -z "$rep" ] && { echo "The TV at $IP doesn't answer: open Claude's Computer on it."; exit 1; }
read -r ANDROID PKG MODEL < <(echo "$rep" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["tv"]["android"].split(".")[0], d["app"]["id"], d["tv"]["model"].replace(" ","_"))' 2>/dev/null)
case "$ANDROID" in ''|*[!0-9]*) echo "The TV at $IP sent a report this can't read. Update the app on the TV (\"update the TVs\"), then try again."; exit 1;; esac
summary(){
  rem=$(h status); term=no; [ "$(sh 'echo ok' | tr -d '\r\n')" = ok ] && term=yes
  echo "This TV ($MODEL, Android $ANDROID):"
  if [ "$rem" = paired ]; then echo "  yes  updates without pressing Install, reopen after an update or a crash, turn on and off, press buttons"
  else echo "  no   hands-free updates and power (the helper isn't paired as a remote)"; fi
  if [ $term = yes ]; then echo "  yes  command line (settings, screenshots, logs, silent installs) while wireless debugging is on"
  elif [ "$ANDROID" -ge 11 ]; then echo "  no   command line: turn on Developer options > Wireless debugging, then run this with: terminal <code> <port>"
  else echo "  no   command line (needs Android 11 or newer)"; fi
}

st=$(h status)
case "$st" in
  "not installed"|"the helper isn't installed")
    r=$(h install)
    case "$r" in *allow*) echo "ON THE TV: the setting 'Install unknown apps' is open. Turn it on for Claude's Computer, press Back. Then run this again."; exit 0;; esac
    echo "ON THE TV: Android asks to install 'Claude's Computer helper'. Move to Install and press OK. Then run this again."; exit 0;;
esac

# The terminal (Android 11+): with it, the rest needs no button presses.
if [ "$1" = terminal ]; then
  r=$(h adbpair "$2 $3"); case "$r" in *Success*) echo "Terminal paired.";; *) echo "Pairing failed: $r"; exit 1;; esac
fi
term=no; [ "$(sh 'echo ok' | tr -d '\r\n')" = ok ] && term=yes
if [ $term = no ] && [ "$ANDROID" -ge 11 ] && [ "$1" != basic ] && [ "$1" != code ] && [ "$st" != paired ]; then
  echo "ON THE TV (recommended; Claude then does the rest by itself): Settings > System > About > press OK on 'Android TV OS build' 7 times."
  echo "Then Settings > System > Developer options > Wireless debugging: turn it on, open 'Pair device with pairing code',"
  echo "and tell Claude the code and the port. Claude runs: $0 $IP terminal <code> <port>"
  echo "Without it: $0 $IP basic   (two more button presses and a code to read out)"
  exit 0
fi

if [ $term = yes ]; then
  sh "appops set $PKG REQUEST_INSTALL_PACKAGES allow; appops set dev.ccrd.helper ACTIVATE_VPN allow" >/dev/null
  if [ "$st" != paired ]; then
    r=$(h pair); [ "$r" = ok ] || { echo "Remote pairing didn't start: $r"; exit 1; }
    sleep 2
    code=$(sh 'uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; cat /data/local/tmp/ui.xml' | grep -oE 'text="[0-9A-F]{6}"' | head -1 | cut -d'"' -f2)
    [ -z "$code" ] && { echo "Couldn't read the code on the TV. Ask the person for it: $0 $IP code <code>"; exit 0; }
    r=$(h code "$code"); [ "$r" = ok ] || { echo "Remote pairing failed: $r"; exit 1; }
  fi
  summary; exit 0
fi

# Without the terminal: the person presses OK on the VPN question and reads out the pairing code.
if [ "$1" = code ]; then
  r=$(h code "$2"); [ "$r" = ok ] || { echo "Pairing failed: $r. Run this again for a new code."; exit 1; }
  summary; exit 0
fi
if [ "$st" != paired ]; then
  r=$(h pair); [ "$r" = ok ] || { echo "Remote pairing didn't start: $r"; exit 1; }
  echo "ON THE TV: a 6-character code is showing. Ask the person to read it out (leave it on screen), then: $0 $IP code <code>"; exit 0
fi
r=$(h keys "wait:1")
case "$r" in *"isn't allowed"*) h allow >/dev/null
  echo "ON THE TV: Android asks to allow a VPN connection for the helper (it stays inside the TV). Move to OK and press it. Then run this again."; exit 0;; esac
summary
