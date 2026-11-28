#!/bin/bash
# Builds the TV app from scratch on 64-bit Linux. You need: Go 1.24 or newer (it fetches the exact
# version go.mod asks for by itself), a JDK (javac, keytool), curl, unzip.
# Everything else (Android build tools and NDK, gomobile, Tailscale with our two patches) is downloaded into
# tv-app/build/, which git ignores. The result is tv-app/out/claudes-computer.apk.
#
# Signing: the first build creates build/release.keystore and build/keystore.pass. Keep both: Android only
# accepts an update signed with the same key. To use your own key, set KEYSTORE and KS_PASS.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); B=$HERE/build; mkdir -p "$B"
export PATH=$PATH:/usr/local/go/bin:$B/bin GOFLAGS=-mod=mod
REPO=https://dl.google.com/android/repository

fetch() { # zip-name target-dir
  [ -d "$B/$2" ] && return
  echo "downloading $1"
  curl -fsSL -o "$B/dl.zip" "$REPO/$1" && mkdir -p "$B/$2.tmp" && unzip -q "$B/dl.zip" -d "$B/$2.tmp" && rm "$B/dl.zip"
  mkdir -p "$(dirname "$B/$2")" && mv "$B/$2.tmp"/* "$B/$2" && rmdir "$B/$2.tmp"
}
fetch build-tools_r37_linux.zip build-tools          # aapt2, d8, zipalign, apksigner (d8 must be 37+)
fetch platform-34-ext7_r03.zip sdk/platforms/android-34
fetch android-ndk-r27c-linux.zip sdk/ndk/android-ndk-r27c
export ANDROID_HOME=$B/sdk ANDROID_NDK_HOME=$B/sdk/ndk/android-ndk-r27c

# gomobile turns the Go library (ccrdnet/) into something the Android app can call.
if [ ! -x "$B/bin/gomobile" ]; then
  GOBIN=$B/bin go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20261117202452-47699113848a
  GOBIN=$B/bin go install golang.org/x/mobile/cmd/gobind@v0.0.0-20261117202452-47699113848a
fi

# Tailscale, patched: faster relay traffic (../cloud/tailscale-relay-speed.patch) and DNS on Android
# (tailscale-android-dns.patch). ccrdnet/go.mod points at build/tailscale.
TSV=$(awk '/^[[:space:]]*(require[[:space:]]+)?tailscale.com v/{print $NF; exit}' "$HERE/ccrdnet/go.mod")
if [ ! -f "$B/tailscale/.patched-$TSV" ]; then
  (cd /tmp && go mod download tailscale.com@$TSV)
  rm -rf "$B/tailscale" && cp -r "$(go env GOMODCACHE)/tailscale.com@$TSV" "$B/tailscale" && chmod -R u+w "$B/tailscale"
  (cd "$B/tailscale" && patch -p1 -s < "$HERE/../cloud/tailscale-relay-speed.patch" && patch -p1 -s < "$HERE/tailscale-android-dns.patch")
  touch "$B/tailscale/.patched-$TSV"
fi

# The Go library -> libs/
# ABIS: which processors to build for. TVs are ARM; the test lab's emulator is x86 (ABIS=android/arm,android/386).
(cd "$HERE/ccrdnet" && gomobile bind -target=${ABIS:-android/arm} -androidapi 21 -ldflags="-s -w" -o "$B/ccrdnet.aar" .)
rm -rf "$B/aar" && mkdir "$B/aar" && (cd "$B/aar" && unzip -q "$B/ccrdnet.aar")
rm -rf "$HERE/libs" && mkdir -p "$HERE/libs/jni" && cp "$B/aar/classes.jar" "$HERE/libs/ccrdnet-classes.jar" && cp -r "$B/aar/jni/"* "$HERE/libs/jni/"

# Signing key. Each app id has its own key, and Android refuses an update signed with a different one. A
# household with an older app id keeps its key in build/keystore-<id>.jks (+ keystore-<id>.pass): used by itself.
if [ -z "$KEYSTORE" ] && [ -n "$APP_ID" ] && [ -f "$B/keystore-$APP_ID.jks" ]; then
  KEYSTORE=$B/keystore-$APP_ID.jks; KS_PASS=$(cat "$B/keystore-$APP_ID.pass")
elif [ -z "$KEYSTORE" ] && [ -n "$APP_ID" ]; then
  echo "no key for $APP_ID (build/keystore-$APP_ID.jks): its TVs would refuse this build" >&2; exit 1
fi
# RELEASE=1 (the GitHub release workflow): only the real release key, given as KEYSTORE; never make one.
if [ "$RELEASE" = 1 ] && { [ -z "$KEYSTORE" ] || [ ! -f "$KEYSTORE" ]; }; then
  echo "RELEASE=1 needs the release key in KEYSTORE (the TV_KEYSTORE_B64 secret); refusing to sign with another" >&2; exit 1
fi
if [ -z "$KEYSTORE" ]; then
  KEYSTORE=$B/release.keystore
  if [ ! -f "$KEYSTORE" ]; then
    echo "NOTE: no signing key here, so this makes a new local one. A build signed with it is for testing only:" >&2
    echo "TVs that installed the published app refuse it as an update. Releases are signed only by GitHub." >&2
    head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$B/keystore.pass"
    keytool -genkeypair -keystore "$KEYSTORE" -storepass "$(cat "$B/keystore.pass")" -alias app -keyalg RSA \
      -keysize 2048 -validity 20000 -dname "CN=Claude's Computer" >/dev/null 2>&1
    echo "created signing key $KEYSTORE (keep it, and build/keystore.pass, to sign updates)"
  fi
  KS_PASS=$(cat "$B/keystore.pass")
fi

# Build number: minutes since 2026-01-01 (UTC) of the commit being built, or of now when files have changed since.
# Every build that differs gets a higher number, on any machine; the name (versionName in the manifest) changes
# only with a release. The TV reports both.
T=$(cd "$HERE" && { git diff --quiet HEAD -- . ../helper 2>/dev/null && git log -1 --format=%ct 2>/dev/null; } || date +%s)
BUILD=$(( (T - 1767225600) / 60 ))
# The app
BT=$B/build-tools; JAR=$B/sdk/platforms/android-34/android.jar; LIB=$HERE/libs/ccrdnet-classes.jar
cd "$HERE"; rm -rf out && mkdir -p out/gen out/classes out/dex out/apk
$BT/aapt2 compile --dir res -o out/res.zip
# APP_ID=...: build under another app id (a household whose TVs have an older one), from this same code.
MAN=AndroidManifest.xml
if [ -n "$APP_ID" ]; then sed "s/package=\"dev.ccrd.tv\"/package=\"$APP_ID\"/" AndroidManifest.xml > out/AndroidManifest.xml; MAN=out/AndroidManifest.xml; fi
# The repair helper (../helper): its own small app, signed with this same key (it only obeys a caller with its own
# signature) and carried inside this one as assets/helper.apk, which the app installs when asked.
H=$HERE/../helper; HO=$HERE/out/helper; mkdir -p $HO/classes $HO/dex out/assets && cp -r assets/. out/assets/
$BT/aapt2 link -I $JAR --manifest $H/AndroidManifest.xml -o $HO/base.apk --min-sdk-version 23 --target-sdk-version 28 --version-code $BUILD --replace-version
javac -nowarn -source 8 -target 8 -bootclasspath $JAR -d $HO/classes $(find $H/src -name '*.java') 2>&1 | grep -v "^warning" || true
$BT/d8 --lib $JAR --min-api 23 --output $HO/dex $(find $HO/classes -name '*.class')
cp $HO/base.apk $HO/unsigned.apk && zip -q -j $HO/unsigned.apk $HO/dex/classes.dex
# The helper carries adb for Android (helper/jniLibs, see helper/jniLibs/LADB-LICENSE.txt) as lib/<abi>/libadb.so.
# (Left out of an emulator build: adb here is ARM only, and x86 emulators refuse an app with only ARM code.)
case "$ABIS" in *386*|*amd64*) ;; *) mkdir -p $HO/lib && cp -r $H/jniLibs/armeabi-v7a $HO/lib/ && (cd $HO && zip -q -r unsigned.apk lib);; esac
$BT/zipalign -f -p 4 $HO/unsigned.apk $HO/aligned.apk
$BT/apksigner sign --ks "$KEYSTORE" --ks-pass pass:"$KS_PASS" --out out/assets/helper.apk $HO/aligned.apk || { echo "helper build failed"; exit 1; }
rm -f out/assets/helper.apk.idsig
$BT/aapt2 link -I $JAR --manifest $MAN -A out/assets -o out/base.apk out/res.zip --java out/gen --min-sdk-version 21 --target-sdk-version 28 --version-code $BUILD --replace-version
javac -nowarn -source 8 -target 8 -bootclasspath $JAR -cp $LIB -d out/classes $(find src out/gen -name '*.java') 2>&1 | grep -v "^warning" || true
[ -f out/classes/dev/ccrd/tv/MainActivity.class ] || { echo "Java compile failed; no app built."; exit 1; }
$BT/d8 --lib $JAR --min-api 21 --output out/dex $(find out/classes -name '*.class') $LIB
cd out && cp base.apk unsigned.apk && zip -q -j unsigned.apk dex/classes.dex
mkdir -p apk/lib && cp -r ../libs/jni/* apk/lib/ && (cd apk && zip -q -r ../unsigned.apk lib)
$BT/zipalign -f -p 4 unsigned.apk aligned.apk
$BT/apksigner sign --ks "$KEYSTORE" --ks-pass pass:"$KS_PASS" --out claudes-computer${APP_ID:+-$APP_ID}.apk aligned.apk
CERT=$($BT/apksigner verify --print-certs claudes-computer${APP_ID:+-$APP_ID}.apk 2>/dev/null | awk '/certificate SHA-256 digest/{print $NF; exit}')
if [ "$RELEASE" = 1 ] && [ "$CERT" != "$(cat "$HERE/RELEASE_CERT.sha256")" ]; then
  echo "signed with the wrong key ($CERT), not the release key in tv-app/RELEASE_CERT.sha256: not releasing" >&2; exit 1
fi
[ "$CERT" = "$(cat "$HERE/RELEASE_CERT.sha256")" ] || echo "NOTE: test build (not the release key): don't send it to TVs that have the published app" >&2
echo "built: $(pwd)/claudes-computer${APP_ID:+-$APP_ID}.apk (build $BUILD)"
