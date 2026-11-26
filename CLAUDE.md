# Instructions for the Claude session that hosts the desktop

**"desktop on"** (also "desktop on (sent from the TV)"):
1. No `/opt/ccrd/desktop-on.sh` means a new machine: say in one line that you're setting it up (about 3 minutes),
   then run `bash cloud/install.sh 2>&1 | tee /tmp/ccrd-install.log` with a 10-minute timeout. If it fails, give the
   reason from the end of the log in one line (network unreachable: set the environment's network access to Full).
2. Run `/opt/ccrd/desktop-on.sh` with a 5-minute timeout. Its last line says whether the desktop is on Tailscale.
   If not signed in, run `/opt/ccrd/tailscale-up.sh` in the background and give the user the link it prints.
3. Start `/opt/ccrd/keepawake.sh` in the background (timeout 7200000).
4. Reply in one short line, no questions: the user is at a TV.

**keepawake.sh finishes:** `IDLE` means nobody is watching: do nothing. `REARM: viewers=N`: start it again.

**Something broken that this file doesn't cover:** try desktop-on.sh once more and read the log it names. If that
doesn't fix it, don't improvise changes. Say plainly what's wrong and: "For a fix like this, switch this chat to
Opus (model menu next to the message box) and tell it what's happening."

**"Set up waking from the TV":** create a scheduled task tied to this session, no schedule, prompt exactly
`desktop on (sent from the TV)`, named "Claude's Computer: wake" (reuse one that exists). Tell the user: on
claude.ai/code/routines open it → Edit → add an **API** trigger → **Generate token** (shown once; never in chat).
Then run `/opt/ccrd/wake-token.sh <task id>`: a box on the desktop takes the token and hands it to the TV, where
the user presses OK and picks a PIN.

**"Keep my logins":** run `/opt/ccrd/vault-password.sh` (the password goes in a box on the desktop, never in chat).
**"Skip the sign-in next time":** the user makes a reusable, ephemeral, pre-approved auth key at
login.tailscale.com/admin/settings/keys and adds it as the environment variable `CCRD_TS_AUTHKEY` themselves.

**Home network check-up:** run `/opt/ccrd/house-check.sh` (a TV with the app must be on; about 30 seconds) and explain
it plainly: what each device probably is, what's new, anything worth a look and what to do. Device names and
addresses are private: never put them in this repository.

**The TV app:**
- Never install or update it over the home route (adb through Tailscale's SOCKS port): that route runs through the
  app itself. Use another device on the home network, the other TV, or Downloader on the TV.
- Won't open ("it beeps") and nothing else can install it: the user installs the official Tailscale app on the TV,
  signs in, opens `http://<this machine's tailnet IP>:6083/cc.apk` in Downloader, installs over the top, then turns
  the Tailscale app off. Copy the newest build into /opt/ccrd/tv first.
- "Update the TVs" → `/opt/ccrd/tv-update.sh`: sends the newest build (in /opt/ccrd/tv) to every TV that's on; the app must be open
  on that TV (Android shows the install screen only for the app in front). With the helper set up, the update installs
  and the app reopens by itself; without it, the person confirms Android's install screen and opens the app again. A TV whose app is too old for that: in
  Downloader on that TV, with the app running, open `http://127.0.0.1:16082/assets/tv.apk`.
- **"Set up my home computer":** walk the user through it; they type the commands on that computer.
  Linux or Mac: install Tailscale, sign in to the same account, `sudo tailscale set --ssh`. Windows: install
  **Ubuntu** from the Microsoft Store, put `[wsl2]` / `networkingMode=mirrored` in `%UserProfile%\.wslconfig`
  (Windows 11; it lets Ubuntu see the TV), run `wsl --shutdown`, then in Ubuntu install Tailscale and
  `sudo tailscale up --ssh`. Then set `CCRD_HOME_BOX=user@name` in `/opt/ccrd/ccrd.conf`, check
  `tailscale ssh $CCRD_HOME_BOX true`, and install adb there (`sudo apt install adb`; Mac: `brew install android-platform-tools`).
- **A TV went dark** (the app is closed or the TV restarted, so it's off the private network) and there is a home
  box: `/opt/ccrd/tv-open.sh` opens the app on the TVs at home as a paired remote, through the home box. Once per TV:
  `tv-open.sh find`, `tv-open.sh pair <address>`, then `tv-open.sh code <address> <code on the TV>`. `tv-update.sh`
  does this by itself when no TV answers.
- **Before asking a person to touch a TV, try every route, in this order:** the app (port 6084) → the helper
  (`/tv/helper`) → the home box (`tv-open.sh`; adb from the box for a TV with network debugging) → the other TV as
  the way into the home network (SOCKS port, when its app is open) → only then the person. Check `tailscale status`
  for what is online first; a missing Claude session on a machine doesn't mean the machine is unreachable.
- Optional, only if the user has a home box and turned on the TV's debugging: adb from `CCRD_HOME_BOX` (it's on
  the home Wi-Fi, so not the home route) can press keys, restart or reinstall the app; a Wake-on-LAN packet sent
  from there turns on a TV with Remote start on. Without them, everything above still works.
- **"Set up the helper"** (a second small app inside the TV app: hands-free updates, reopening the app after an
  update or a crash, power, buttons; on Android 11+ also a command line on the TV): run
  `/opt/ccrd/tv-helper-setup.sh`. Each run does what it can, then prints the one thing the person must do on the TV
  (lines starting "ON THE TV"): tell them exactly that, wait, run it again. It ends with what this TV can and can't
  do: pass that on. On Android 11+ it asks for wireless debugging first, because Claude then does the rest itself.
  Afterwards (POST `http://<TV>:6084/tv/helper?do=...` through the SOCKS port; the TV shows a notice each time):
  `do=keys&arg=key:<android keycode>,link:<uri>`, `do=power`, `do=shell&arg=<command>` (adb's shell user: input, pm,
  settings, dumpsys). Wireless debugging switches off when the TV restarts; the person turns it back on, no new pairing.
  Setup ends with `tv-helper-setup.sh <TV> tune` (run it again any time): pairing never expires, the helper may open
  the app directly, and on Android 13+ the app and helper stay exempt from the standby network cut-off (applies at the
  TV's next restart). Every change and its undo go in `/opt/ccrd/tv/tuneup-<TV>.txt`.
- **Does a TV stay reachable when it's off?** `/opt/ccrd/tv-standby-test.sh <TV> [minutes]`, then the person turns
  it off with the remote; it ends with a verdict.
- **"Tune up my TV"** (needs the terminal): look first, then ask before changing. Only reversible changes:
  `pm disable-user --user 0 <app>` (never uninstall system apps), `settings put` with the old value noted, the TV's own
  menus through keys. Keep a list of every change and its undo in `/opt/ccrd/tv/tuneup-<TV>.txt` and tell the person.
  Picture settings live in the TV maker's menus; walk them with the remote keys.
- Each TV reports itself to this machine: `http://<TV tailnet IP>:6084/tv/report` (JSON) and `/tv/screen` (PNG),
  through `curl --socks5-hostname 127.0.0.1:1055` with no_proxy unset.

**Driving the desktop:** use the accessibility tree, not screenshots: `/opt/ccrd/a11y.py apps|tree|do|focus`
run as `desk` with DISPLAY=:1 and the session's DBUS_SESSION_BUS_ADDRESS (from xfce4-session's environment).
Screenshots only when stuck. Work on your own workspace (the second, "Claude's"): `/opt/ccrd/claude-window.sh URL`
opens a Chrome window there without taking over the person's screen. Start Chrome only through `/opt/ccrd/chrome.sh`
(it brings the desktop's sound and accessibility with it).

**Facts:** the desktop runs as user `desk`, not root. Never print secrets. Tailscale state is `/opt/ccrd/ts.state`.
Home network traffic goes through Tailscale's SOCKS port 127.0.0.1:1055 (unset no_proxy for 192.168.x and 100.x).
Settings: `/opt/ccrd/ccrd.conf` (`CCRD_PRINTER`, `CCRD_TZ`, `CCRD_HOME_BOX`: an optional always-on home computer,
reached with `/opt/ccrd/tailscale --socket=/opt/ccrd/ts.sock ssh $CCRD_HOME_BOX`). The TV app reads
`/opt/ccrd/tv/tv-config.json`, served on tailnet port 6083.
