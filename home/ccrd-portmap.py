#!/usr/bin/env python3
"""Keeps the house name (DuckDNS) and the home router's port 443 pointed at this machine (NAT-PMP), for the Claude's Computer relay.
Renews every 10 minutes; removes the mapping when stopped."""
import socket, struct, time, signal, sys, os, urllib.request, subprocess
def default_gateway():
    # The real default route (netmask 0, so not a VPN's 0.0.0.0/1 half-route), lowest metric first. Looked up
    # every round: at boot the network may not be up yet, and a guess would be wrong for good.
    best = None
    for line in open("/proc/net/route").read().splitlines()[1:]:
        f = line.split()
        if f[1] == "00000000" and f[7] == "00000000" and int(f[3], 16) & 2:  # default route with a gateway
            if best is None or int(f[6]) < best[0]:
                best = (int(f[6]), socket.inet_ntoa(struct.pack("<L", int(f[2], 16))))
    return best and best[1]
def gw(): return os.environ.get("CCRD_ROUTER") or default_gateway()
PORT = int(os.environ.get("CCRD_PORT", "443"))
STUN = int(os.environ.get("CCRD_STUN_PORT", "3478"))
def req(life, op=2, port=PORT):  # op 2 = TCP, 1 = UDP
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
    g = gw()
    if not g: raise OSError("no default route yet")
    s.sendto(struct.pack("!BBHHHI", 0, op, 0, port, port if life else 0, life), (g, 5351))
    d, _ = s.recvfrom(64); _, _, res, _, _, ext, lt = struct.unpack("!BBHIHHI", d[:16]); return res, ext, lt
def stop(*_):
    try: print("removed mappings:", req(0), req(0, 1, STUN), flush=True)
    finally: sys.exit(0)
signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
CFG = os.path.expanduser("~/.config/ccrd/")
def duck():
    name = open(CFG + "duckdns.name").read().strip(); tok = open(CFG + "duckdns.token").read().strip()
    return urllib.request.urlopen(f"https://www.duckdns.org/update?domains={name}&token={tok}", timeout=20).read().decode()
while True:
    try: print("house name update:", duck(), flush=True)
    except Exception as e: print("house name update failed:", type(e).__name__, flush=True)
    try: print("mapped TCP / UDP (result, outside port, lifetime):", req(3600), req(3600, 1, STUN), flush=True)
    except Exception as e: print("mapping failed:", e, flush=True)
    # Use the home relay as this machine's home relay whenever it answers (Tailscale otherwise keeps
    # whatever it fell back to during a blip). Wait for the relay to be up first; lasts until tailscaled
    # restarts, so repeat each round.
    time.sleep(30)
    subprocess.run(["tailscale", "debug", "force-prefer-derp", "900"], capture_output=True, timeout=20)
    time.sleep(570)
