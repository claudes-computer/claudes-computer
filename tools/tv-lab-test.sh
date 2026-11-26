#!/bin/bash
# The test lab: checks a build on an Android TV emulator (or any TV on adb), no person needed.
#   tools/tv-lab-test.sh <claudes-computer.apk> [output dir, default lab-out]
# Needs adb on PATH and one device attached. Installs the app and its helper, opens the app, applies the settings
# the helper setup uses, turns the TV off and on, restarts it, and looks for crashes. Writes screenshots, logs and
# summary.txt. Fails (exit 1) only when the app doesn't install, doesn't open, or crashes.
APK=$1; OUT=${2:-lab-out}; mkdir -p "$OUT"
[ -f "$APK" ] || { echo "usage: $0 <apk> [out dir]"; exit 2; }
PKG=${PKG:-dev.ccrd.tv}; H=dev.ccrd.helper; FAIL=0      # PKG=... for a build under another app id
sh(){ adb shell "$@" 2>&1 | tr -d '\r'; }
say(){ echo "$*" | tee -a "$OUT/summary.txt"; }
shot(){ adb exec-out screencap -p > "$OUT/$1.png" 2>/dev/null; }
lps(){ sh dumpsys power | awk '/Low Power Standby Controller:/{p=1} p{print} p&&/mAllowedFeatures=|mAllowedReasons=/{n++} n>=1&&/^$/{exit}' | head -40; }
alive(){ [ -n "$(sh pidof $PKG)" ]; }
booted(){ adb wait-for-device; for i in $(seq 1 180); do [ "$(sh getprop sys.boot_completed)" = 1 ] && return 0; sleep 5; done; return 1; }

: > "$OUT/summary.txt"
REL=$(sh getprop ro.build.version.release); SDK=$(sh getprop ro.build.version.sdk)
say "TV: $(sh getprop ro.product.model), Android $REL (API $SDK), $(sh getprop ro.product.cpu.abi)"

# 1. Install and open
unzip -p "$APK" assets/helper.apk > "$OUT/helper.apk" 2>/dev/null
r=$(adb install -r "$APK" 2>&1 | tail -1); say "install app: $r"; case "$r" in *Success*) ;; *) exit 1;; esac
if [ -s "$OUT/helper.apk" ]; then say "install helper: $(adb install -r "$OUT/helper.apk" 2>&1 | grep -v '^$' | tail -2 | tr '\n' ' ')"; fi
rm -f "$OUT/helper.apk"
adb logcat -c
say "start: $(sh am start -W -n $PKG/dev.ccrd.tv.MainActivity | grep -E 'Status|Error|TotalTime' | tr '\n' ' ')"
sleep 20; shot 1-opened
if ! alive; then      # a TV that just started may restart Google Play services, and Android closes apps using it
  say "closed by Android: $(adb logcat -d | grep -m1 -o "Killing [0-9]*:$PKG.*" | cut -c1-160)"
  sh am start -W -n $PKG/dev.ccrd.tv.MainActivity >/dev/null; sleep 20; shot 1-opened
fi
if alive; then say "open: ok"; else
  say "open: FAILED (the app isn't running)"; FAIL=1
  adb logcat -d | grep -E "AndroidRuntime|$PKG|libgojni|DEBUG   :|Fatal signal" | tail -40 | cut -c1-300 >> "$OUT/summary.txt"
fi
say "in front: $(sh dumpsys activity activities | grep -m1 -E 'topResumedActivity|mResumedActivity' | grep -o '[a-z.]*/[A-Za-z.]*' | head -1)"

# 2. The settings the helper setup applies (cloud/tv-helper-setup.sh tune): do the commands work on this Android?
say "--- tune commands"
say "pairing expiry: $(sh settings put global adb_allowed_connection_time 0; sh settings get global adb_allowed_connection_time)"
say "helper settings permission: $(sh pm grant $H android.permission.WRITE_SECURE_SETTINGS; sh dumpsys package $H | grep -c 'WRITE_SECURE_SETTINGS: granted=true')"
say "helper opens the app directly: $(sh appops set $H SYSTEM_ALERT_WINDOW allow; sh appops get $H SYSTEM_ALERT_WINDOW | head -1)"
lps > "$OUT/standby-before.txt"
v(){ sed -n "s/^ *$1=//p" "$OUT/standby-before.txt" | head -1; }
say "standby cut-off: supported=$(v mSupportedConfig) enabled=$(v mIsEnabled) exempt-list=$(v mEnableCustomPolicy) mode=$(v mIdentifier)"
ID=$(v mIdentifier)
if [ -n "$ID" ]; then
  sh cmd device_config put low_power_standby "policy_${ID}_exempt_packages" "$PKG,$H" >/dev/null
  say "exempt list written: $(sh cmd device_config get low_power_standby policy_${ID}_exempt_packages)"
fi

# 3. Off and on again: the app must survive, and not be frozen
say "--- power off and on"
sh input keyevent SLEEP; sleep 45
say "screen: $(sh dumpsys power | grep -m1 -o 'mWakefulness=[A-Za-z]*')  standby active: $(lps | sed -n 's/^ *mIsActive=//p' | head -1)"
if alive; then say "app while off: running ($(sh dumpsys activity processes | grep -A12 "ProcessRecord.*$PKG" | grep -m1 -o 'curProcState=[0-9A-Z_]*'), frozen=$(sh dumpsys activity processes | grep -A40 "ProcessRecord.*$PKG" | grep -m1 -o 'isFrozen=[a-z]*'))"
else say "app while off: not running"; fi
sh input keyevent WAKEUP; sleep 8; shot 2-woke
alive && say "after wake: running" || say "after wake: not running"

# 4. Restart: does the exempt list take, and does the helper's start-up run?
say "--- restart"
adb logcat -d > "$OUT/logcat-before-restart.txt" 2>/dev/null
adb reboot; sleep 10
if booted; then
  sleep 40; shot 3-restarted
  lps > "$OUT/standby-after-restart.txt"
  say "exempt after restart: $(sed -n 's/^ *mExemptPackages=//p' "$OUT/standby-after-restart.txt" | head -1)  allowed uids: $(sed -n 's/^ *Allowed UIDs=//p' "$OUT/standby-after-restart.txt" | head -1)"
  say "helper at start-up: $(adb logcat -d -s ClaudeHelper:* | grep -c 'boot') log lines"
  say "app after restart: $(alive && echo running || echo 'not running (expected unless the helper is paired)')"
else say "restart: the TV didn't come back in 15 minutes"; fi

# 5. Crashes
adb logcat -d > "$OUT/logcat.txt" 2>/dev/null
cat "$OUT/logcat-before-restart.txt" "$OUT/logcat.txt" > "$OUT/all.txt" 2>/dev/null
C=$(grep -c -E "FATAL EXCEPTION|Fatal signal" "$OUT/all.txt"); OURS=$(grep -A3 -E "FATAL EXCEPTION|Fatal signal" "$OUT/all.txt" | grep -c -E "$PKG|$H|ccrd")
say "--- crashes: $OURS ours, $C on the TV in total"
[ "$OURS" -gt 0 ] && { grep -A12 -E "FATAL EXCEPTION|Fatal signal" "$OUT/all.txt" | grep -B2 -A10 -E "$PKG|$H" | head -40 >> "$OUT/summary.txt"; FAIL=1; }
rm -f "$OUT/all.txt"
say "RESULT: $([ $FAIL = 0 ] && echo PASS || echo FAIL)"
exit $FAIL
