#!/bin/bash
# Recreates what newer TVs do in standby, on an unlocked (userdebug) Android 14 virtual device, and checks our
# answer to it.
#   tools/tv-standby-lab.sh <claudes-computer.apk> [output dir]
# with LPS_DEX (tools/lab/Lps.java built to a dex), LPS_OVERLAY (tools/lab/lps-overlay built to an apk) and a
# listener on the test host at PROBE_PORT (default 8099).
# TV makers turn on Android's Low Power Standby: seconds after the screen goes off, apps that aren't on screen lose
# the network. Stock images ship with it off, so this turns it on (a framework config overlay, as root), then:
#   A. shows the cut-off happening to our app with no exemption,
#   B. exempts our app and its helper, the way a TV's Energy mode list does, and shows the network come back,
#   C. shows the fallback for a TV with no exempt list: switching the cut-off off.
# "Network" is tested for real: a connection made as the app's own user id, which is what the firewall acts on.
# Needs root (adb root): Google's Cuttlefish userdebug builds have it; the SDK's TV emulator images don't.
APK=$1; OUT=${2:-standby-out}; mkdir -p "$OUT"; PKG=${PKG:-dev.ccrd.tv}; H=dev.ccrd.helper
ADB=$(command -v adb); adb(){ timeout "${T:-120}" "$ADB" "$@"; }
conn(){ [ -n "$CCRD_ADB_CONNECT" ] && { adb connect "$CCRD_ADB_CONNECT" >/dev/null 2>&1; sleep 1; }; return 0; }
sh(){ adb shell "$@" 2>&1 | tr -d '\r'; }
say(){ echo "$*" | tee -a "$OUT/summary.txt"; }
booted(){ for i in $(seq 1 150); do conn; [ "$(sh getprop sys.boot_completed)" = 1 ] && return 0; sleep 4; done; return 1; }
root(){ adb root >/dev/null 2>&1; sleep 4; conn; adb wait-for-device; }
lps(){ sh dumpsys power | awk '/Low Power Standby Controller:/{p=1} p{print} p&&/mAllowedFeatures=/{exit}' | head -45; }
v(){ lps | sed -n "s/^ *$1=//p" | head -1; }
tool(){ sh "CLASSPATH=/data/local/tmp/lps.dex app_process / Lps $*" | tail -1; }
uidof(){ sh dumpsys package "$1" | sed -n 's/.*userId=\([0-9]*\).*/\1/p' | head -1; }
# Can this app's user id open a connection right now? (root runs the test as that uid)
reach(){ sh "su $1 sh -c 'echo | toybox nc -w 5 $PROBE $PP >/dev/null 2>&1 && echo CONNECTS || echo BLOCKED'" | tail -1; }
sleep_tv(){ sh input keyevent SLEEP; sleep "${1:-20}"; }
wake_tv(){ sh input keyevent WAKEUP; sleep 4; sh input keyevent 82 >/dev/null; sleep 2; }

: > "$OUT/summary.txt"
conn; say "Device: $(sh getprop ro.product.model), Android $(sh getprop ro.build.version.release), build type $(sh getprop ro.build.type)"
root; [ "$(sh id -u)" = 0 ] || { say "no root on this image: can't turn Low Power Standby on. Stopping."; exit 0; }
sh settings put global verifier_verify_adb_installs 0 >/dev/null; sh settings put global package_verifier_enable 0 >/dev/null
unzip -p "$APK" assets/helper.apk > "$OUT/helper.apk" 2>/dev/null
say "install: $(T=300 adb install -r --no-streaming "$APK" 2>&1 | tail -1) / helper: $(T=300 adb install -r --no-streaming "$OUT/helper.apk" 2>&1 | tail -1)"; rm -f "$OUT/helper.apk"
[ -n "$LPS_DEX" ] && adb push "$LPS_DEX" /data/local/tmp/lps.dex >/dev/null 2>&1
# The probe target is a listener on the test host (PROBE_PORT, started by whoever runs this), reached at the
# device's own gateway: no internet needed.
PP=${PROBE_PORT:-8099}; PROBE=""
for g in $(sh "ip route show table all 2>/dev/null | sed -n 's/.*default via \([0-9.]*\).*/\1/p' | sort -u") 192.168.97.1 192.168.96.1 10.0.2.2; do
  [ "$(sh "echo | toybox nc -w 4 $g $PP >/dev/null 2>&1 && echo ok")" = ok ] && { PROBE=$g; break; }
done
say "network probe target: ${PROBE:-NONE FOUND} port $PP"
[ -n "$PROBE" ] || say "(no reachable probe target: the CONNECTS/BLOCKED lines below can't be trusted; see the allowed-uids values)"
say "before: supported=$(v mSupportedConfig) enabled=$(v mIsEnabled)   TV Settings present: $(sh pm list packages | grep -c com.android.tv.settings)"

