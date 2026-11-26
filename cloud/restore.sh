#!/bin/bash
# Brings your saved files and desktop settings back from Google Drive, and Chrome's profile (logins) from the
# encrypted vault: remote if you set a vault password. desktop-on.sh runs it on a fresh machine before the desktop
# starts; if the Drive sign-in wasn't available yet (the TV was off), save.sh runs it again before its first backup.
# Never deletes local files and never replaces a newer local file.
# Paths can be overridden for testing: DESK_HOME, CCRD_DIR, RCLONE_CONFIG.
D=${CCRD_DIR:-/opt/ccrd}; H=${DESK_HOME:-/home/desk}; LOG=${SAVE_LOG:-/tmp/save.log}
[ -f $D/proxy.env ] && . $D/proxy.env && export HTTPS_PROXY https_proxy="$HTTPS_PROXY"
note(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
TS="$D/tailscale --socket=$D/ts.sock"; . $D/ccrd.conf 2>/dev/null; HOME_BOX=$CCRD_HOME_BOX
CONF=${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}
if ! rclone listremotes 2>/dev/null | grep -qx "gdrive:"; then
  # A fresh machine has no Drive sign-in. Get it back from your TV (the app keeps a copy, see tv-keep.sh), or from
  # a home computer (CCRD_HOME_BOX=user@host); otherwise ask Claude to run "rclone config" once.
  mkdir -p "$(dirname "$CONF")"
  { [ -z "$CCRD_DIR" ] && "$(dirname "$0")/tv-keep.sh" get rclone.conf "$CONF.new" 2>/dev/null; } || \
    { [ -n "$HOME_BOX" ] && (umask 077; timeout 40 $TS ssh "$HOME_BOX" 'cat ~/claude-desktop-backup/identity/rclone.conf' > "$CONF.new" 2>/dev/null); }
  if grep -q "^\[gdrive\]" "$CONF.new" 2>/dev/null; then
    mv "$CONF.new" "$CONF"; chmod 600 "$CONF"
  else
    rm -f "$CONF.new"; note "restore: no Drive sign-in available"; exit 2
  fi
fi
if ! rclone lsf gdrive:claude-desktop/home --max-depth 1 >/dev/null 2>/tmp/restore-ls.err; then
  if grep -qi "directory not found" /tmp/restore-ls.err; then note "nothing saved in Drive yet"
  else cat /tmp/restore-ls.err >> /tmp/save.err; note "restore FAILED (Drive not reachable)"; exit 1; fi
elif rclone copy gdrive:claude-desktop/home "$H" --fast-list --transfers 8 --update "$@" 2>>/tmp/save.err; then
  note "restored files"
else
  note "restore FAILED"; exit 1
fi
# Chrome profile (logins), only from the encrypted vault, and only while Chrome isn't running.
# $D/chrome-restored means "the vault and this machine agree": the profile came back, or the vault is empty.
# save.sh uploads the profile only once that marker exists, so a failed or skipped restore can never be
# followed by an upload that replaces the saved logins with this machine's empty profile.
restore_chrome(){
  if [ "$(rclone config show vault 2>/dev/null | awk -F' = ' '$1=="type"{print $2}')" != crypt ]; then
    note "Chrome profile not restored: no vault password set"
  elif ! rclone lsf vault:chrome --max-depth 1 >/tmp/restore-vault.ls 2>/tmp/restore-vault.err \
       && ! grep -qi "directory not found" /tmp/restore-vault.err; then
    cat /tmp/restore-vault.err >> /tmp/save.err
    note "Chrome profile restore FAILED (vault not readable); saving the profile is paused"
  elif ! grep -q . /tmp/restore-vault.ls; then
    note "Chrome profile: nothing saved yet"; date '+%F %T %Z' > $D/chrome-restored
  elif pgrep -u "$(stat -c %U "$H")" -f 'google/chrome/chrome' >/dev/null; then
    note "Chrome profile not restored: Chrome is running; saving the profile is paused until Chrome is closed"
  else
    mkdir -p "$H/.claude-desktop-chrome"
    if rclone copy vault:chrome "$H/.claude-desktop-chrome" --fast-list --transfers 8 --update 2>>/tmp/save.err; then
      rm -f "$H"/.claude-desktop-chrome/Singleton*; chmod 700 "$H/.claude-desktop-chrome"; note "restored Chrome profile"
      date '+%F %T %Z' > $D/chrome-restored
    else
      note "Chrome profile restore FAILED; saving the profile is paused"
    fi
  fi
  [ "$(id -u)" = 0 ] && chown -R "$(stat -c %U:%G "$H")" "$H/.claude-desktop-chrome" 2>/dev/null
  return 0
}
if [ "$CCRD_RESTORE" = chrome ]; then restore_chrome; exit 0; fi
restore_chrome
[ "$(id -u)" = 0 ] && chown -R "$(stat -c %U:%G "$H")" "$H" 2>/dev/null
date '+%F %T %Z' > $D/restored
exit 0
