#!/bin/bash
# Wakes the hosting session when a message arrives over Tailscale (talk.py send): prints the new lines and exits.
F=/home/desk/.local/share/ccrd/received.txt; touch "$F"; N=$(wc -l < "$F")
for i in $(seq 3500); do
  M=$(wc -l < "$F"); [ "$M" -gt "$N" ] && { echo "INBOX:"; tail -n +$((N+1)) "$F"; exit 0; }; sleep 2
done; echo REARM