say "--- turning Low Power Standby on, the way a TV maker's build has it"
# A built-in (immutable) overlay in /product/overlay: the power service reads this config during start-up, before
# overlays enabled at run time reach it (a first version that used "cmd overlay fabricate" showed exactly that).
remount(){ root; adb remount 2>&1 | tail -2; }
R=$(remount); say "remount: $(echo "$R" | tr '\n' ' ')"
if echo "$R" | grep -qi "reboot"; then adb reboot; sleep 15; booted; sleep 10; say "remount again: $(remount | tr '\n' ' ')"; fi
sh mkdir -p /product/overlay/config
adb push "$LPS_OVERLAY" /product/overlay/CcrdLps.apk >/dev/null 2>&1; sh chmod 644 /product/overlay/CcrdLps.apk
cfg=$(sh cat /product/overlay/config/config.xml 2>/dev/null | grep -v "No such file")
line='    <overlay package="dev.ccrd.lpsoverlay" mutable="false" enabled="true" />'
if echo "$cfg" | grep -q "</config>"; then echo "$cfg" | sed "s#</config>#$line\n</config>#" > "$OUT/overlay-config.xml"
else printf '<?xml version="1.0" encoding="utf-8"?>\n<config>\n%s\n</config>\n' "$line" > "$OUT/overlay-config.xml"; fi
adb push "$OUT/overlay-config.xml" /product/overlay/config/config.xml >/dev/null 2>&1; sh chmod 644 /product/overlay/config/config.xml
say "overlay installed: $(sh ls -la /product/overlay/CcrdLps.apk | awk '{print $5, $NF}')"
sh device_config set_sync_disabled_for_tests persistent >/dev/null
sh device_config put low_power_standby enable_policy true
sh settings put global low_power_standby_enabled 1
adb reboot; sleep 15; booted; sleep 25; root; wake_tv
say "overlay state: $(sh cmd overlay list android | grep -i ccrd | tr '\n' ' ')"
say "after restart: supported=$(v mSupportedConfig) enabled=$(v mIsEnabled) custom-policy=$(v mEnableCustomPolicy) timeout-ms=$(v mStandbyTimeoutConfig)"
lps > "$OUT/lps-1-on.txt"
[ "$(v mSupportedConfig)" = true ] || { say "couldn't turn it on here (the overlay didn't take). Stopping."; cat "$OUT/lps-1-on.txt" >> "$OUT/summary.txt"; exit 0; }
[ "$(v mIsEnabled)" = true ] || say "enable via the power manager: $(tool enable true)"

U=$(uidof $PKG); UH=$(uidof $H); say "our user ids: app=$U helper=$UH"
open_app(){ wake_tv; sh am start -W -n $PKG/dev.ccrd.tv.MainActivity >/dev/null; sleep 10; }

say "--- A. no exemption"
say "policy: $(tool policy plain '' 0)"
open_app;    say "screen on:   app $(reach $U)   helper $(reach $UH)"
sleep_tv 20; say "screen off:  app $(reach $U)   helper $(reach $UH)   (standby active=$(v mIsActive), allowed uids=$(v 'Allowed UIDs'))"
lps > "$OUT/lps-2-off-noexempt.txt"; sh dumpsys netpolicy > "$OUT/netpolicy-a.txt"

say "--- B. our app and helper on the exempt list"
wake_tv; say "policy: $(tool policy ccrd_test "$PKG,$H" 0)"
open_app;    say "screen on:   app $(reach $U)   helper $(reach $UH)"
sleep_tv 20; say "screen off:  app $(reach $U)   helper $(reach $UH)   (standby active=$(v mIsActive), allowed uids=$(v 'Allowed UIDs'))"
say "app while off: $(sh pidof $PKG >/dev/null && echo running || echo 'not running'), $(sh dumpsys activity processes | grep -A12 "ProcessRecord.*$PKG" | grep -m1 -o 'curProcState=[0-9A-Z_]*')"
lps > "$OUT/lps-3-off-exempt.txt"; sh dumpsys netpolicy > "$OUT/netpolicy-b.txt"

say "--- C. no exempt list, cut-off switched off (the fallback)"
wake_tv; tool policy plain '' 0 >/dev/null; sh settings put global low_power_standby_enabled 0; sleep 2
sleep_tv 20; say "screen off:  app $(reach $U)   (enabled=$(v mIsEnabled) active=$(v mIsActive))"
wake_tv; sh settings put global low_power_standby_enabled 1

A=$(grep -A2 '^--- A' "$OUT/summary.txt" | grep 'screen off' | grep -o 'app [A-Z]*' | head -1)
B=$(grep -A3 '^--- B' "$OUT/summary.txt" | grep 'screen off' | grep -o 'app [A-Z]*' | head -1)
say "RESULT: without exemption, screen off -> $A; with exemption -> $B"
