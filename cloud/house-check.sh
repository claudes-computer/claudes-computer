#!/bin/bash
# The house check-up: what is on your home network right now, and what changed since last time.
# The TV does the looking (it is on the home network; see tv-app/ccrdnet/house.go) and this prints the result
# for Claude to explain in plain words. Results stay on this machine, in /opt/ccrd/house (root only).
#   house-check.sh          run a check-up (about half a minute)
#   house-check.sh --last   show the last one again
D=/opt/ccrd; O=$D/house
mkdir -p $O && chmod 700 $O
if [ "$1" != "--last" ]; then
  TVS=$($D/tv-keep.sh tvs)
  [ -n "$TVS" ] || { echo "No TV is on. Open the Claude's Computer app on a TV at home, then try again."; exit 1; }
  # Ask each TV that is on until one answers (a TV on an older app version can't).
  rm -f $O/new.json
  for tv in $TVS; do
    env -u no_proxy -u NO_PROXY curl -s -m 150 --socks5-hostname 127.0.0.1:1055 -o $O/new.json "http://$tv:6084/house/scan" \
      && python3 -c 'import json,sys; assert isinstance(json.load(open(sys.argv[1])).get("devices"), list)' $O/new.json 2>/dev/null && break
    rm -f $O/new.json
  done
  [ -f $O/new.json ] || { echo "No TV answered the check-up (the app needs version 4.3 or later)."; exit 1; }
  [ -f $O/latest.json ] && mv -f $O/latest.json $O/previous.json
  mv $O/new.json $O/latest.json
  cp $O/latest.json "$O/scan-$(date +%Y%m%d-%H%M).json"
fi
[ -f $O/latest.json ] || { echo "No check-up yet."; exit 1; }
python3 - $O/latest.json $O/previous.json <<'PY'
import json, os, re, sys, time

latest = json.load(open(sys.argv[1]))
previous = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else None

# Who made a device, from the first half of its hardware address (the IEEE's public list, package ieee-data).
makers = {}
try:
    for line in open("/usr/share/ieee-data/oui.txt", errors="replace"):
        m = re.match(r"^([0-9A-F]{6})\s+\(base 16\)\s+(.+)$", line.strip())
        if m:
            makers[m.group(1)] = m.group(2).strip()
except OSError:
    pass

def maker(d):
    mac = d.get("mac", "").replace(":", "").upper()
    if len(mac) >= 6 and mac[1] in "26AE":
        return "(private address: a phone, tablet or laptop hiding its maker)"
    return d.get("maker") or makers.get(mac[:6], "")

DOORS = {21: "file transfer (FTP)", 22: "remote login (SSH)", 23: "TELNET: old, unencrypted remote login",
         53: "name service", 80: "web page", 139: "file sharing", 443: "web page (secure)", 445: "file sharing",
         554: "camera video", 631: "printing", 1883: "smart-home messages (MQTT)", 1900: "UPnP",
         3389: "remote desktop", 5000: "AirPlay/UPnP", 5555: "Android debugging door (ADB)", 5900: "screen sharing",
         7000: "AirPlay", 8008: "casting", 8009: "casting", 8080: "web page", 8443: "web page (secure)",
         8883: "smart-home messages (secure)", 9100: "printing", 49152: "UPnP", 62078: "Apple device sync"}
WORTH_A_LOOK = {23, 21, 5555, 3389, 5900, 1883}

devices = latest.get("devices") or []
before = {d.get("mac") or d["ip"] for d in (previous.get("devices") or [])} if previous else None
when = time.strftime("%A %-I:%M %p", time.localtime(os.path.getmtime(sys.argv[1])))
print(f"Home network {latest.get('subnet')}, router {latest.get('router')}: {len(devices)} devices ({when}, took {latest.get('took')}).")
if latest.get("skipped"):
    print("Note:", latest["skipped"])
print()
for d in devices:
    tags = []
    if d.get("router"): tags.append("ROUTER")
    if d.get("this_tv"): tags.append("THIS TV")
    if before is not None and (d.get("mac") or d["ip"]) not in before: tags.append("NEW since the last check")
    names = [n for n in d.get("names") or [] if not re.fullmatch(r"[0-9a-f-]{12,}|Android(-\d+)?", n)]
    title = " / ".join(names[:2]) or "(no name announced)"
    print(f"{d['ip']:15}  {title}" + (f"   [{', '.join(tags)}]" if tags else ""))
    made = " ".join(x for x in (maker(d), d.get("model", "")) if x)
    if made: print(f"{'':17}made by: {made}")
    kinds = [k for k in d.get("kinds") or [] if not k.startswith("_sub.") and "._sub." not in k]
    if kinds: print(f"{'':17}announces: {', '.join(kinds[:6])}")
    ports = d.get("open_ports") or []
    if ports: print(f"{'':17}open doors: " + ", ".join(f"{p} {DOORS.get(p, '')}".strip() for p in ports))
    look = [p for p in ports if p in WORTH_A_LOOK]
    if look: print(f"{'':17}worth a look: " + ", ".join(f"{p} ({DOORS[p]})" for p in look))
if previous:
    now = {d.get("mac") or d["ip"] for d in devices}
    gone = [d for d in previous.get("devices") or [] if (d.get("mac") or d["ip"]) not in now]
    if gone:
        print("\nNot seen this time (off or away): " + ", ".join((d.get("names") or [d["ip"]])[0] for d in gone))
PY
