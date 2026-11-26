#!/bin/bash
# Installs the whole desktop into a fresh Claude Code cloud machine. Safe to run again: each step is skipped if
# it is already done. Run by Claude on the first "desktop on" (CLAUDE.md), or ahead of time by the environment's
# setup script. Output: /tmp/ccrd-install.log.
set -e
# If a step fails, say which one (the log otherwise ends on a bare error code).
trap 'echo "Claude'\''s Computer install FAILED at cloud/install.sh line $LINENO: $BASH_COMMAND" >&2' ERR
HERE=$(cd "$(dirname "$0")" && pwd)
D=/opt/ccrd
H=/home/desk
. $D/ccrd.conf 2>/dev/null || true
export DEBIAN_FRONTEND=noninteractive

# ---- Network check ------------------------------------------------------------------------------------------
# The desktop needs the environment's network access set to Full (Chrome, Firefox, Tailscale and the themes
# download from their own sites). Say so plainly instead of failing later on a bare download error.
if ! curl -fs -m 15 -o /dev/null https://dl.google.com/linux/linux_signing_key.pub; then
  echo "Claude's Computer: this environment can't reach dl.google.com. Set its network access to Full" >&2
  echo "(claude.ai/code: environment settings, Network access), then start a new session." >&2
  exit 1
fi

# ---- Packages -----------------------------------------------------------------------------------------------
apt-get update -qq
# The desktop itself: virtual screen, XFCE, sound, file manager and viewers, printing, and the tools our scripts use.
apt-get install -y -qq --no-install-recommends \
  xvfb xfce4 xfce4-terminal dbus-x11 x11-utils xdotool zenity wmctrl \
  pulseaudio pulseaudio-utils pavucontrol xfce4-pulseaudio-plugin \
  xfce4-whiskermenu-plugin xfce4-notifyd xfce4-screenshooter \
  thunar thunar-archive-plugin gvfs gvfs-daemons tumbler xdg-user-dirs \
  mousepad ristretto file-roller gnome-calculator evince vlc \
  mint-y-icons fonts-ubuntu \
  cups cups-client cups-ipp-utils socat ieee-data \
  python3-venv xclip xsel openssh-client iproute2 libnss3-tools curl unzip python3-pyatspi gir1.2-atspi-2.0
# The everyday apps people would miss on a new computer: office, photo editing, sticky notes, a task manager,
# and fonts so documents and other languages look right. Nothing else.
apt-get install -y -qq --no-install-recommends \
  libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-gtk3 libreoffice-style-colibre \
  gimp xfce4-notes-plugin xfce4-taskmanager \
  fonts-noto-cjk fonts-crosextra-carlito fonts-crosextra-caladea fonts-liberation2 fonts-noto-color-emoji

# ---- Downloads from their own sites -------------------------------------------------------------------------
# Chrome. Check for the real one: /usr/bin/google-chrome* may already exist as our own launcher or another
# browser's wrapper (a fresh cloud image ships one that points at Playwright's Chromium).
if [ ! -x /opt/google/chrome/google-chrome ]; then
  for try in 1 2 3; do
    curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && break
    sleep 5
  done
  [ -s /tmp/chrome.deb ] || { echo "Claude's Computer install FAILED: couldn't download Chrome from dl.google.com" >&2; exit 1; }
  apt-get install -y -qq /tmp/chrome.deb && rm -f /tmp/chrome.deb
fi

# Firefox, from Mozilla (Ubuntu's package only installs a snap, which this machine can't run).
if [ ! -x /opt/firefox/firefox ]; then
  curl -fsSL -o /tmp/ff.tar.xz "https://download.mozilla.org/?product=firefox-latest&os=linux64&lang=en-US" \
    && tar -xf /tmp/ff.tar.xz -C /opt && rm -f /tmp/ff.tar.xz
fi

# rclone (Drive backup).
if ! command -v rclone >/dev/null; then
  curl -fsSL -o /tmp/rclone.deb https://downloads.rclone.org/rclone-current-linux-amd64.deb
  apt-get install -y -qq /tmp/rclone.deb && rm -f /tmp/rclone.deb
fi

# Mint-Y themes (only the themes are taken from Mint's package). Mint removes old versions from its server, so take
# the newest one listed. Not essential: without them the desktop still works, in XFCE's own look.
if [ ! -d /usr/share/themes/Mint-Y-Dark-Aqua ]; then
  M=http://packages.linuxmint.com/pool/main/m/mint-themes
  v=$(curl -fsS "$M/" | grep -oE 'mint-themes_[0-9.]+_all\.deb' | sort -uV | tail -1 || true)
  if [ -n "$v" ] && curl -fsSL -o /tmp/mint-themes.deb "$M/$v"; then
    rm -rf /tmp/mt && dpkg-deb -x /tmp/mint-themes.deb /tmp/mt
    cp -r /tmp/mt/usr/share/themes/Mint-Y* /usr/share/themes/
    rm -rf /tmp/mt /tmp/mint-themes.deb
  else
    echo "note: couldn't get the Mint themes from $M; the desktop uses XFCE's own look" >&2
  fi
fi

# ---- The desktop's own user account (apps like VLC refuse to run as root) ------------------------------------
id desk >/dev/null 2>&1 || useradd -m -s /bin/bash -u 1500 desk
mkdir -p $D $H/.pki/nssdb $H/.config/autostart $H/.config/gtk-3.0 \
  $H/Desktop $H/Documents $H/Downloads $H/Pictures $H/Music $H/Videos

# ---- Tailscale (runs in userspace; no system install) -------------------------------------------------------
if [ ! -x $D/tailscale ]; then
  curl -fsSL https://pkgs.tailscale.com/stable/tailscale_1.104.7_amd64.tgz | tar xz -C $D --strip-components=1
