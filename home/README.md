# Optional home computer

Not needed. Claude's Computer works with just the TV app: the TV lends its home internet connection, and
Tailscale's free relays carry the stream (6-21 Mbit/s measured; the stream uses 5).

An always-on Linux computer at home (an old laptop is fine) adds:

- **A home relay**: Tailscale's relay server, reachable from the cloud on your router's port 443 (opened
  automatically over NAT-PMP). Measured 32-35 Mbit/s cloud-to-TV, steadier than the free relays.
- **Your home network and internet address** even when the TV is off (`99-tailscale-exitnode.conf` +
  `tailscale set --advertise-exit-node --advertise-routes=<your home subnet>`).

Setup (Claude does this for you):
1. A free DuckDNS name; its name and token go in `~/.config/ccrd/duckdns.name` and `duckdns.token`.
2. In your tailnet policy, add the home relay:
   ```
   "derpMap": {"Regions": {"900": {"RegionID": 900, "RegionCode": "home", "RegionName": "Home relay",
     "Nodes": [{"Name": "900a", "RegionID": 900, "HostName": "<name>.duckdns.org", "DERPPort": 443, "STUNPort": 3478}]}}},
   ```
3. `./install.sh`

The TV app can run the same relay itself when there's no home computer (it opens the router port and gets its own
certificate).
