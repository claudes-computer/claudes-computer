#!/bin/bash
# Signs this machine in to your tailnet (prints a login link the first time).
. /opt/ccrd/ccrd.conf 2>/dev/null
/opt/ccrd/desktop-on.sh >/dev/null 2>&1; sleep 3
# --reset: "tailscale up" refuses to run when settings were changed since (home-route.sh sets the exit node);
# start clean, and home-route.sh puts the home route back. The TV app looks for devices named "ccrd" or "ccrd-<name>" (computer-name.sh).
/opt/ccrd/tailscale --socket=/opt/ccrd/ts.sock up --reset --hostname="$(/opt/ccrd/computer-name.sh)" --accept-dns=false "$@"
