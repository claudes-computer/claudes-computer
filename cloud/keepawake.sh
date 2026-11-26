#!/bin/bash
# Keeps this machine awake while someone is watching the desktop, repairs pieces that die, and saves your files.
# Claude runs it in the background after "desktop on" (CLAUDE.md) and reads its last line when it ends:
#   IDLE: ...           nobody has watched for IDLE_LIMIT seconds: let the machine sleep
#   REARM: viewers=N    still in use, but background tasks are capped at 2 hours: start it again
IDLE_LIMIT=${IDLE_LIMIT:-600}     # seconds without a viewer before giving up
MAX=${MAX:-6900}                  # stop before the 2-hour cap
SAVE_EVERY=${SAVE_EVERY:-900}     # save to Drive this often while in use
start=$(date +%s); last=$start; saved=$start
while true; do
  /opt/ccrd/desktop-on.sh >/dev/null 2>&1
  viewers=$(ss -Htn state established '( sport = :6081 )' | wc -l)
  now=$(date +%s)
  [ "$viewers" -gt 0 ] && last=$now
  if [ $((now - saved)) -ge $SAVE_EVERY ]; then
    saved=$now
    (/opt/ccrd/save.sh >/dev/null 2>&1 &)
  fi
  if [ $((now - last)) -ge $IDLE_LIMIT ]; then
    /opt/ccrd/save.sh >/dev/null 2>&1
    echo "IDLE: no viewer for ${IDLE_LIMIT}s (saved: $(cat /opt/ccrd/last-save 2>/dev/null))"
    exit 0
  fi
  if [ $((now - start)) -ge $MAX ]; then
    /opt/ccrd/save.sh >/dev/null 2>&1
    echo "REARM: viewers=$viewers"
    exit 0
  fi
  sleep 30
done
