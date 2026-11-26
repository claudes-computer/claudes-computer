# Control an Android TV from an app on the same TV

Press remote buttons, open apps and confirm install screens on an Android TV or Google TV **from an app running on that
TV**, with no root, no adb, no phone and no second device.

This is the part of [Claude's Computer](../README.md) that lets its TV app update itself hands-free. It's about 530
lines of plain Java with no dependencies, and you can copy it into your own app.

## Problems this solves

- **"My Android TV app can't update itself without someone pressing Install."** Android shows a confirmation screen
  for every sideloaded update. With this, your app (or a small companion app) presses it.
- **"I want to send key presses (Home, Back, OK, arrows, volume) from my app to the TV it's running on."** Android
  doesn't let an ordinary app inject keys into other apps. The TV's own remote-control service accepts them.
- **"The Android TV Remote service refuses my connection when I connect from the TV itself."** It does: connections
  from the TV's own address are dropped. This works around that (see *How it works*).
- **"I want to automate my TV (kiosk, signage, accessibility, Home Assistant-style) without a phone or a PC."**
- **"Open an app or a deep link on the TV from a background service."**

Works on TVs with the **Android TV Remote Service** (the one the Google TV phone app pairs with). That's most Android
TV and Google TV devices. If your TV pairs with the Google TV app on a phone, it has it. Fire TV doesn't.

## What the user does once

1. Allows a **VPN connection** for your app (Android asks once). Nothing leaves the TV; see below.
2. Types a **6-character pairing code** that the TV shows on screen. After that, your app is a paired remote.

Both are normal Android consent screens, so the user always knows and agrees.

## The code

All in [`helper/src/dev/ccrd/helper/`](../helper/src/dev/ccrd/helper/):

| File | What it does |
|---|---|
| [`LoopVpn.java`](../helper/src/dev/ccrd/helper/LoopVpn.java) | The disguise: a VpnService that routes one made-up network (10.111.0.0/24) back through the app |
| [`Packets.java`](../helper/src/dev/ccrd/helper/Packets.java) | Rewrites addresses and fixes IPv4/TCP checksums |
| [`Remote.java`](../helper/src/dev/ccrd/helper/Remote.java) | The Android TV Remote v2 protocol: pairing (port 6467) and keys and links (port 6466) |
| [`Pb.java`](../helper/src/dev/ccrd/helper/Pb.java) | A tiny protobuf writer and reader, just enough for that protocol |
| [`Identity.java`](../helper/src/dev/ccrd/helper/Identity.java) | Makes the client certificate the TV accepts (hand-built X.509) |
| [`TvAddress.java`](../helper/src/dev/ccrd/helper/TvAddress.java) | Finds the TV's own address on the home network |

Copy the six files into your app's package. Add the service to your manifest:

```xml
<service android:name=".LoopVpn" android:exported="false"
    android:permission="android.permission.BIND_VPN_SERVICE">
    <intent-filter><action android:name="android.net.VpnService"/></intent-filter>
</service>
```

Then, from a background thread (see `disguised()` in
[`HelperService.java`](../helper/src/dev/ccrd/helper/HelperService.java) for the full version with retries):

```java
// Once: ask Android for the VPN permission (an Activity, because it shows a dialog).
Intent ask = VpnService.prepare(context);
if (ask != null) activity.startActivityForResult(ask, 1);

// Each time: start the disguise, talk to the TV through it, stop it.
LoopVpn.start(context, TvAddress.find(context));
while (!LoopVpn.up) Thread.sleep(100);
try {
    Remote tv = new Remote(context, LoopVpn.FAKE_TV);
    // First time only: the TV shows a code; the user tells you what it is.
    //   tv.startPairing("My app");  ...  tv.finishPairing(code);
    tv.run("key:3");                                   // HOME (Android keycodes)
    tv.run("key:21", "key:23");                        // LEFT, then OK: e.g. "Install" on an update screen
    tv.run("link:myapp://open");                       // open your app (any deep link)
} finally {
    LoopVpn.stop(context);
}
```

Actions are `key:<Android keycode>`, `link:<uri>` and `wait:<ms>`. Keycodes are the ones in
[`KeyEvent`](https://developer.android.com/reference/android/view/KeyEvent) (3 = HOME, 4 = BACK, 19-22 = arrows,
23 = OK, 24/25 = volume, 26 = POWER).

## How it works

The TV's remote service listens on ports 6466 and 6467, but drops connections that come from the TV itself.
So the app never connects to the TV directly. Instead:

```
 your app ──► 10.111.0.1 (a made-up "TV")
                 │   LoopVpn catches it (only this /24 is routed to the VPN)
                 ▼
             rewrite: from 10.111.0.3 (a made-up stranger) ──► the TV's real address
                 │   handed back to Android
                 ▼
             TV remote service: "a stranger on the network, fine"
                 │   answers 10.111.0.3, which routes back into the VPN
                 ▼
             rewrite back: from 10.111.0.1 ──► your app
```

Only the made-up network goes through the VPN, and only for your app (`addAllowedApplication`): other apps can't
use the tunnel. The rest of the TV's traffic is untouched, and nothing leaves the TV.

Two details that took a while to find:
- **Wait about a second after the TV says the session started** before sending keys. The TV is still creating its
  virtual remote, and earlier keys are silently lost.
- **Give each pairing a unique certificate name.** The TV looks paired remotes up by name, so two with the same
  name get mixed up.

## Limits

- Needs the Android TV Remote Service. Fire TV and some older or non-Google TVs don't have it.
- Another VPN app that's switched on at the same time takes the TV's single VPN slot.
- The TV has to be awake. Key 26 (POWER) works while it's on; turning it on from off needs the TV's network standby
  (Wake-on-LAN from another device).
- Google could change the remote service. This uses only its normal pairing and remote protocol, the same one the
  Google TV phone app uses (open-source reference: [androidtvremote2](https://github.com/tronikos/androidtvremote2), in
  Python).

## License

MIT, like the rest of [Claude's Computer](../LICENSE). Built by Drew at [The Cardiff Group](https://thecardiffgroup.us).
If it saved you an afternoon, [tips are welcome](https://ko-fi.com/stuckdrew).
