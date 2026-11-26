# Changelog

## 1.0-alpha

First public build.

- TV app for Android TV / Google TV with Tailscale built in: sign in with a QR code, no VPN app needed.
- The desktop: XFCE, Chrome, Firefox, LibreOffice, sound, 1080p at 30 frames a second (H.264).
- "desktop on" sets up a new cloud machine by itself and keeps it awake only while someone is watching.
- The TV is the house's node: home internet for the computer, home network for Claude when asked.
- Wake from the TV with a PIN. Google Drive backup and encrypted browser logins. Home network check-up.
- Each TV reports its state to the computer (version, screen, what's plugged in).
- The app updates itself: ask Claude to "update the TVs", then press Install on the TV. No computer needed.
- The desktop's sound keeps playing in the background, like a music app.
- Smoother sound over Wi-Fi (a quarter-second cushion), and two workspaces: yours and Claude's.
- The helper: a second small app. Updates install without pressing Install, the app reopens after an update or a
  crash, Claude can turn the TV on and off, and on Android 11+ gets a command line on the TV.
- Claude's light: the TV shows a notice whenever Claude looks at its screen, sends an update or checks the home
  network.

Known gaps: the microphone from the TV (Ctrl+Alt+M) is experimental; no camera. Coming soon: more than one
computer, managed from the TV.
