#!/bin/bash
# Asks for the vault password on the desktop (never in chat) and creates the encrypted Drive remote "vault:",
# which save.sh and restore.sh use for Chrome's profile (saved logins and cookies).
# Prints VAULT_CREATED, CANCELLED or FAILED.
# The box runs as the desktop user, on the desktop's screen; only what was typed comes back.
ask() {
  runuser -u desk -- env -i DISPLAY=:1 HOME=/home/desk XDG_RUNTIME_DIR=/run/user/$(id -u desk) PATH=/usr/bin:/bin zenity "$@"
}

MSG="Choose a password for your encrypted backup.\nWrite it down somewhere safe: it protects the copy in Google Drive, and you'll need it if you ever set this up again from nothing."
while true; do
  OUT=$(ask --forms --title="Desktop backup" --text="$MSG" --width=700 --separator=$'\n' \
    --add-password="Password" --add-password="Type it again" 2>/dev/null) || { echo "CANCELLED"; exit 1; }
  P1=$(printf '%s' "$OUT" | sed -n 1p)
  P2=$(printf '%s' "$OUT" | sed -n 2p)
  if [ "$P1" != "$P2" ]; then MSG="Those didn't match. Try again."; continue; fi
  if [ ${#P1} -lt 10 ]; then MSG="Use at least 10 characters. Try again."; continue; fi
  break
done
OBS=$(printf '%s' "$P1" | rclone obscure -)
unset P1 P2 OUT
rclone config create vault crypt remote=gdrive:claude-desktop-vault \
  filename_encryption=standard directory_name_encryption=true password="$OBS" --no-obscure >/dev/null 2>&1 \
  && echo "VAULT_CREATED" || echo "FAILED"
