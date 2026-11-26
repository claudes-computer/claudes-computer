# Measurements

All numbers measured on real hardware during development (November 2026): an Android TV (Android 14, 4 cores,
4.7 GB) and a Claude Code cloud session (4 vCPUs, 15 GB RAM).

## Stream frame rate on a TV
`selkies-core.js`: `this._backlog/n>4` becomes `this._backlog/n>16` (applied by `cloud/install.sh`).
TV hardware decoders (Android MediaCodec) hold several frames by design; Selkies read that as "decoder behind"
and throttled the stream. Measured in the TV's WebView:
- stock: 11 fps at 720p and 1080p
- patched: 25-33 fps (steady ~30)
- 60 fps requested: the TV really falls behind (~18-20), so 30 fps is the setting.

## TV app with Tailscale built in
| | Idle on the sign-in screen | Streaming 1080p AV1, full-screen motion |
|---|---|---|
| App memory (PSS) | 88 MB | 210 MB |
| App CPU | negligible | ~0.9 core (app) + ~0.4 core (WebView renderer), of 4 |
| Frame rate at the TV | - | 30-31 fps |

The stream's video decoder only runs on a secure origin (HTTPS or localhost). The app's built-in node listens on
`127.0.0.1` and carries each connection to the desktop over the tailnet, so no certificates are needed.

## Why Tailscale was slow through relays
- The cloud session has no direct UDP path, so Tailscale traffic goes through relay (DERP) servers.
- Cause 1: tailscaled queues only 32 packets per relay connection and drops the rest; at ~60 ms round trip TCP backs
  off hard, giving ~8-12 Mbit/s. Patched queue to 1024: drops went to 0, 22 Mbit/s.
- Cause 2: every packet was flushed as its own write through the sandbox's proxy. Patched to bundle writes
  (flush at 48 KB or after 0.3 ms): 23-28 Mbit/s for one transfer, 33-34 with four.
- Patch: `cloud/tailscale-relay-speed.patch`. The stream itself needs about 4.5 Mbit/s.

## The TV as the house's internet connection
- `Ccrdnet.shareHome(lan)` advertises an exit node (0.0.0.0/0, ::/0) and the home subnet. Tailscale still has to
  approve them (admin console, or `autoApprovers` in the tailnet policy).
- tsnet only accepts traffic addressed to itself; a fallback TCP handler dials everything else out over the TV's network.
  TCP only (tsnet has no UDP fallback), so QUIC and plain DNS over UDP don't go through the TV; browsers fall back to TCP.
- Android has no `resolv.conf`: the app hands Go the Wi-Fi's DNS servers, and Tailscale's exit-node DNS is patched to
  use them (`tv-app/tailscale-android-dns.patch`).
- Homes without IPv6: IPv6 flows are refused before the handshake, so clients fall back to IPv4 at once.
- Result: cloud browsing through the TV comes from the home address at 25-29 Mbit/s.
- If another VPN app runs on the TV (for example the Tailscale app), Android sends home-network traffic into it and
  the app can't route around it, so the app shares only the internet connection then, not the home network.

## Everyday use
- YouTube on the home route, with sound: about 23 frames a second shown, at 480p, 720p and 1080p alike. Chrome draws
  without a graphics card and that is the limit, not the video size.
- Protected video (Widevine): plays.
- LibreOffice: documents save and open normally.

## CPU-only 3D (llvmpipe, 720p, glmark2)
| Scene | score |
|---|---|
| texture | 803 |
| build | 521 |
| phong | 302 |
| refract | 19 |
| terrain | 9 |

SuperTuxKart (720p, default graphics): 28 fps while the stream was encoding. 0 A.D.: 2-9 fps, not playable.

## Stream encoder benchmark (2026-11-24)
Cloud session (4 vCPU, no GPU), 1920x1080, Selkies 2.2.1 over WebSockets, one headless Chrome viewer on the same
machine, CBR with `--video-max-qp 32`. Two workloads, 20 s each: a full-screen terminal scrolling source code
(40 lines/s), and Chrome playing a 1080p30 film full screen. "Text sharpness" is PSNR of the viewer's picture against
the real screen, 150 ms after the scrolling stops (what you see while scrolling) and 3 s later (settled).

