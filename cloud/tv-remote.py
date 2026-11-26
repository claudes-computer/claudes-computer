#!/usr/bin/env python3
"""A remote control for a TV on the home network, reached through the home computer (CCRD_HOME_BOX), for when the
TV app is closed and the TV is off the private network. Used by tv-open.sh.
  tv-remote.py BOX TV pair            the TV shows a code; waits for it in DIR/code-<TV>
  tv-remote.py BOX TV keys A B ...    A is an Android TV key name (HOME, DPAD_CENTER, ...), launch:<link> or sleep:<s>
The connection goes cloud -> (tailscale ssh) -> home computer -> (nc) -> TV ports 6466/6467; only bytes pass through
the home computer, the remote's key stays here."""
import asyncio, os, socket, subprocess, sys, threading

from androidtvremote2 import AndroidTVRemote

DIR = "/opt/ccrd/remote"
BOX, TV, CMD, ARGS = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
SSH = ["/opt/ccrd/tailscale", "--socket=/opt/ccrd/ts.sock", "ssh", BOX]


def forward(remote_port):
    """Listens on a free local port; each connection is piped to TV:remote_port through the home computer."""
    l = socket.socket(); l.bind(("127.0.0.1", 0)); l.listen(8)

    def serve():
        while True:
            c, _ = l.accept()
            p = subprocess.Popen(SSH + ["nc", TV, str(remote_port)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, bufsize=0)

            def up(c=c, p=p):
                try:
                    while (d := c.recv(65536)): p.stdin.write(d)
                except Exception: pass
                finally:
                    try: p.stdin.close()
                    except Exception: pass

            def down(c=c, p=p):
                try:
                    while (d := p.stdout.read(65536)): c.sendall(d)
                except Exception: pass
                finally:
                    try: c.close()
                    except Exception: pass
                    p.kill()
            threading.Thread(target=up, daemon=True).start(); threading.Thread(target=down, daemon=True).start()
    threading.Thread(target=serve, daemon=True).start()
    return l.getsockname()[1]


async def main():
    r = AndroidTVRemote("Claude's Computer", DIR + "/cert.pem", DIR + "/key.pem", "127.0.0.1",
                        api_port=forward(6466), pair_port=forward(6467))
    await r.async_generate_cert_if_missing()
    if CMD == "pair":
        code = "%s/code-%s" % (DIR, TV)
        if os.path.exists(code): os.remove(code)
        await r.async_start_pairing()
        print("CODE ON TV", flush=True)
        for _ in range(300):
            if os.path.exists(code): break
            await asyncio.sleep(1)
        else:
            sys.exit("no code given in 5 minutes")
        await r.async_finish_pairing(open(code).read().strip()); os.remove(code)
        print("PAIRED", flush=True)
        return
    await r.async_connect()
    for a in ARGS:
        if a.startswith("launch:"): r.send_launch_app_command(a[7:])
        elif a.startswith("sleep:"): await asyncio.sleep(float(a[6:])); continue
        else: r.send_key_command(a)
        await asyncio.sleep(0.6)
    print("ok; in front:", r.current_app, flush=True)
    r.disconnect()

try:
    asyncio.run(asyncio.wait_for(main(), 330))
except Exception as e:
    sys.exit("%s: %s" % (type(e).__name__, e))
