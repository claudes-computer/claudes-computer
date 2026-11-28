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
- **The app on the TVs is always the published release** (`github.com/claudes-computer/claudes-computer/releases/latest`,
  signed only by GitHub). Android accepts updates only with the same signature; anything else is refused and the
  installed app keeps working. Never send a TV a build made in this session.
- **"Update the TVs"** → `/opt/ccrd/tv-update.sh` (`--only <TV name>` for one TV): downloads the latest release and
  sends it to every TV that's on, with the app open. Android then asks on the TV: the person moves to **Install**, OK.
- **The app won't open, or a TV needs it fresh:** on that TV, in Downloader, open
  `github.com/claudes-computer/claudes-computer/releases/latest/download/claudes-computer.apk` and install over the top.
  A fresh install signs in again with the QR code (the person scans it with their phone).
- Each TV reports itself to this machine: `http://<TV tailnet IP>:6084/tv/report` (JSON) and `/tv/screen` (PNG),
  through `curl --socks5-hostname 127.0.0.1:1055` with no_proxy unset.
- **Before asking a person to touch a TV:** check `tailscale status`, then the app (port 6084). If the user has a home
  computer set up (`CCRD_HOME_BOX`), adb from it reaches the TVs; see `docs/advanced-tv.md`. Android refuses any
  software answering its "Allow USB debugging?" box: that one always needs a real press on the TV.
- **Anything else on the TVs** (home computer setup, the experimental helper, tune-ups, standby tests): follow
  `docs/advanced-tv.md`, and only when the user asks for it.

**Driving the desktop:** use the accessibility tree, not screenshots: `/opt/ccrd/a11y.py apps|tree|do|focus`
run as `desk` with DISPLAY=:1 and the session's DBUS_SESSION_BUS_ADDRESS (from xfce4-session's environment).
Screenshots only when stuck. Arrange windows with XFCE's own snapping, never pixel geometry (Chrome's borders
leave gaps): activate the window by clicking its title bar, then `xdotool key super+KP_Left` / `super+KP_Right` for halves, `super+KP_Home`,
`KP_Page_Up`, `KP_End`, `KP_Next` for quarters. Work on your own workspace (the second, "Claude's"): `/opt/ccrd/claude-window.sh URL`
opens a Chrome window there without taking over the person's screen. Start Chrome only through `/opt/ccrd/chrome.sh`
(it brings the desktop's sound and accessibility with it).

**Other agents' machines** (Codex, Muse, ...): `cloud/ccrd doctor` names the machine's walls with evidence,
`cloud/ccrd up` runs the desktop the way they allow, `cloud/ccrd report` gives 8 lines to paste. Not for this
machine's own desktop: "desktop on" above is that.

**Signing keys:** releases are made only by GitHub (Actions → TV app release), which signs with the repository
secret and refuses any key whose certificate isn't `tv-app/RELEASE_CERT.sha256`. A session never signs a release, never
holds the release key, and never sends TVs that have the published app a build signed with another key (`build.sh`
says "test build" when it is one): Android refuses it, and the only fix is uninstalling the app on each TV. To update
TVs, send them the published release (`releases/latest/download/claudes-computer.apk`).

**Facts:** the desktop runs as user `desk`, not root. Never print secrets. Tailscale state is `/opt/ccrd/ts.state`.
Home network traffic goes through Tailscale's SOCKS port 127.0.0.1:1055 (unset no_proxy for 192.168.x and 100.x).
Settings: `/opt/ccrd/ccrd.conf` (`CCRD_PRINTER`, `CCRD_TZ`, `CCRD_HOME_BOX`: an optional always-on home computer,
reached with `/opt/ccrd/tailscale --socket=/opt/ccrd/ts.sock ssh $CCRD_HOME_BOX`). The TV app reads
`/opt/ccrd/tv/tv-config.json`, served on tailnet port 6083.
