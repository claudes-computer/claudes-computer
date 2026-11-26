#!/bin/bash
# Sets up the repair helper on a TV, one step per run: it does what it can by itself, then prints the one thing the
# person has to do on the TV and stops. Run it again after each. Ends with what this TV can and can't do.
#   tv-helper-setup.sh [TV tailnet IP]                     next step (the only TV that's on, if no IP)
#   tv-helper-setup.sh [IP] terminal <code> <port>         the code and port from the TV's
#                                                          Developer options > Wireless debugging > Pair device with pairing code
#   tv-helper-setup.sh [IP] code <6 characters>            the remote-pairing code the TV shows (TVs without the terminal)
#   tv-helper-setup.sh [IP] basic                          skip the terminal on a TV that could have it
#   tv-helper-setup.sh [IP] tune                           (again) the settings the helper needs; part of every
#                                                          setup with the terminal. Each change and its undo goes in
#                                                          /opt/ccrd/tv/tuneup-<TV>.txt
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


# The settings that keep the app reachable and the helper able to help, each noted with its undo. Needs the terminal.
tune(){
  local log=$D/tv/tuneup-$MODEL.txt old cur
  note(){ echo "$(date '+%F %H:%M')  $1   | undo: $2" >> "$log"; echo "  changed: $1"; }
  t(){ sh "$1" | tr -d '\r'; }
  # Wireless debugging forgets a pairing after 7 days without use.
  old=$(t 'settings get global adb_allowed_connection_time' | tr -d '\n')
  if [ "$old" != 0 ]; then
    t 'settings put global adb_allowed_connection_time 0' >/dev/null
    if [ "$old" = null ]; then note "wireless debugging pairing never expires" "settings delete global adb_allowed_connection_time"
    else note "wireless debugging pairing never expires (was $old)" "settings put global adb_allowed_connection_time $old"; fi
  fi
  # The helper turns wireless debugging back on after a restart.
  if ! t 'dumpsys package dev.ccrd.helper' | grep -q 'WRITE_SECURE_SETTINGS: granted=true'; then
    t 'pm grant dev.ccrd.helper android.permission.WRITE_SECURE_SETTINGS' >/dev/null
    note "helper may change system settings (turns wireless debugging back on after a restart)" "pm revoke dev.ccrd.helper android.permission.WRITE_SECURE_SETTINGS"
  fi
  # The helper opens the app directly (Android blocks background apps from opening screens otherwise).
  if ! t 'appops get dev.ccrd.helper SYSTEM_ALERT_WINDOW' | grep -q allow; then
    t 'appops set dev.ccrd.helper SYSTEM_ALERT_WINDOW allow' >/dev/null
    note "helper may open the app directly (display over other apps)" "appops set dev.ccrd.helper SYSTEM_ALERT_WINDOW default"
  fi
  # Android 13+ TVs (Low Power Standby, the "Energy modes" setting): seconds after the TV turns off, every app that
  # isn't on screen loses the network, so the app drops off the private network. The Energy mode's list of exempt
  # apps can be extended through a device setting that TV Settings reads at every start.
  [ "$ANDROID" -ge 13 ] || return 0
  local lps; lps=$(t 'dumpsys power' | awk '/Low Power Standby Controller:/{p=1} p&&/=/{print} /mAllowedReasons=/{exit}')
  v(){ echo "$lps" | sed -n "s/^ *$1=//p" | head -1; }
  if [ "$(v mSupportedConfig)" != true ] || [ "$(v mIsEnabled)" != true ]; then echo "  standby: this TV doesn't cut apps off the network"; return 0; fi
  if [ "$(v mEnableCustomPolicy)" != true ]; then
    t 'settings put global low_power_standby_enabled 0' >/dev/null
    note "standby network cut-off off (this TV has no exempt list; comes back on at a restart)" "settings put global low_power_standby_enabled 1"
    return 0
  fi
  local id pk; id=$(v mIdentifier); pk=$(v mExemptPackages)
  case ",$pk," in *",$PKG,"*) case ",$pk," in *",dev.ccrd.helper,"*) echo "  standby: the app and the helper are already exempt ($id)"; return 0;; esac;; esac
  [ -n "$id" ] || { echo "  standby: couldn't read the Energy mode; nothing changed"; return 0; }
  old=$(t "cmd device_config get low_power_standby policy_${id}_exempt_packages" | tr -d '\n')
  cur=$(echo "$pk,$PKG,dev.ccrd.helper" | tr ',' '\n' | grep -v '^$' | sort -u | paste -sd,)
  t "cmd device_config put low_power_standby policy_${id}_exempt_packages $cur" >/dev/null
  if [ "$old" = null ] || [ -z "$old" ]; then note "standby: the app and the helper keep the network (Energy mode $id)" "cmd device_config delete low_power_standby policy_${id}_exempt_packages"
  else note "standby: the app and the helper keep the network (Energy mode $id; was $old)" "cmd device_config put low_power_standby policy_${id}_exempt_packages $old"; fi
  echo "  standby: takes effect when the TV restarts (or the Energy mode is chosen again in Settings)."
  echo "           To apply now: restart the TV (it comes back to the app by itself if the helper is paired)."
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

if [ "$1" = tune ]; then
  [ $term = yes ] || { echo "Tuning needs the command line (wireless debugging on, and paired)."; exit 1; }
  tune; exit 0
fi
if [ $term = yes ]; then
  sh "appops set $PKG REQUEST_INSTALL_PACKAGES allow; appops set dev.ccrd.helper ACTIVATE_VPN allow" >/dev/null
  if [ "$st" != paired ]; then
    r=$(h pair); [ "$r" = ok ] || { echo "Remote pairing didn't start: $r"; exit 1; }
    sleep 2
    code=$(sh 'rm -f /data/local/tmp/ui.xml; uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; cat /data/local/tmp/ui.xml' | grep -oE 'text="[0-9A-F]{6}"' | head -1 | cut -d'"' -f2)
    [ -z "$code" ] && { echo "Couldn't read the code on the TV. Ask the person for it: $0 $IP code <code>"; exit 0; }
    r=$(h code "$code"); [ "$r" = ok ] || { echo "Remote pairing failed: $r"; exit 1; }
  fi
  tune; summary; exit 0
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
