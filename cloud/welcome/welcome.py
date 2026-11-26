#!/usr/bin/env python3
"""Welcome to Claude's Computer: the first-run walkthrough, like a new laptop's.

Serves the walkthrough (index.html) on 127.0.0.1 with a random key, opens it in a Chrome app window, and does the
few things its buttons ask for (open Files, sign in to Chrome, ...). Only those fixed actions, only from a page
that knows the key. Runs as the desktop user.

  welcome.py              open the walkthrough
  welcome.py --first-run  open it only if it hasn't been finished yet (autostart)
"""
import http.server, json, os, secrets, shutil, socketserver, subprocess, sys, threading, time, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
DONE = os.path.join(HOME, ".config", "ccrd", "welcomed")
KEY = secrets.token_urlsafe(16)
CHROME = "/opt/ccrd/chrome.sh"
last_ping = time.time()

# Links the walkthrough may open. Nothing else gets passed to Chrome.
LINKS = {
    "google": "https://accounts.google.com/signin/chrome/sync?ssp=1",
    "bitwarden": "https://chromewebstore.google.com/detail/bitwarden-password-manage/nngceckbapebfimnlniiiahkandclblb",
    "1password": "https://chromewebstore.google.com/detail/1password-%E2%80%93-password-mana/aeblfdkhhhdcdjpifhhbdiojplfjncoa",
    "proton": "https://chromewebstore.google.com/detail/proton-pass-free-password/ghmbeldphafepmbegfdlkpapadhbakde",
    "github": "https://github.com/login",
    "claude": "https://claude.ai/",
}
APPS = {
    "files": ["thunar", HOME],
    "terminal": ["xfce4-terminal"],
    "editor": ["mousepad"],
    "writer": ["libreoffice", "--writer"],
    "menu": ["xfce4-popup-whiskermenu"],
}


def run(cmd):
    subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


def status():
    s = {"saved_at": 0, "folders": [], "free_gb": 0}
    try:
        s["free_gb"] = int(shutil.disk_usage(HOME).free / 1e9)
    except OSError:
        pass
    try:
        s["saved_at"] = int(os.path.getmtime("/opt/ccrd/last-save"))
    except OSError:
        pass
    for d in ("Documents", "Downloads", "Pictures", "Music", "Videos"):
        if os.path.isdir(os.path.join(HOME, d)):
            s["folders"].append(d)
    return s


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=HERE, **kw)

    def log_message(self, *a):
        pass

    def reply(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global last_ping
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path in ("/", "/index.html", "/logo.png", "/logo-wide.png", "/menu.jpg"):
            return super().do_GET()
        if q.get("k", [""])[0] != KEY:
            return self.reply(403)
        last_ping = time.time()
        if u.path == "/status":
            return self.reply(200, json.dumps(status()).encode())
        if u.path == "/open":
            what = q.get("what", [""])[0]
            if what in LINKS:
                run([CHROME, LINKS[what]])
            elif what in APPS:
                run(APPS[what])
            else:
                return self.reply(404)
            return self.reply(200, b"{}")
        if u.path == "/done":
            os.makedirs(os.path.dirname(DONE), exist_ok=True)
            if q.get("again", ["0"])[0] == "1":
                if os.path.exists(DONE):
                    os.remove(DONE)
            else:
                open(DONE, "w").write(time.strftime("%F %T\n"))
            return self.reply(200, b"{}")
        if u.path == "/ping":
            return self.reply(200, b"{}")
        return self.reply(404)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def main():
    if "--first-run" in sys.argv:
        if os.path.exists(DONE):
            return
        time.sleep(4)  # let the panel and desktop draw first
    srv = Server(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{port}/#k={KEY}"
    run([CHROME, f"--app={url}", "--window-size=1100,760", "--window-position=218,36"])
    # The page pings every few seconds; stop once it has been closed for a while.
    while time.time() - last_ping < 120:
        time.sleep(5)


if __name__ == "__main__":
    main()
