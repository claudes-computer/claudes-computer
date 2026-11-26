#!/bin/bash
# Firefox, set up like Chrome (chrome.sh): your home connection when it's up (Tailscale exit node via the local SOCKS
# port :1055), otherwise this machine's own connection (the HTTPS proxy in the environment).
P=$HOME/.ccrd-firefox; mkdir -p "$P"
home(){ curl -s -m 8 -o /dev/null --socks5-hostname 127.0.0.1:1055 https://www.gstatic.com/generate_204; }
if home || home; then
  printf 'user_pref("network.proxy.type", 1);\nuser_pref("network.proxy.socks", "127.0.0.1");\nuser_pref("network.proxy.socks_port", 1055);\nuser_pref("network.proxy.socks_version", 5);\nuser_pref("network.proxy.socks_remote_dns", true);\nuser_pref("network.proxy.share_proxy_settings", false);\nuser_pref("network.proxy.no_proxies_on", "localhost, 127.0.0.1, .ts.net");\n' > "$P/user.js"
else
  printf 'user_pref("network.proxy.type", 5);\n' > "$P/user.js"
fi
exec /opt/firefox/firefox --profile "$P" "$@"
