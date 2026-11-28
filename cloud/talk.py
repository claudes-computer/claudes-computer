#!/usr/bin/env python3
"""Desktops talking to each other over the owner's tailnet (Claude's, Codex's, Muse's, ... all run this).

    talk.py serve                  the service on port 6085 (desktop-on.sh starts it): other desktops send text and
                                   links here, and read this machine's report
    talk.py peers                  every desktop on the tailnet (anything serving the desktop stream on port 6081),
                                   with the second line of its report (READY / SIGN IN / NOT UP)
    talk.py send <name|all> <text> send text or a link; a link opens in Chrome there, text lands on its clipboard,
                                   either way with a notice on its screen
    talk.py report <name>          that desktop's 8-line report
    talk.py ui                     "Send to another computer" on the desktop (zenity)

Port 6085 listens on this machine only; Tailscale (userspace networking) hands it connections from the tailnet,
the same way as the desktop stream on 6081. Outgoing requests go through Tailscale's SOCKS port 1055.
"""
import http.server, json, os, re, socket, socketserver, subprocess, sys, time, urllib.parse
from concurrent.futures import ThreadPoolExecutor

D = "/opt/ccrd"
PORT = 6085
# On a desktop these defaults fit. On any other machine with Tailscale (a home computer with its own Claude):
#   TALK_TS=tailscale TALK_SOCKS= TALK_BIND=<its tailnet address> talk.py serve
# A cloud machine runs its own userspace Tailscale (reached through SOCKS); any other machine uses its normal one.
CLOUD = os.path.exists(f"{D}/tailscale")
TS = os.environ.get("TALK_TS", f"{D}/tailscale --socket={D}/ts.sock" if CLOUD else "tailscale").split()
SOCKS = os.environ.get("TALK_SOCKS", "127.0.0.1:1055" if CLOUD else "")
BIND = os.environ.get("TALK_BIND", "127.0.0.1")
DESK = os.path.isdir("/home/desk") and os.path.exists(f"{D}/chrome.sh")
LOG = "/home/desk/.local/share/ccrd/received.txt" if DESK else os.path.expanduser("~/.local/share/ccrd/received.txt")


def me():
    try:
        if DESK:
            return subprocess.run([f"{D}/computer-name.sh"], capture_output=True, text=True, timeout=5).stdout.strip() or "ccrd"
        return json.loads(subprocess.run(TS + ["status", "--self", "--json"], capture_output=True, text=True, timeout=5).stdout)["Self"]["HostName"]
    except Exception:
        return socket.gethostname()