fi
# Faster relay traffic: rebuild tailscaled with our patch when Go is available (stock otherwise).
if command -v go >/dev/null && [ ! -f $D/tailscaled.patched ]; then
  "$HERE/build-tailscaled.sh" >/tmp/build-tailscaled.log 2>&1 && date > $D/tailscaled.patched || true
fi
[ ! -f $D/ts.state ] || chmod 600 $D/ts.state

# ---- Selkies (the stream) -----------------------------------------------------------------------------------
if [ ! -x /opt/selkies/bin/selkies ]; then
  python3 -m venv /opt/selkies && /opt/selkies/bin/pip install -q selkies==2.2.1
fi
# The TV fix: TV decoders hold several frames by design, so only call the decoder "behind" past 16 queued
# frames, not 4. Without this, TVs get throttled to about 10 fps.
for f in /opt/selkies/lib/python3*/site-packages/selkies/selkies_web/selkies-core.js; do
  sed -i 's|this._backlog/n>4|this._backlog/n>16|' "$f"
done

# ---- Trust the cloud machine's own web proxy ----------------------------------------------------------------
# When there's no home route, browsers go out through the machine's proxy, which re-signs HTTPS with Anthropic's
# certificates. Chrome reads them from the desktop user's certificate store, Firefox from its policy file.
certutil -d sql:$H/.pki/nssdb -L >/dev/null 2>&1 || certutil -d sql:$H/.pki/nssdb -N --empty-password
if [ -f /root/.ccr/ca-bundle.crt ]; then
  C=$(mktemp -d)
  (cd "$C" && awk '/BEGIN CERT/{n++} {print > ("c" n ".pem")}' /root/.ccr/ca-bundle.crt)
  for f in "$C"/c*.pem; do
    openssl x509 -in "$f" -noout -subject 2>/dev/null | grep -q "O = Anthropic" || continue
    certutil -d sql:$H/.pki/nssdb -A -t "C,," -n "sandbox-$(basename "$f")" -i "$f" || true
    install -m 644 "$f" $D/sandbox-ca-$(basename "$f")
  done
  rm -rf "$C"
fi

# ---- Our own scripts, launchers and settings ----------------------------------------------------------------
for s in desktop-on.sh keepawake.sh apply-look.sh fix-python-apps.sh \
         chrome.sh firefox.sh \
         tailscale-up.sh ts-join.sh home-route.sh tv-keep.sh wake-token.sh house-check.sh \
         save.sh restore.sh chrome-db-check.py vault-password.sh a11y.py tv-update.sh claude-window.sh patch-selkies-audio.sh computer-name.sh tv-helper-setup.sh tv-open.sh tv-remote.py; do
  install -m 755 "$HERE/$s" $D/$s
done
cp "$HERE/wallpaper.png" $D/wallpaper.png
rm -rf $D/welcome && cp -r "$HERE/welcome" $D/welcome && chmod 755 $D/welcome/welcome.py

# Menu entries, the Chrome icon on the desktop, and the Welcome walkthrough on the first start.
A=/usr/share/applications
cp "$HERE/files/chrome.desktop" $A/chrome.desktop
install -m 755 "$HERE/files/chrome.desktop" $H/Desktop/chrome.desktop
cp "$HERE/files/welcome.desktop" $A/ccrd-welcome.desktop
cp "$HERE/files/welcome-autostart.desktop" $H/.config/autostart/ccrd-welcome.desktop
# Every Chrome launcher (file associations, other apps) must go through our wrapper: stock Chrome won't start here.
ln -sf $D/chrome.sh /usr/bin/google-chrome-stable
ln -sf $D/chrome.sh /usr/bin/google-chrome

# Firefox: its menu entry (firefox.sh picks the home route like chrome.sh) and its policy: no update nags, no
# first-run terms screen, and trust in the cloud machine's proxy.
if [ -x /opt/firefox/firefox ]; then
  cp "$HERE/files/firefox.desktop" $A/firefox.desktop
  mkdir -p /opt/firefox/distribution
  CA=$(ls $D/sandbox-ca-*.pem 2>/dev/null | sed 's/.*/"&"/' | paste -sd,)
  cat > /opt/firefox/distribution/policies.json <<EOF
{"policies": {
  "DisableAppUpdate": true, "DontCheckDefaultBrowser": true, "OverrideFirstRunPage": "",
  "SkipTermsOfUse": true, "DisableTelemetry": true,
  "Certificates": {"Install": [$CA]}
}}
EOF
fi

# LibreOffice: no "Tip of the Day" popup.
mkdir -p /etc/libreoffice/registry
cp "$HERE/files/libreoffice-no-tips.xcd" /etc/libreoffice/registry/ccrd.xcd

# Ubuntu's Python desktop apps need Python 3.12; this image's default is 3.13 (see fix-python-apps.sh).
$D/fix-python-apps.sh

# The bottom bar's look and dark tooltips (cloud/files/panel.css). Only ours: a stylesheet the user wrote stays.
G=$H/.config/gtk-3.0/gtk.css
[ -f "$G" ] && ! grep -q "Claude's Computer: the bottom bar" "$G" || cp "$HERE/files/panel.css" "$G"

# Folder shortcuts in file windows.
for f in Documents Downloads Pictures Music Videos; do echo "file://$H/$f $f"; done > $H/.config/gtk-3.0/bookmarks

chown -R desk:desk $H
chmod 750 $H
# The clock: CCRD_TZ if set (desktop-on.sh applies it too); otherwise home-route.sh asks the TV for its time zone.
[ -n "$CCRD_TZ" ] && [ -f "/usr/share/zoneinfo/$CCRD_TZ" ] && ln -sf "/usr/share/zoneinfo/$CCRD_TZ" /etc/localtime
exit 0
