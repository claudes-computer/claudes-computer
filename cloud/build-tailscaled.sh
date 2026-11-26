#!/bin/bash
# Builds tailscaled with our patches: relay speed (bigger relay send queue, packets bundled per write) and the
# WebSocket fallback for machines behind a proxy that intercepts TLS (tailscale-control-websocket.patch).
# Stock Tailscale drops relay packets past a 32-packet queue and flushes every packet on its own,
# which held the cloud-to-home stream at ~8 Mbit/s; patched it measured 23-34 Mbit/s.
set -e
V=${TS_VERSION:-1.106.0}; HERE=$(cd "$(dirname "$0")" && pwd)
# Everything Go downloads and compiles goes to a throwaway folder, removed at the end (it's several GB).
W=$(mktemp -d /tmp/ts-build.XXXXXX); trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
export GOPATH=$W/gopath GOCACHE=$W/cache GOFLAGS=-mod=mod CGO_ENABLED=0
go mod download tailscale.com@v$V
SRC=$(go env GOMODCACHE)/tailscale.com@v$V
cp -r "$SRC" $W/src && chmod -R u+w $W/src
cd $W/src && patch -p1 < "$HERE/tailscale-relay-speed.patch" && patch -p1 < "$HERE/tailscale-control-websocket.patch"
go build -o $W/out/tailscaled ./cmd/tailscaled && go build -o $W/out/tailscale ./cmd/tailscale
install -m 755 $W/out/tailscaled $W/out/tailscale /opt/ccrd/
