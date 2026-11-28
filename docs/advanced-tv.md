# Advanced and experimental TV notes

For Claude sessions, only when the user asks for one of these. Nothing here is needed for the desktop on the TV.
These were written for one household's setup; treat them as notes, not tested steps.

- Never install or update it over the home route (adb through Tailscale's SOCKS port): that route runs through the
  app itself. Use another device on the home network, the other TV, or Downloader on the TV.
- Won't open ("it beeps") and nothing else can install it: the user installs the official Tailscale app on the TV,
  signs in, opens `http://<this machine's tailnet IP>:6083/cc.apk` in Downloader, installs over the top, then turns
  the Tailscale app off. Copy the newest build into /opt/ccrd/tv first.
- "Update the TVs" → `/opt/ccrd/tv-update.sh`: sends the newest build (in /opt/ccrd/tv) to every TV that's on (a new build means both files: `cc.apk`, and `cc-old.apk` built with `APP_ID=com.walt.desktop` for TVs still on the old app id); the app must be open
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
- **Before asking a person to touch a TV, try every route, in this order:** the app (port 6084) → adb from the home
  box (`tailscale ssh $CCRD_HOME_BOX`, then `adb connect <TV LAN IP>:5555`; it installs, presses keys, screenshots and
  changes settings, and is the route that has proved reliable) → the other TV as the way into the home network → only
  then the person. Android refuses any software answering its "Allow USB debugging?" box: that one needs a real press. Check `tailscale status`
  for what is online first; a missing Claude session on a machine doesn't mean the machine is unreachable.
- Optional, only if the user has a home box and turned on the TV's debugging: adb from `CCRD_HOME_BOX` (it's on
  the home Wi-Fi, so not the home route) can press keys, restart or reinstall the app; a Wake-on-LAN packet sent
  from there turns on a TV with Remote start on. Without them, everything above still works.
- **"Set up the helper"** (experimental, off by default: it has been unreliable; prefer adb from the home box) (a second small app inside the TV app: hands-free updates, reopening the app after an
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

