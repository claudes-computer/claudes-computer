# The TV app

Android TV / Google TV app (`dev.ccrd.tv`): shows the cloud desktop and makes the TV the house's node on your
Tailscale network. No Gradle: `build.sh` builds it from nothing (`APP_ID=...` for another app id).

| Path | What |
|---|---|
| `src/dev/ccrd/tv/MainActivity.java` | The screen: status page or desktop stream; reconnects, mic switch (Ctrl+Alt+M) |
| `src/dev/ccrd/tv/Wake.java` | Waking the computer from the TV with a PIN |
| `src/dev/ccrd/tv/TvInfo.java` | The TV's report and screenshot for the desktop |
| `assets/status.html` | Status screens: sign-in QR, no internet, asleep, PIN |
| `ccrdnet/` | Go (gomobile): the Tailscale node, the home route, the private service on port 6084 |

The first build makes a signing key in `tv-app/build/` (git ignores it). Keep it: Android only accepts updates
signed with the same key. Development switches (`am start ... --ez debug true`, `--es authkey ...`) work only
while the TV's USB debugging is on.
