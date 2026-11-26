#!/bin/bash
# Optional home computer (any always-on Linux box): runs the home relay for a faster, steadier stream,
# keeps the router's port 443 and the DuckDNS house name pointed at it.
# Before running: put your DuckDNS name and token in ~/.config/ccrd/duckdns.name and duckdns.token
# (Claude does this during setup), and add the home relay to your tailnet policy (see README.md).
# Needs: Go, systemd user services (loginctl enable-linger), sudo for the port-443 capability and firewall.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); C=~/.config/ccrd; mkdir -p ~/.local/bin ~/.config/systemd/user $C
[ -s $C/duckdns.name ] && [ -s $C/duckdns.token ] || { echo "missing $C/duckdns.name or duckdns.token"; exit 1; }
chmod 600 $C/duckdns.token
echo "DERP_HOST=$(cat $C/duckdns.name).duckdns.org" > $C/derp.env
# The relay: Tailscale's derper, built from source (same version as the patch notes in ../docs).
GOBIN=~/.local/bin go install tailscale.com/cmd/derper@v1.104.6 && mv -f ~/.local/bin/derper ~/.local/bin/ccrd-derper
sudo setcap cap_net_bind_service=+ep ~/.local/bin/ccrd-derper
cp "$HERE/ccrd-portmap.py" ~/.local/bin/ && chmod +x ~/.local/bin/ccrd-portmap.py
cp "$HERE"/ccrd-portmap.service "$HERE"/ccrd-derp.service ~/.config/systemd/user/
if command -v ufw >/dev/null && sudo ufw status | grep -q "Status: active"; then
  sudo ufw allow 443/tcp comment "ccrd relay" >/dev/null; sudo ufw allow 3478/udp comment "ccrd relay stun" >/dev/null
fi
loginctl enable-linger "$USER" 2>/dev/null || true
systemctl --user daemon-reload && systemctl --user enable --now ccrd-portmap.service ccrd-derp.service
echo "home relay: $(systemctl --user is-active ccrd-derp)  port keeper: $(systemctl --user is-active ccrd-portmap)"
