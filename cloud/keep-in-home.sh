#!/bin/bash
# For a sandbox where you're root but only your home folder survives the machine being replaced (and Docker isn't
# there): sets up ~/computer with a start command and a note for whoever looks after the machine, then starts the
# desktop from the published image unpacked into home (run-from-image.sh). Prints a few short lines.
#   bash keep-in-home.sh [name]        e.g. bash keep-in-home.sh muse   -> ccrd-muse on the tailnet
#   CCRD_INBOX=<folder> CCRD_INBOX_NAME=<name>: pictures and videos saved there show up in a desktop folder
# Behind a proxy that refuses Tailscale's own upgrades (most agent sandboxes), Tailscale uses WebSockets.
[ "$(id -u)" = 0 ] || { echo "FAILED: must run as root"; exit 1; }
N=${1:-${CCRD_NAME:-sandbox}}; C=$HOME/computer; HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $C
cat > $C/start <<EOF
#!/bin/bash
# Starts or repairs this machine's desktop. Safe to run any time; run it after every machine replacement.
# A scheduled job may not inherit the shell's proxy settings: take them from the first process if missing.
[ -z "\$HTTPS_PROXY" ] && eval "\$(tr '\\0' '\\n' < /proc/1/environ | grep -E '^(HTTPS?_PROXY|https?_proxy)=' | sed 's/^/export /')"
export CCRD_ROOT=$HOME/ccrd-root CCRD_NAME=$N CCRD_TZ=\${CCRD_TZ:-${CCRD_TZ:-UTC}} CCRD_FPS=\${CCRD_FPS:-20} CCRD_KBPS=\${CCRD_KBPS:-3000}
export TS_CONTROL_WEBSOCKET=1 TS_DERP_WEBSOCKET=1${CCRD_INBOX:+ CCRD_INBOX=$CCRD_INBOX CCRD_INBOX_NAME=${CCRD_INBOX_NAME:-Inbox}}
bash $HERE/run-from-image.sh "\$@" >> $C/start.log 2>&1; r=\$?
[ "\$1" = report ] || [ "\$1" = stop ] || bash $HERE/run-from-image.sh status | tail -1
[ "\$1" = report ] && bash $HERE/run-from-image.sh report
exit \$r
EOF
chmod +x $C/start
cat > $C/README.md <<EOF
# This machine is the owner's desktop computer (Claude's Computer, github.com/claudes-computer/claudes-computer)
XFCE + Chrome unpacked in $HOME/ccrd-root and run with chroot; streamed to the owner's TV over Tailscale as ccrd-$N.
Everything lives in $HOME, so it survives the machine being replaced.
- Start or repair:  $C/start            (prints READY / SIGN IN: <link> / NOT UP)
- Health, 8 lines:  $C/start report     (paste these lines as they are)
- Stop:             $C/start stop
- Newest version:   $C/start --update   (keeps the sign-in and the owner's files)
- Pictures and videos saved in ${CCRD_INBOX:-(no inbox set)} show up on the desktop in the folder ${CCRD_INBOX_NAME:-Inbox}.
- After every machine replacement, something must run $C/start (a scheduled job every 10 minutes is fine: it
  does nothing when the desktop is already up).
- "SIGN IN: <link>": give the owner exactly that link. Never print tokens or proxy passwords.
- If something fails: paste the output of "$C/start report". Don't call a failure a restriction; report the error.
EOF
echo "set up: $C/start and $C/README.md"
$C/start; $C/start report
