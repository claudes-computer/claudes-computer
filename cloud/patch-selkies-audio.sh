#!/bin/bash
# The stream's audio player keeps only 50 ms of sound in reserve (built for a wired LAN) and throws sound away when
# more piles up, so over Wi-Fi and Tailscale the sound breaks up. Give it a real cushion: at least 250 ms, growing to
# a second when the connection is jittery. The sound then runs a fraction of a second behind the picture, which is
# far less noticeable than gaps. Safe to run again (it only changes the original values).
F=$(ls /opt/selkies/lib/python3*/site-packages/selkies/selkies_web/selkies-core.js 2>/dev/null | head -1)
[ -f "$F" ] || exit 0
grep -q 'this.TARGET_MIN = 2;' "$F" || exit 0
sed -i 's/this\.TARGET_MIN = 2;/this.TARGET_MIN = packets(250);/;
        s/this\.TARGET_MAX = 1 + packets(50);/this.TARGET_MAX = 1 + packets(1000);/;
        s/this\.MAX_BUFFER_PACKETS = this\.TARGET_MAX + packets(20);/this.MAX_BUFFER_PACKETS = this.TARGET_MAX + packets(500);/' "$F"
echo "stream audio: cushion set to 250 ms - 1 s"