def desk_env():
    """The desktop session's environment (display and D-Bus), to act on the screen as the desktop's user."""
    env = {"HOME": "/home/desk", "USER": "desk", "DISPLAY": ":1", "PATH": "/usr/local/bin:/usr/bin:/bin",
           "XDG_RUNTIME_DIR": "/run/user/%d" % _uid("desk")}
    try:
        pid = subprocess.run(["pgrep", "-u", "desk", "-x", "xfce4-session"], capture_output=True, text=True).stdout.split()[0]
        for kv in open(f"/proc/{pid}/environ", "rb").read().split(b"\0"):
            k, _, v = kv.decode(errors="replace").partition("=")
            if k in ("DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "XAUTHORITY"):
                env[k] = v
    except Exception:
        pass
    return env


def _uid(user):
    try:
        import pwd
        return pwd.getpwnam(user).pw_uid
    except Exception:
        return 1000


def as_desk(cmd, stdin=None, wait=True):
    pre = [] if os.geteuid() == _uid("desk") else ["runuser", "-u", "desk", "--"]
    full = pre + ["env", "-i"] + [f"{k}={v}" for k, v in desk_env().items()] + cmd
    if wait:
        return subprocess.run(full, input=stdin, capture_output=True, timeout=20)
    return subprocess.Popen(full, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)


def receive(text, sender):
    text = text.strip("\n")
    is_link = re.fullmatch(r"https?://\S+", text.strip()) is not None
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M')} from {sender}: {text}\n")
    if not DESK:   # a home computer: the inbox file is the message (its Claude reads it); a notice if a screen is on
        subprocess.run(["notify-send", f"From {sender}", text[:200]], capture_output=True)
        return "in the inbox (" + LOG + ")"
    try:
        os.system(f"chown -R desk: {os.path.dirname(LOG)} 2>/dev/null")
    except Exception:
        pass
    # xclip stays running to hold the clipboard: start it and don't wait, or the sender times out.
    try:
        pre = [] if os.geteuid() == _uid("desk") else ["runuser", "-u", "desk", "--"]
        x = subprocess.Popen(pre + ["env", "-i"] + [f"{k}={v}" for k, v in desk_env().items()] + ["xclip", "-selection", "clipboard"],
                             stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        x.stdin.write(text.encode()); x.stdin.close()
    except Exception:
        pass
    if is_link:
        as_desk([f"{D}/chrome.sh", text.strip()], wait=False)
    short = text if len(text) < 200 else text[:200] + "…"
    as_desk(["notify-send", "-i", "mail-message-new", f"From {sender}",
             ("Opened: " if is_link else "On your clipboard (Ctrl+V): ") + short])
    return "opened" if is_link else "on the clipboard"


def local_report():
    try:
        return subprocess.run(["bash", f"{D}/ccrd", "report"], capture_output=True, text=True, timeout=40,
                              env=dict(os.environ, CCRD_INSIDE="1")).stdout
    except Exception as e:
        return f"report failed: {e}\n"


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        p = urllib.parse.urlparse(self.path).path
        if p == "/report":
            return self._send(200, local_report())
        if p in ("/", "/hello"):
            return self._send(200, json.dumps({"name": me(), "talk": 1}), "application/json")
        self._send(404, "no such thing\n")

    def do_POST(self):
        p = urllib.parse.urlparse(self.path)
        if p.path != "/send":
            return self._send(404, "no such thing\n")
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", errors="replace")
        # A form field "text=..." (a browser form); anything else is the text itself (curl --data-binary sends raw
        # text under the form type too).
        if "application/x-www-form-urlencoded" in (self.headers.get("Content-Type") or "") and body.startswith("text="):
            body = urllib.parse.parse_qs(body).get("text", [""])[0]
        sender = self.headers.get("X-From") or "another computer"
        if not body.strip():
            return self._send(400, "nothing to send\n")
        self._send(200, receive(body, sender) + "\n")

    def log_message(self, *a):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve():
    Server((BIND, PORT), Handler).serve_forever()


# ---- Talking to the others ---------------------------------------------------------------------------------
def curl(url, data=None, timeout=6, headers=()):
    cmd = ["curl", "-s", "-m", str(timeout)] + (["--socks5-hostname", SOCKS] if SOCKS else []) + [url]
    for h in headers:
        cmd += ["-H", h]
    if data is not None:
        cmd += ["--data-binary", "@-", "-H", "Content-Type: text/plain; charset=utf-8"]
    env = {k: v for k, v in os.environ.items() if k.lower() not in ("no_proxy", "http_proxy", "https_proxy", "all_proxy")}
    try:
        r = subprocess.run(cmd, input=(data or "").encode(), capture_output=True, timeout=timeout + 2, env=env)
        return r.returncode, r.stdout.decode(errors="replace")
    except Exception:
        return 1, ""


def peers():
    """Online devices of the same Tailscale user that serve the desktop stream (port 6081) or the talk service, this one excluded."""
    try:
        st = json.loads(subprocess.run(TS + ["status", "--json"], capture_output=True, text=True, timeout=10).stdout)
    except Exception:
        return []
    uid = (st.get("Self") or {}).get("UserID")
    cand = [p for p in (st.get("Peer") or {}).values()
            if p.get("Online") and p.get("UserID") == uid and p.get("TailscaleIPs")
            and not p.get("HostName", "").lower().startswith("ccrd-tv")]

    def probe(p):
        ip = p["TailscaleIPs"][0]
        rc, hello = curl(f"http://{ip}:{PORT}/hello", timeout=4)
        talk = rc == 0 and '"talk"' in hello
        if not talk and curl(f"http://{ip}:6081/", timeout=4)[0] != 0:
            return None      # neither a desktop nor a machine with the talk service
        return {"name": p.get("HostName", ip), "ip": ip, "talk": talk}

    with ThreadPoolExecutor(16) as ex:
        found = [x for x in ex.map(probe, cand) if x]
    return sorted(found, key=lambda x: (x["name"] != "ccrd", x["name"]))


def find(name, ps):
    name = name.lower()
    return [p for p in ps if name in ("all", "*") or p["name"].lower() == name
            or p["name"].lower() == "ccrd-" + name or p["ip"] == name]


def send(name, text):
    ps = find(name, peers())
    if not ps:
        print(f"no desktop called {name} is on (talk.py peers lists them)")
        return 1
    bad = 0
    for p in ps:
        if not p["talk"]:
            print(f"{p['name']}: on, but too old to receive (update it)"); bad += 1; continue
        rc, out = curl(f"http://{p['ip']}:{PORT}/send", data=text, headers=[f"X-From: {me()}"])
        print(f"{p['name']}: {out.strip() if rc == 0 else 'failed'}"); bad += rc != 0
    return 1 if bad else 0


def main(a):
    cmd = a[0] if a else ""
    if cmd == "serve":
        serve()
    elif cmd == "peers":
        ps = peers()
        if not ps:
            print("no other desktops on the tailnet right now")

        def line(p):
            state = ""
            if p["talk"]:
                rc, rep = curl(f"http://{p['ip']}:{PORT}/report", timeout=45)
                state = (rep.splitlines()[1:2] or [""])[0] if rc == 0 else "report failed"
            else:
                state = "(no report: older version)"
            return f"{p['name']:<16} {p['ip']:<16} {state}"

        with ThreadPoolExecutor(8) as ex:
            for l in ex.map(line, ps):
                print(l)
    elif cmd == "send" and len(a) >= 3:
        return send(a[1], " ".join(a[2:]))
    elif cmd == "send" and len(a) == 2:
        return send(a[1], sys.stdin.read())
    elif cmd == "report" and len(a) == 2:
        ps = find(a[1], peers())
        if not ps:
            print(f"no desktop called {a[1]} is on"); return 1
        rc, rep = curl(f"http://{ps[0]['ip']}:{PORT}/report", timeout=45)
        print(rep.rstrip() if rc == 0 else "report failed"); return rc
    elif cmd == "ui":
        return ui()
    else:
        print(__doc__); return 2
    return 0


def ui():
    """On the desktop: pick a computer, type or paste, send."""
    def z(*args, stdin=None):
        return subprocess.run(["zenity"] + list(args), input=stdin, capture_output=True, text=True)
    pulse = subprocess.Popen(["zenity", "--progress", "--pulsate", "--no-cancel", "--auto-close",
                              "--title=Send to another computer", "--text=Looking for your other computers…"],
                             stdin=subprocess.PIPE, text=True)
    ps = peers()
    try:
        pulse.stdin.close(); pulse.terminate()
    except Exception:
        pass
    if not ps:
        z("--info", "--title=Send to another computer", "--text=None of your other computers is on right now.")
        return 1
    rows = []
    for p in ps:
        rows += [p["name"], p["ip"]]
    r = z("--list", "--title=Send to another computer", "--text=Send to which computer?", "--column=Computer",
          "--column=Address", "--width=420", "--height=320", *rows)
    if r.returncode != 0 or not r.stdout.strip():
        return 1
    target = r.stdout.strip().split("|")[0]
    try:
        clip = subprocess.run(["xclip", "-o", "-selection", "clipboard"], capture_output=True, text=True, timeout=3).stdout
    except Exception:
        clip = ""
    r = z("--entry", "--title=Send to " + target, "--text=Text or a link (a link opens there):",
          "--entry-text=" + clip[:2000], "--width=560")
    if r.returncode != 0 or not r.stdout.strip():
        return 1
    rc = send(target, r.stdout.rstrip("\n"))
    subprocess.run(["notify-send", "Send to another computer", ("Sent to " if rc == 0 else "Couldn't send to ") + target])
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
