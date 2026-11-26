#!/bin/bash
# Opens Claude's Computer on the TVs at home when a TV has gone dark (the app is closed, or the TV restarted): the
# app holds the TV's place on the private network, so with it closed nothing else here can reach that TV.
# Goes through the home computer (CCRD_HOME_BOX in ccrd.conf, on the home Wi-Fi), as a paired remote control.
#   tv-open.sh                    open the app on every TV at home this remote is paired with
#   tv-open.sh pair TV-ADDRESS    once per TV: the TV shows a 6-character code (addresses: tv-open.sh find)
#   tv-open.sh code TV-ADDRESS CODE
#   tv-open.sh find               the TVs the home computer can see (home-network addresses)
#   tv-open.sh keys TV-ADDRESS KEY...   press buttons (HOME, BACK, DPAD_CENTER, ...; launch:<link>; sleep:<s>)
D=/opt/ccrd; R=$D/remote; . $D/ccrd.conf 2>/dev/null; BOX=$CCRD_HOME_BOX
[ -n "$BOX" ] || { echo "No home computer is set up (CCRD_HOME_BOX). Ask Claude to \"set up my home computer\"."; exit 1; }
SSH="timeout 60 $D/tailscale --socket=$D/ts.sock ssh $BOX"
$SSH true 2>/dev/null || { echo "The home computer ($BOX) doesn't answer. Is it on?"; exit 1; }
mkdir -p $R; chmod 700 $R
# The remote's own tools, once per machine.
[ -x $R/bin/python ] && $R/bin/python -c 'import androidtvremote2' 2>/dev/null || {
  python3 -m venv $R >/dev/null && $R/bin/pip -q install androidtvremote2 >/dev/null 2>&1 || { echo "Couldn't install the remote's tools."; exit 1; }; }
# The remote's identity (what the TVs paired with). A copy lives on the home computer, so a replaced cloud machine
# gets it back and no TV needs pairing again.
if [ ! -s $R/key.pem ]; then
  $SSH 'cat ~/.config/ccrd/remote/cert.pem' > $R/cert.pem 2>/dev/null; (umask 077; $SSH 'cat ~/.config/ccrd/remote/key.pem' > $R/key.pem 2>/dev/null)
  [ -s $R/key.pem ] || rm -f $R/key.pem $R/cert.pem
fi
keep(){ [ -s $R/key.pem ] && $SSH 'umask 077; mkdir -p ~/.config/ccrd/remote && cat > ~/.config/ccrd/remote/bundle' < <(cat $R/cert.pem; echo ----KEY----; cat $R/key.pem) \
  && $SSH 'cd ~/.config/ccrd/remote && umask 077 && sed "/^----KEY----$/,\$d" bundle > cert.pem && sed "1,/^----KEY----$/d" bundle > key.pem && rm bundle'; }
[ -s $R/key.pem ] && [ ! -f $R/.kept ] && keep && touch $R/.kept
# Every device on the home computer's network that answers on the TV remote port.
find_tvs(){ $SSH 'me=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n "s/.*src \([0-9.]*\).*/\1/p"); n=${me%.*}; [ -n "$n" ] || exit 0
  for i in $(seq 1 254); do (nc -z -w1 $n.$i 6466 2>/dev/null && echo $n.$i) & done; wait' 2>/dev/null | sort -t. -k4 -n; }
py(){ $R/bin/python "$(dirname "$(readlink -f "$0")")/tv-remote.py" "$BOX" "$@"; }
case "$1" in
  find) find_tvs;;
  pair) [ -n "$2" ] || { echo "usage: $0 pair TV-ADDRESS"; exit 2; }
        (py "$2" pair > $R/pair-$2.log 2>&1; grep -q PAIRED $R/pair-$2.log && keep && touch $R/.kept) &
        for i in $(seq 1 30); do grep -q "CODE ON TV" $R/pair-$2.log 2>/dev/null && break; sleep 1; done
        grep -q "CODE ON TV" $R/pair-$2.log 2>/dev/null && echo "ON THE TV: a 6-character code is showing. Then: $0 code $2 <code>" || { echo "Pairing didn't start: $(tail -1 $R/pair-$2.log)"; exit 1; };;
  code) echo "$3" > $R/code-$2; for i in $(seq 1 20); do grep -q -E "PAIRED|Error|error" $R/pair-$2.log 2>/dev/null && break; sleep 1; done
        grep -q PAIRED $R/pair-$2.log && echo "Paired with $2." || { echo "Pairing failed: $(tail -1 $R/pair-$2.log)"; exit 1; };;
  keys) shift; tv=$1; shift; py "$tv" keys "$@";;
  "")   [ -s $R/key.pem ] || { echo "This remote isn't paired with a TV yet: $0 find, then $0 pair TV-ADDRESS"; exit 1; }
        n=0
        for tv in $(find_tvs); do
          # HOME first: a screensaver in front swallows the link.
          r=$(py "$tv" keys sleep:1 HOME sleep:3 "launch:claudescomputer://open" sleep:4 2>&1 | tail -1)
          case "$r" in ok*) echo "$tv: opened ($r)"; n=$((n+1));; *) echo "$tv: not opened ($r)";; esac
        done
        [ $n -gt 0 ] || { echo "No TV opened the app. Is the TV on, and paired ($0 pair TV-ADDRESS)?"; exit 1; };;
  *) sed -n 2,10p "$0"; exit 2;;
esac
