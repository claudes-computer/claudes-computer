#!/bin/bash
# This cloud image makes Python 3.13 the default python3, but Ubuntu's desktop apps written in Python (file search,
# printer settings, ...) are built for the system's Python 3.12 and crash under 3.13. The desktop session puts
# /opt/ccrd/pybin first on its PATH: python3 there is 3.12, and each menu app whose script starts with
# #!/usr/bin/python3 gets a same-named wrapper that runs it with 3.12. Run by install.sh and desktop-on.sh, so apps
# installed later are covered on the next "desktop on". Nothing outside the desktop session changes.
SYS=$(ls /usr/bin/python3.1[0-9] 2>/dev/null | while read p; do [ -d /usr/lib/python3/dist-packages/gi ] && ls /usr/lib/python3/dist-packages/gi/_gi.cpython-$(basename $p | tr -d python.)-*.so >/dev/null 2>&1 && echo $p; done | head -1)
[ -n "$SYS" ] || exit 0
B=/opt/ccrd/pybin; mkdir -p $B; ln -sf "$SYS" $B/python3
for f in /usr/share/applications/*.desktop /usr/local/share/applications/*.desktop; do
  [ -f "$f" ] || continue
  e=$(grep -m1 '^Exec=' "$f" | sed 's/^Exec=//; s/^env [^ ]* //; s/ .*//'); [ -n "$e" ] || continue
  p=$(PATH=/usr/local/bin:/usr/bin:/bin:/usr/games command -v "$e" 2>/dev/null) || continue
  case "$p" in /opt/ccrd/*) continue;; esac
  t=$p
  # A small shell launcher that just execs a Python script (e.g. system-config-printer): look through it.
  if head -1 "$p" 2>/dev/null | grep -qE '^#! ?/bin/sh'; then
    x=$(sed -n 's/^prefix=//p' "$p" | head -1)
    x=$(grep -m1 -oE '^exec [^ ]+' "$p" | sed "s/^exec //; s#\${prefix}#${x:-/usr}#")
    [ -f "$x" ] && t=$x
  fi
  head -1 "$t" 2>/dev/null | grep -qE '^#! ?/usr/bin/(env )?python3$' || continue
  printf '#!/bin/sh\nexec %s %s "$@"\n' "$SYS" "$t" > $B/$(basename "$e"); chmod 755 $B/$(basename "$e")
done
exit 0
