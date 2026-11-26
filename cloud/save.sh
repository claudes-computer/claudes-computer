#!/bin/bash
# Saves your files and desktop settings to Google Drive (gdrive:claude-desktop/home), and, only through the
# encrypted vault: remote, Chrome's profile (saved logins and cookies) to vault:chrome.
# Without a vault password (cloud/vault-password.sh) the Chrome profile is skipped, never sent in the clear.
# Paths can be overridden for testing: DESK_HOME, CCRD_DIR, RCLONE_CONFIG.
D=${CCRD_DIR:-/opt/ccrd}; H=${DESK_HOME:-/home/desk}; LOG=${SAVE_LOG:-/tmp/save.log}
[ -f $D/proxy.env ] && . $D/proxy.env && export HTTPS_PROXY https_proxy="$HTTPS_PROXY"
note(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
# Never back up a machine that hasn't got your files back yet: that would copy an empty desktop over your backup.
# On a replaced machine the TV may only be on later, so the restore (which also fetches the Drive sign-in from the
# TV) is tried here first, on every save until it works.
[ -f $D/restored ] || "$(dirname "$0")/restore.sh" >/dev/null 2>&1
rclone listremotes 2>/dev/null | grep -qx "gdrive:" || { note "no Drive connection; skipped"; exit 0; }
[ -f $D/restored ] || { note "not saving: files not restored on this machine yet"; exit 0; }
exec 9>/tmp/save.lock; flock -n 9 || exit 0
rc=0
# 1. Files and desktop settings (plain, in your Drive).
if rclone sync "$H" gdrive:claude-desktop/home --fast-list --transfers 8 --skip-links \
  --include "/Desktop/**" --include "/Documents/**" --include "/Downloads/**" --include "/Pictures/**" \
  --include "/Music/**" --include "/Videos/**" --include "/.config/xfce4/**" --include "/.config/Thunar/**" \
  --include "/.config/gtk-3.0/**" --include "/.config/ccrd/**" --include "/.config/mimeapps.list" "$@" 2>>/tmp/save.err; then
  date '+%F %T %Z' > $D/last-save; note "saved files"
  # Keep the Drive sign-in on your TV too, so a replaced cloud machine can get it back (restore.sh).
  C=${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}
  # And the wake token, for a TV that was off when it was set up.
  # (The TV keeps an identical copy as it is, so the PIN chosen for it stays.)
  [ -z "$CCRD_DIR" ] && [ -f $D/wake.json ] && "$(dirname "$0")/tv-keep.sh" put wake.json $D/wake.json >/dev/null 2>&1
  if [ -z "$CCRD_DIR" ] && [ -f "$C" ] && ! cmp -s "$C" $D/.kept-rclone.conf 2>/dev/null; then
    "$(dirname "$0")/tv-keep.sh" put rclone.conf "$C" >/dev/null 2>&1 && cp "$C" $D/.kept-rclone.conf && chmod 600 $D/.kept-rclone.conf && note "Drive sign-in kept on the TV"
  fi
else
  note "save FAILED (see /tmp/save.err)"; rc=1
fi
# 2. Chrome profile, encrypted. Only if vault: exists AND is a crypt remote (so logins never land in Drive readable).
P=$H/.claude-desktop-chrome
# Machines from before chrome-restored existed: one that has already uploaded its profile is in step with the vault.
[ -f $D/last-vault-save ] && [ ! -f $D/chrome-restored ] && cp $D/last-vault-save $D/chrome-restored
if [ "$(rclone config show vault 2>/dev/null | awk -F' = ' '$1=="type"{print $2}')" != crypt ]; then
  note "Chrome profile skipped: no vault password set (run cloud/vault-password.sh)"
elif [ ! -d "$P" ]; then
  note "Chrome profile skipped: none yet"
elif [ ! -f $D/chrome-restored ] && { CCRD_RESTORE=chrome "$(dirname "$0")/restore.sh" >/dev/null 2>&1; [ ! -f $D/chrome-restored ]; }; then
  # The saved logins haven't come back to this machine yet (see restore.sh): uploading now would replace them.
  note "Chrome profile skipped: saved logins not restored on this machine yet"
else
  # Copy to a private staging folder first, so the upload sees one consistent set of files while Chrome runs.
  S=$(mktemp -d /tmp/chrome-stage.XXXXXX) && chmod 700 "$S" || { note "Chrome profile save FAILED (no room for staging)"; exit 1; }
  F=$(mktemp); printf '%s\n' '- Singleton*' '- *Cache/**' '- *cache/**' '- Crashpad/**' '- Crash Reports/**' \
    '- Safe Browsing/**' '- OptimizationGuidePredictionModels/**' '- optimization_guide_model_store/**' \
    '- OnDeviceHeadSuggestModel/**' '- segmentation_platform/**' '- BrowserMetrics*' '- *.tmp' '- *-journal' > "$F"
  # Only upload a complete staging copy: syncing a partial one would delete the rest from the backup.
  if ! rclone sync "$P" "$S" --filter-from "$F" --skip-links 2>>/tmp/save.err; then
    note "Chrome profile save FAILED (staging copy incomplete; backup left as it was)"; rc=1
  elif ! "$(dirname "$0")/chrome-db-check.py" "$S"; then
    # Chrome was writing a database while it was copied. Keep the last good backup; the next save tries again.
    note "Chrome profile save skipped: a database was mid-write (backup left as it was)"
  elif rclone sync "$S" vault:chrome --fast-list --transfers 8 2>>/tmp/save.err; then
    date '+%F %T %Z' > $D/last-vault-save; note "saved Chrome profile (encrypted)"
  else
    note "Chrome profile save FAILED (see /tmp/save.err)"; rc=1
  fi
  rm -rf "$S" "$F"
fi
exit $rc