| Encoder | fps | target Mbit/s | encoder CPU, text / video (% of one core) | fps shown, text / video | Mbit/s used, text / video | text sharpness while scrolling / settled (dB) |
|---|---|---|---|---|---|---|
| av1enc (SVT-AV1) | 30 | 4.5 | 105 / 138 | 30 / 26 | 11.8 / 1.2 | 33.6 / 51.0 |
| av1enc | 30 | 8 | 112 / 133 | 30 / 23 | 12.8 / 5.2 | 32.8 / 51.3 |
| av1enc | 30 | 12 | 109 / 118 | 30 / 29 | 13.3 / 10.8 | 31.8 / 52.7 |
| av1enc | 60 | 4.5-12 | 121-131 / 131-145 | 35-39 / 27-32 | 11-13 / 0.5-2.6 | 32-33 / 45-47 |
| **h264enc (x264)** | **30** | **8** | **32 / 41** | **30 / 30** | **5.4 / 8.0** | **58.6 / 65.1** |
| h264enc | 30 | 4.5 | 28 / 44 | 30 / 30 | 4.3 / 7.9 | 53.3 / 65.2 |
| h264enc | 30 | 12 | 30 / 42 | 30 / 30 | 7.4 / 8.3 | 59.6 / 65.2 |
| h264enc | 60 | 4.5-12 | 47-50 / 68-72 | 59 / 59 | 2.8-4.4 / 8.0-8.9 | 60-65 / 65 |
| vp9enc (libvpx) | 30 | 4.5-12 | 78-87 / 118-122 | 30 / 30 | 4.2-6.6 / 10.4-12.1 | 55-67 / 67 |
| vp9enc | 60 | 4.5-12 | 118-134 / 140-142 | 59 / 40-43 | 5.4-7.2 / 11-12 | 58-67 / 64-67 |

- Software AV1 is the wrong choice on this machine: over a full core, it can't hold 30 fps on video (23-29), and
  scrolling text is blurry (33 dB) until it settles. The bitrate setting barely changes it.
- H.264 holds 30 fps (and 60) at a third of a core, with sharp text. VP9 is sharper still when settled but costs
  2-3x the CPU and misses 60 fps on video.
- **Applied in cloud/desktop-on.sh: `--encoder h264enc --framerate 30`, 5 Mbit/s by default** (8 with a home
  relay). The link carries 22-35 Mbit/s; the stream uses 5-8. 30 fps stays because TVs fall behind at 60 (see above).
  Bonus: every Android TV decodes H.264 in hardware; many can't decode AV1 at all.
- Whole machine while streaming video: 67-70% busy with AV1, 43-46% with H.264, so apps get the difference.

## Chrome video playback on the desktop (2026-11-24)
Chrome on the desktop playing local 1080p files in a maximized window, with the H.264 stream running and a viewer
connected. Frames shown per second (from the page's own playback counters), 12 s each:

| Chrome flags | H.264 30 | VP9 30 | AV1 30 | H.264 60 | VP9 60 |
|---|---|---|---|---|---|
| default (chrome.sh) | 30.1 | 30.0 | 30.0 | 59.9 | 59.8 |
| --disable-gpu | 30.0 | 29.9 | 30.1 | 60.0 | 59.3 |
| --force-device-scale-factor=1 | 30.0 | 30.0 | 30.0 | 60.0 | 59.1 |
| both | 30.0 | 30.0 | 30.0 | 59.9 | 59.9 |

- Chrome itself keeps up with every format, at 30 and 60, without flags: no flag change made.
- The earlier ~23 fps on YouTube was measured while the AV1 encoder was using 1.1-1.4 of the 4 cores; with H.264 the
  encoder needs about 0.4, so YouTube should now reach 30. Not re-measured on YouTube itself: from the cloud's own
  address YouTube shows a robot check (it only plays on the home route through Tailscale, not used in this test).

## Any-device check (2026-11-24, quick)
Playwright with Chrome, phone (Pixel 7), tablet (iPad Pro 11) and laptop (1366x768) sizes, against the H.264 stream:
- Scaling: the 1920x1080 desktop is scaled to fit the window with letterboxing; no page scrolling on any size.
  On a phone held upright it is small (412 px wide); turn the phone sideways.
- Touch: a tap lands where it should (tap at 1/4 width, mid-height -> desktop pointer at 480,540).
- Clipboard: copy on the desktop -> paste in the browser, and back, both work in Chrome (it asks for permission once).
- Video formats: with H.264 as the server's default, a browser without AV1 is unaffected. With both AV1 and H.264
  decoding disabled the page fell back to drawing on a canvas (striped/JPEG), still working.
- On-screen keyboard: phones and tablets open it from the keyboard button in Selkies' sidebar. The TV app hides
  that sidebar, so the TV shows only the desktop.
