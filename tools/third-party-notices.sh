#!/bin/bash
# Writes THIRD_PARTY_NOTICES.txt: the license of every outside module compiled into the TV app, plus the
# JavaScript we bundle. A copy goes in tv-app/assets so it ships inside the APK (the licenses ask for that).
# Run again after changing tv-app/ccrdnet/go.mod. Needs Go and network access to the Go module proxy.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/THIRD_PARTY_NOTICES.txt
GP=$(mktemp -d)
trap 'chmod -R u+w "$GP" 2>/dev/null; rm -rf "$GP"' EXIT

cd "$ROOT/tv-app/ccrdnet"
mods=$(GOPATH=$GP GOFLAGS=-mod=mod GOOS=android GOARCH=arm CGO_ENABLED=1 \
  go list -deps -f '{{with .Module}}{{if not .Main}}{{.Path}}@{{.Version}}{{end}}{{end}}' . | sort -u)
GOPATH=$GP go mod download $(echo "$mods") >/dev/null

{
  echo "Third-party software in Claude's Computer"
  echo "========================================="
  echo
  echo "The TV app includes the Go modules below (compiled in) and Kazuhiko Arase's QR Code Generator."
  echo "Each one's license follows. The Go standard library is under the same license as golang.org/x/crypto."
  for m in $mods; do
    dir=$(GOPATH=$GP go mod download -json "$m" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Dir"])')
    lic=$(ls "$dir" | grep -iE '^(LICENSE|LICENCE|COPYING)(\.md|\.txt)?$' | head -1)
    echo; echo "----------------------------------------------------------------------"
    echo "$m"; echo
    if [ -n "$lic" ]; then cat "$dir/$lic"; else echo "(no license file in the module; see its source)"; fi
  done
  echo; echo "----------------------------------------------------------------------"
  echo "QR Code Generator for JavaScript (tv-app/assets/qrcode.js)"; echo
  cat <<'EOF'
Copyright (c) 2009 Kazuhiko Arase
URL: http://www.d-project.com/

Licensed under the MIT license:
  http://www.opensource.org/licenses/mit-license.php

The word 'QR Code' is registered trademark of DENSO WAVE INCORPORATED
  http://www.denso-wave.com/qrcode/faqpatent-e.html
EOF
} > "$OUT"
cp "$OUT" "$ROOT/tv-app/assets/notices.txt"
echo "wrote $OUT ($(echo "$mods" | wc -l) modules)"
