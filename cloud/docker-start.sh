#!/bin/bash
# The image's start-up (see ../Dockerfile): applies the settings given as environment variables, keeps the Tailscale
# identity in /state so the computer is the same one after the container is replaced, starts the desktop, prints the
# sign-in link the first time, and then keeps the desktop repaired.
D=/opt/ccrd
# A proxy that re-signs HTTPS: trust its certificate (system-wide, and in the desktop's browsers).
if ls /usr/local/share/ca-certificates/*.crt >/dev/null 2>&1; then
  update-ca-certificates >/dev/null 2>&1
  for f in /usr/local/share/ca-certificates/*.crt; do
    certutil -d sql:/home/desk/.pki/nssdb -A -t "C,," -n "sandbox-$(basename "$f" .crt)" -i "$f" 2>/dev/null
    install -m 644 "$f" $D/sandbox-ca-$(basename "$f" .crt).pem
  done
  chown -R desk: /home/desk/.pki 2>/dev/null
fi
# Some sandboxes resolve the proxy's name to a dead address inside containers.
if [ -n "$CCRD_PROXY_IP" ] && [ -n "$HTTPS_PROXY" ]; then
  h=${HTTPS_PROXY#*://}; h=${h%%[:/]*}
  grep -q "[[:space:]]$h\$" /etc/hosts || echo "$CCRD_PROXY_IP $h" >> /etc/hosts
fi
# Settings.
touch $D/ccrd.conf
for v in CCRD_NAME CCRD_TZ CCRD_KBPS CCRD_FPS CCRD_PRINTER CCRD_SCREEN CCRD_DERP_REGION CCRD_LOW_MEMORY; do
  [ -n "${!v}" ] && { sed -i "/^$v=/d" $D/ccrd.conf; printf '%s=%q\n' "$v" "${!v}" >> $D/ccrd.conf; }
done
# The Tailscale identity lives in /state (CCRD_STATE_DIR, set by the image): the same computer after a new container.
mkdir -p "${CCRD_STATE_DIR:-/state}"

$D/desktop-on.sh
if ! $D/tailscale --socket=$D/ts.sock status >/dev/null 2>&1; then
  echo "Sign this computer in to your Tailscale (the link appears below):"
  $D/tailscale --socket=$D/ts.sock up --hostname="$($D/computer-name.sh)" --accept-dns=false &
fi
# Keep it repaired: desktop-on.sh is safe to run again and fixes whatever stopped.
while sleep 300; do $D/desktop-on.sh >/dev/null 2>&1; done
