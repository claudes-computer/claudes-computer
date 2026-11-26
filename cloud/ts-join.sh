#!/bin/bash
# Signs this machine in to your tailnet by itself when it needs it (a fresh or replaced cloud machine), using a
# Tailscale auth key saved in the environment's settings as CCRD_TS_AUTHKEY (CLAUDE.md, "skip the sign-in").
# Use a reusable, ephemeral key: Tailscale then removes an old machine soon after it goes away, freeing the name.
# Without the key it does nothing, and "run /opt/ccrd/tailscale-up.sh" prints a sign-in link as before.
D=/opt/ccrd; . $D/ccrd.conf 2>/dev/null; TS="$D/tailscale --socket=${CCRD_TS_SOCKET:-$D/ts.sock}"
[ -n "$CCRD_TS_AUTHKEY" ] || exit 0
for i in 1 2 3 4 5; do $TS status --json >/dev/null 2>&1 && break; sleep 2; done
st=$($TS status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))')
case "$st" in Running|Starting) exit 0;; esac
# The key goes in a root-only file, not on the command line (other users could read it there while this runs).
# --reset: "tailscale up" refuses to run when settings were changed since (home-route.sh sets the exit node);
# start clean, and home-route.sh puts the home route back.
K=$(umask 077; mktemp $D/.authkey.XXXXXX) && printf '%s' "$CCRD_TS_AUTHKEY" > "$K"
$TS up --reset --auth-key="file:$K" --hostname="$(/opt/ccrd/computer-name.sh)" --accept-dns=false --timeout=60s >$D/ts-join.log 2>&1 \
  && echo "joined the tailnet" || echo "couldn't join the tailnet (see $D/ts-join.log)"
rm -f "$K"
