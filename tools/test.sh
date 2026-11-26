#!/bin/bash
# Runs the project's automated checks (no TV needed): computer names, the helper's protocol pieces, the Go core.
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"; fail=0
echo "== computer names"
while read -r name want; do
  got=$(CCRD_CONF=/dev/null CCRD_NAME="$name" bash cloud/computer-name.sh)
  if [ "$got" = "$want" ]; then echo "ok    '$name' -> $got"; else echo "FAIL  '$name' -> $got (want $want)"; fail=1; fi
done <<'CASES'
Work ccrd-work
My_Office! ccrd-my-office
tv2 ccrd-pc-tv2
main ccrd
CASES
[ "$(CCRD_CONF=/dev/null CCRD_NAME= bash cloud/computer-name.sh)" = ccrd ] && echo "ok    '' -> ccrd" || { echo "FAIL  empty name"; fail=1; }
echo "== helper (Java)"
JAR=tv-app/build/sdk/platforms/android-34/android.jar; O=$(mktemp -d)
if [ -f $JAR ]; then
  javac -nowarn -cp $JAR -d "$O" helper/src/dev/ccrd/helper/{Pb,Identity,Packets}.java helper/test/*.java 2>&1 | grep -v "^Picked up\|^warning\|^Note" 
  java -cp "$O" dev.ccrd.helper.HelperTests 2>&1 | grep -v "^Picked up" ; [ ${PIPESTATUS[0]} = 0 ] || fail=1
else echo "skipped: run tv-app/build.sh once first (it downloads the Android SDK)"; fi
rm -rf "$O"
echo "== network core (Go)"
(cd tv-app/ccrdnet && GOFLAGS=-mod=mod go test -run 'TestIsDesktopName|TestSetDesktop' . 2>&1 | tail -3) ; [ ${PIPESTATUS[0]} = 0 ] || fail=1
[ $fail = 0 ] && echo "ALL OK" || { echo "SOME CHECKS FAILED"; exit 1; }
