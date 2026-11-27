#!/bin/bash
# Recreates what newer TVs do in standby, on an Android TV 14 emulator, and checks our answer to it.
#   tools/tv-standby-lab.sh <claudes-computer.apk> [output dir]
# TV makers turn on Android's Low Power Standby: seconds after the screen goes off, apps that aren't on screen lose
# the network. The emulator ships with it off, so this turns it on (a config overlay, as root), then:
#   A. shows the cut-off happening to our app with no exemption,
#   B. applies the exemption the helper setup uses (cloud/tv-helper-setup.sh tune) and shows whether it holds,
#      including after a restart (TV Settings re-applies the Energy mode at boot).
# Needs a userdebug emulator (adb root). Writes summary.txt and the raw dumps.
APK=$1; OUT=${2:-standby-out}; mkdir -p "$OUT"; PKG=${PKG:-dev.ccrd.tv}; H=dev.ccrd.helper
ADB=$(command -v adb); adb(){ timeout "${T:-120}" "$ADB" "$@"; }
sh(){ adb shell "$@" 2>&1 | tr -d '\r'; }
say(){ echo "$*" | tee -a "$OUT/summary.txt"; }
booted(){ T=600 adb wait-for-device; for i in $(seq 1 120); do [ "$(sh getprop sys.boot_completed)" = 1 ] && return 0; sleep 5; done; return 1; }
lps(){ sh dumpsys power | awk '/Low Power Standby Controller:/{p=1} p{print} p&&/mAllowedFeatures=/{exit}' | head -45; }
v(){ lps | sed -n "s/^ *$1=//p" | head -1; }
uidof(){ sh dumpsys package "$1" | sed -n 's/.*userId=\([0-9]*\).*/\1/p' | head -1; }
# What the network policy says about a uid right now: is it on the standby allow list, and is it blocked?
net(){ local u=$1; sh dumpsys netpolicy > "$OUT/netpolicy-$2.txt"; echo "standby-mode=$(grep -m1 -o 'Low Power Standby mode: [a-z]*' "$OUT/netpolicy-$2.txt" | awk '{print $NF}') allowlisted=$(grep -A40 -i 'low power standby allowlist' "$OUT/netpolicy-$2.txt" | grep -c -w "$u") blocked=$(grep -E "^ *(UID=)?$u[ :]" "$OUT/netpolicy-$2.txt" | grep -o -i 'blocked[^ ]*=[^ ]*' | tr '\n' ' ')"; }
sleep_tv(){ sh input keyevent SLEEP; sleep "${1:-25}"; }
wake_tv(){ sh input keyevent WAKEUP; sleep 5; }

: > "$OUT/summary.txt"
say "TV: $(sh getprop ro.product.model), Android $(sh getprop ro.build.version.release), build type $(sh getprop ro.build.type)"
adb root >/dev/null 2>&1; sleep 3; adb wait-for-device
[ "$(sh id -u)" = 0 ] || { say "no root on this image: can't turn Low Power Standby on. Stopping."; exit 0; }
sh settings put global verifier_verify_adb_installs 0 >/dev/null; sh settings put global package_verifier_enable 0 >/dev/null
unzip -p "$APK" assets/helper.apk > "$OUT/helper.apk" 2>/dev/null
say "install: $(T=300 adb install -r --no-streaming "$APK" 2>&1 | tail -1) / helper: $(T=300 adb install -r --no-streaming "$OUT/helper.apk" 2>&1 | tail -1)"; rm -f "$OUT/helper.apk"
say "has TV Settings energy modes code: $(sh pm list packages | grep -c com.android.tv.settings)"
say "before: supported=$(v mSupportedConfig) enabled=$(v mIsEnabled)"

# Turn the feature on the way a TV maker does: framework config, read at system start.
say "--- turning Low Power Standby on"
sh cmd overlay fabricate --target android --name CcrdLps android:bool/config_lowPowerStandbySupported 0x12 0xffffffff
sh cmd overlay fabricate --target android --name CcrdLpsOn android:bool/config_lowPowerStandbyEnabledByDefault 0x12 0xffffffff
sh cmd overlay enable --user 0 com.android.shell:CcrdLps; sh cmd overlay enable --user 0 com.android.shell:CcrdLpsOn
sh cmd overlay list android | grep -i ccrd | tee -a "$OUT/summary.txt"
sh device_config set_sync_disabled_for_tests persistent >/dev/null
sh device_config put low_power_standby enable_policy true; sh device_config put low_power_standby enable_standby_ports true
sh settings put global low_power_standby_enabled 1
adb shell 'stop; sleep 3; start' ; sleep 20; booted; sleep 30; adb root >/dev/null 2>&1; sleep 3
say "after framework restart: supported=$(v mSupportedConfig) enabled=$(v mIsEnabled) custom-policy=$(v mEnableCustomPolicy) timeout-ms=$(v mStandbyTimeoutConfig)"
lps > "$OUT/lps-1-on.txt"
[ "$(v mSupportedConfig)" = true ] || { say "couldn't turn it on here (the overlay didn't take). Stopping."; cat "$OUT/lps-1-on.txt" >> "$OUT/summary.txt"; exit 0; }

U=$(uidof $PKG); UH=$(uidof $H); say "our uids: app=$U helper=$UH"
open_app(){ sh am start -W -n $PKG/dev.ccrd.tv.MainActivity >/dev/null; sleep 12; }

say "--- A. no exemption: screen off"
open_app; say "screen on:  $(net $U a-on)  policy=$(v mIdentifier) exempt=[$(v mExemptPackages)]"
sleep_tv 25; say "screen off: active=$(v mIsActive)  $(net $U a-off)  allowed-uids=$(v 'Allowed UIDs')"
lps > "$OUT/lps-2-off-noexempt.txt"; wake_tv

say "--- B. the exemption from tv-helper-setup.sh tune"
ID=$(v mIdentifier); say "energy mode identifier: [$ID]"
for id in $ID low_energy_use moderate_energy_use high_energy_use; do sh cmd device_config put low_power_standby "policy_${id}_exempt_packages" "$PKG,$H" >/dev/null; done
say "written: $(sh cmd device_config list low_power_standby | tr '\n' ' ')"
say "(applies when TV Settings re-applies the Energy mode: at boot) restarting the TV..."
adb reboot; sleep 15; booted; sleep 45; adb root >/dev/null 2>&1; sleep 3
say "after restart: enabled=$(v mIsEnabled) policy=$(v mIdentifier) exempt=[$(v mExemptPackages)]"
lps > "$OUT/lps-3-restart.txt"
open_app; say "screen on:  $(net $U b-on)"
sleep_tv 25; say "screen off: active=$(v mIsActive)  $(net $U b-off)  allowed-uids=$(v 'Allowed UIDs')"
say "app while off: $(sh pidof $PKG >/dev/null && echo running || echo 'not running'), $(sh dumpsys activity processes | grep -A12 "ProcessRecord.*$PKG" | grep -m1 -o 'curProcState=[0-9A-Z_]*')"
lps > "$OUT/lps-4-off-exempt.txt"; wake_tv

say "--- C. the fallback for TVs with no exempt list: switch the cut-off off"
sh settings put global low_power_standby_enabled 0; sleep 2
sleep_tv 20; say "screen off with it disabled: enabled=$(v mIsEnabled) active=$(v mIsActive)  $(net $U c-off)"; wake_tv
