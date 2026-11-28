package dev.ccrd.tv;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.webkit.WebSettings;
import android.webkit.WebView;

import ccrdnet.Ccrdnet;
import org.json.JSONObject;

public class MainActivity extends Activity implements Runnable {
    // The cloud desktop's name on your tailnet (set by cloud/tailscale-up.sh) and its stream port.
    private static final String DESKTOP_HOST = "ccrd";
    private static final String DESKTOP = DESKTOP_HOST + ":6081";
    // Ways to reach the desktop, tried in order: the Tailscale node built into this app (port 16082, see run()),
    // then a plain forwarder for a TV that also runs Tailscale's own app.
    private static final String[] HOSTS = { "http://127.0.0.1:16082/", "http://127.0.0.1:16081/" };
    private WebView web;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean opened = false;  // the desktop is on screen
    private boolean forwarding = false;
    private String shown = "";
    private android.widget.FrameLayout root;
    private Wake wake;               // waking the computer from this TV with a PIN (Wake.java)
    private long wakeAskedAt = 0;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        // Off unless asked for ("am start ... --ez debug true"): with debugging on, anything on the home network that
        // can reach this TV's adb could look inside the pages this app shows.
        WebView.setWebContentsDebuggingEnabled(devExtra("debug"));
        // With a real keyboard connected, don't let Android pop its on-screen keyboard over the desktop every time
        // a text box gets focus. Typing still reaches the desktop through the real keyboard.
        web = new WebView(this) {
            @Override public boolean onCheckIsTextEditor() { return !hasRealKeyboard(); }
        };
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
        web.setBackgroundColor(Color.BLACK);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        web.setWebViewClient(new DesktopClient(this));
        // The desktop page may use this TV's microphone, but only when the user switches it on (Ctrl+Alt+M) and only
        // for our own desktop page; Android asks the user once for permission.
        web.setWebChromeClient(new android.webkit.WebChromeClient() {
            @Override public void onPermissionRequest(final android.webkit.PermissionRequest r) {
                String host = r.getOrigin() == null ? "" : r.getOrigin().getHost();
                boolean ours = "127.0.0.1".equals(host);
                boolean wantsMic = java.util.Arrays.asList(r.getResources()).contains(android.webkit.PermissionRequest.RESOURCE_AUDIO_CAPTURE);
                if (ours && wantsMic && mic && hasMicPermission())
                    r.grant(new String[] { android.webkit.PermissionRequest.RESOURCE_AUDIO_CAPTURE });
                else r.deny();
            }
            // No grey "play" placeholder while the stream starts: an empty picture instead.
            @Override public android.graphics.Bitmap getDefaultVideoPoster() {
                return android.graphics.Bitmap.createBitmap(1, 1, android.graphics.Bitmap.Config.ARGB_8888);
            }
        });
        new LocalForwarder(16081, DESKTOP_HOST, 6081).start();
        root = new android.widget.FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        root.addView(web);
        picker = new ComputerPicker(this, root, handler);
        sound = new BackgroundSound(this, handler, speakersLost);
        registerReceiver(screenOff, new android.content.IntentFilter(android.content.Intent.ACTION_SCREEN_OFF));
        // Small pills in the top-right corner: Claude's notice, and the microphone while it's on.
        android.widget.LinearLayout pills = new android.widget.LinearLayout(this);
        pills.setOrientation(android.widget.LinearLayout.VERTICAL);
        pills.setGravity(android.view.Gravity.END);
        claudeBadge = Ui.pill(this, Ui.CORAL);
        claudeBadge.setVisibility(View.GONE);
        micBadge = Ui.pill(this, 0xFFE5484D);
        micBadge.setText("Microphone on");
        micBadge.setVisibility(View.GONE);
        android.widget.LinearLayout.LayoutParams gap = new android.widget.LinearLayout.LayoutParams(
            android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT);
        gap.setMargins(0, 0, 0, Ui.dp(this, 10));
        pills.addView(claudeBadge, gap);
        pills.addView(micBadge, new android.widget.LinearLayout.LayoutParams(gap));
        android.widget.FrameLayout.LayoutParams lp = new android.widget.FrameLayout.LayoutParams(
            android.widget.FrameLayout.LayoutParams.WRAP_CONTENT, android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
            android.view.Gravity.TOP | android.view.Gravity.END);
        lp.setMargins(0, Ui.dp(this, 24), Ui.dp(this, 32), 0);
        root.addView(pills, lp);
        setContentView(root);
        host = MANY_COMPUTERS ? getSharedPreferences("desktop", 0).getString("host", "ccrd") : "ccrd";
        Ccrdnet.setDesktop(host);
        wake = new Wake(this, web, handler, host);
        hideBars();
        go.Seq.setContext(getApplicationContext());
        Ccrdnet.setInterfaces(NetInfo.describe(), NetInfo.defaultInterface(this));
        android.util.Log.i("ClaudeDesktop", "bound to home network: " + NetInfo.bindToHomeNetwork(this));
        Ccrdnet.setDNS(NetInfo.dnsServers(this));
        String tailnetDir = getFilesDir().getAbsolutePath() + "/tailnet";
        writeAuthKey(tailnetDir, devMode() ? getIntent().getStringExtra("authkey") : null);
        if (devExtra("profile")) Ccrdnet.startProfiler();
        Ccrdnet.start(tailnetDir, "ccrd-tv");
        Ccrdnet.setTVInfo(new TvInfo(this, handler));   // the TV describing itself to the desktop (TvInfo.java)
        web.loadUrl("file:///android_asset/status.html");
        handler.postDelayed(this, 700);
    }

    /** The development switches (tv-app/README.md) only work while the TV's own "USB debugging" setting is on:
     *  any app on the TV can start this screen with extras, but only the TV's owner can turn that setting on. */
    private boolean devMode() {
        return getIntent() != null
            && android.provider.Settings.Global.getInt(getContentResolver(), android.provider.Settings.Global.ADB_ENABLED, 0) == 1;
    }
    private boolean devExtra(String name) { return devMode() && getIntent().getBooleanExtra(name, false); }

    /** For setting up a TV from a computer: an auth key passed with "am start --es authkey ..." signs the
     *  built-in node in without the QR code. ccrdnet reads it once and deletes it. */
    static void writeAuthKey(String dir, String key) {
        if (key == null || !key.startsWith("tskey-")) return;
        try {
            new java.io.File(dir).mkdirs();
            java.io.FileOutputStream f = new java.io.FileOutputStream(dir + "/authkey");
            f.write(key.trim().getBytes("UTF-8")); f.close();
        } catch (Exception e) { android.util.Log.w("ClaudeDesktop", "authkey: " + e); }
    }

    private static boolean extrasStarted = false;
    private long pausedAt = 0;

    @Override protected void onPause() { super.onPause(); pausedAt = System.currentTimeMillis(); resumed = false; }
    private boolean resumed = false;
    boolean inFront() { return resumed; }

    // ---- "Off" that keeps the TV awake (TvInfo helper action "blank") -------------------------------------
    // Some TVs (the Sony A95L) turn their Wi-Fi off a few minutes into standby, and then nothing can turn them on
    // again from the network. So "off" from Claude shows pure black (on an OLED the pixels are off), dims the
    // backlight and mutes the sound, while the TV stays awake and reachable. Any button, or "blank off", undoes it.
    private android.view.View blank;
    private int mutedFrom = -1;
    void blankOn() {
        if (blank != null) return;
        blank = new android.view.View(this);
        blank.setBackgroundColor(0xFF000000);
        root.addView(blank, new android.widget.FrameLayout.LayoutParams(
            android.widget.FrameLayout.LayoutParams.MATCH_PARENT, android.widget.FrameLayout.LayoutParams.MATCH_PARENT));
        WindowManager.LayoutParams lp = getWindow().getAttributes(); lp.screenBrightness = 0f; getWindow().setAttributes(lp);
        android.media.AudioManager am = (android.media.AudioManager) getSystemService(AUDIO_SERVICE);
        if (am != null && !am.isStreamMute(android.media.AudioManager.STREAM_MUSIC)) {
            am.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, android.media.AudioManager.ADJUST_MUTE, 0); mutedFrom = 1; }
        android.util.Log.i("ClaudeDesktop", "blank on");
    }
    void unblank() {
        if (blank == null) return;
        root.removeView(blank); blank = null;
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE; getWindow().setAttributes(lp);
        android.media.AudioManager am = (android.media.AudioManager) getSystemService(AUDIO_SERVICE);
        if (am != null && mutedFrom == 1) am.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, android.media.AudioManager.ADJUST_UNMUTE, 0);
        mutedFrom = -1;
        android.util.Log.i("ClaudeDesktop", "blank off");
    }
    boolean blanked() { return blank != null; }

    // ---- sound in the background, like a music app: leave the app and the desktop keeps playing, until another
    // app takes the speakers (Android's audio focus). Then the desktop steps aside and disconnects, so the
    // computer can sleep as usual; coming back opens it again. ----
    private boolean away = false, steppedAside = false;
    private BackgroundSound sound;
    private final Runnable speakersLost = new Runnable() { public void run() {
        if (!away || !opened || steppedAside) return;
        hangUp("another app took the speakers");
    } };
    /** Hang up: no sound, no stream, so the computer can sleep. The app keeps running quietly so it stays on the
     *  private network. Coming back to the app opens the desktop again. */
    private void hangUp(String why) {
        steppedAside = true;
        KeepPlaying.start(this, true);                 // stay alive (and reachable) without sound or stream
        web.loadUrl("about:blank");
        android.util.Log.i("ClaudeDesktop", why + ": desktop stepped aside");
    }
    /** Power off is "goodnight", not "keep playing in the background": hang up, even if the desktop was playing
     *  sound behind another app. The app itself stays on the private network, so Claude can still reach the TV. */
    private final android.content.BroadcastReceiver screenOff = new android.content.BroadcastReceiver() {
        @Override public void onReceive(android.content.Context c, android.content.Intent i) {
            if (opened && !steppedAside) { away = true; hangUp("the TV turned off"); }
        }
    };
    private boolean screenIsOn() {
        return ((android.os.PowerManager) getSystemService(POWER_SERVICE)).isInteractive();
    }

    private final Runnable heartbeat = new Runnable() { public void run() {
        HelperLink.beat(MainActivity.this, true);
        handler.postDelayed(this, 30000);
    } };

    @Override protected void onStop() {
        super.onStop();
        handler.removeCallbacks(heartbeat); HelperLink.beat(this, false);
        if (opened && !steppedAside) {
            away = true;
            if (!screenIsOn()) hangUp("the TV turned off");
            else { sound.take(); KeepPlaying.start(this); }
        }
    }

    @Override protected void onDestroy() {
        try { unregisterReceiver(screenOff); } catch (Exception e) { }
        super.onDestroy();
    }

    @Override protected void onStart() {
        super.onStart();
        handler.removeCallbacks(heartbeat); handler.post(heartbeat);
        if (away && !steppedAside) pausedAt = 0;   // it kept playing, still connected: no reconnect needed
        away = false;
        KeepPlaying.stop(this);
        if (steppedAside) {                                              // it hung up while away: open it again
            steppedAside = false; pausedAt = 0;
            if (current != null) open(current);
        }
        if (opened) sound.take();
    }

    /** Back from the home screen or the screensaver: the stream may have dropped while away, so reconnect. */
    @Override protected void onResume() {
        super.onResume();
        resumed = true;
        if (opened && pausedAt > 0 && System.currentTimeMillis() - pausedAt > 10000) web.reload();
        if (!opened) { shown = ""; handler.post(this); }
    }

    /** Polls until the desktop can be opened, telling the viewer what it is waiting for: the TV's internet,
     *  the Tailscale sign-in, or the cloud computer itself (asleep until someone tells Claude "desktop on").
     *  Never needs a button press: it keeps checking by itself. */
    @Override
    public void run() {
        handler.removeCallbacks(this);
        if (opened || probing) return;
        if (wake.busy()) { handler.postDelayed(this, 1000); return; }      // a setup or PIN screen is up
        if (wake.waking() && System.currentTimeMillis() - wakeAskedAt > 240000) { wake.reset(); shown = ""; }  // gave it 4 minutes
        if (!NetInfo.online(this)) { status("offline", "", ""); handler.postDelayed(this, 2000); return; }
        String state = Ccrdnet.state();
        if (!"Running".equals(state)) {
            status(state, Ccrdnet.authURL(), Ccrdnet.lastError());
            handler.postDelayed(this, 1000);
            return;
        }
        if (!forwarding) { forwarding = Ccrdnet.forward(16082, DESKTOP).isEmpty(); }
        // The TV's own service (report, updates, helper, "off" that keeps it awake) starts as soon as the TV is on
        // the private network, not only after a desktop opens: with every desktop asleep, Claude still reaches the TV.
        startExtras();
        if (!asleep) status("checking", "", "");
        probing = true;
        new Thread(new Runnable() { public void run() {
            // "--ez fakeasleep true" (testing): behave as if the computer were asleep without stopping it for everyone.
            final String url = devExtra("fakeasleep") ? null : findDesktop();
            handler.post(new Runnable() { public void run() {
                probing = false;
                if (url != null) { asleep = false; open(url); return; }
                asleep = true;
                if (MANY_COMPUTERS) picker.recount();
                status("asleep", "", "");
                handler.postDelayed(MainActivity.this, RETRY_MS);
            } });
        } }, "probe").start();
    }

    private static final int RETRY_MS = 10000;
    private boolean probing = false, asleep = false;

    /** The first address that answers: the built-in node, then the plain forwarder (for a TV that also runs
     *  Tailscale's own app). null when the desktop doesn't answer (the cloud computer is asleep). */
    static String findDesktop() {
        for (String u : HOSTS) if (answers(u, 8000)) return u;
        return null;
    }

    static boolean answers(String u, int timeoutMs) {
        java.net.HttpURLConnection c = null;
        try {
            c = (java.net.HttpURLConnection) new java.net.URL(u).openConnection();
            c.setConnectTimeout(timeoutMs); c.setReadTimeout(timeoutMs); c.setUseCaches(false);
            int code = c.getResponseCode();
            return code >= 200 && code < 500;
        } catch (Exception e) {
            return false;
        } finally { if (c != null) c.disconnect(); }
    }

    private void status(String kind, String url, String detail) {
        String key = kind + "|" + url + "|" + detail;
        if (wake.busy()) return;
        // While waking, keep the "Waking your computer" screen unless something else went wrong.
        if (wake.waking()) { if (kind.equals("asleep") || kind.equals("checking")) return; wake.reset(); }
        if (key.equals(shown)) return;
        shown = key;
        if (kind.equals("asleep")) refreshHint();
        web.evaluateJavascript("setStatus(" + JSONObject.quote(kind) + "," + JSONObject.quote(url) + ","
            + JSONObject.quote(detail) + "," + RETRY_MS + ")", null);
    }

    // ---- used by Wake.java ----
    boolean isAsleep() { return asleep && !opened; }
    void refreshHint() {
        String h = wake.hint();
        if (MANY_COMPUTERS && picker.count() > 1) h = "This is " + ComputerPicker.label(host) + ". Press ◀ ▶ (on a desktop: hold Back, or Ctrl+Alt+Tab) to switch computers.\n" + h;
        web.evaluateJavascript("setWakeHint(" + JSONObject.quote(h) + ")", null);
    }
    void refreshStatus() { shown = ""; handler.post(this); }
    void wakeRequested() { wakeAskedAt = System.currentTimeMillis(); handler.removeCallbacks(this); handler.postDelayed(this, 5000); }

    private void open(String url) {
        wake.reset();
        opened = true;
        current = url;
        mic = false; micBadge.setVisibility(View.GONE);   // a freshly opened desktop page starts with the mic off
        web.loadUrl(url);
        handler.postDelayed(watchdog, 30000);
        reloads = 0;
        handler.removeCallbacks(streamCheck);
        handler.postDelayed(streamCheck, 20000);
        startExtras();
    }

    private String current = null;
    private int misses = 0;

    /** While the desktop is on screen: if it stops answering for about half a minute (the cloud computer went to
     *  sleep), go back to the status screen, which reopens the desktop as soon as it is back. */
    private final Runnable watchdog = new Runnable() { public void run() {
        if (!opened) return;
        final String u = current;
        new Thread(new Runnable() { public void run() {
            final boolean ok = answers(u, 8000);
            handler.post(new Runnable() { public void run() {
                if (!opened) return;
                misses = ok ? 0 : misses + 1;
                if (misses >= 2) { lost(); return; }
                handler.postDelayed(watchdog, ok ? 15000 : 8000);
            } });
        } }, "watchdog").start();
    } };

    private int reloads = 0;

    /** The page can answer while the stream itself never starts (the TV showed a blank page with the desktop up and
     *  nobody watching). 20 s after the page loads, ask it whether any video has arrived; reload if not, and after
     *  three failed reloads go back to the status screen, which keeps retrying. Once video has arrived, Selkies
     *  reconnects by itself and the watchdog covers the desktop going away. (A still desktop sends no new
     *  frames, so a stalled counter later on proves nothing; only the first frame is checked.) */
    private final Runnable streamCheck = new Runnable() { public void run() {
        if (!opened) return;
        web.evaluateJavascript("String(window.videoChunksReceived||0)",
            new android.webkit.ValueCallback<String>() { public void onReceiveValue(String v) {
                if (!opened) return;
                long chunks = 0;
                try { chunks = Long.parseLong(v.replace("\"", "")); } catch (Exception e) { }
                if (chunks > 0) { reloads = 0; return; }
                if (++reloads > 3) { lost(); return; }
                android.util.Log.i("ClaudeDesktop", "no video yet, reloading (" + reloads + ")");
                web.reload();
                handler.postDelayed(streamCheck, 20000);
            } });
    } };

    /** The status page has (re)loaded: send it the current status again. */
    void statusPageReady() {
        if (opened) return;
        String k = shown; shown = "";
        if (!k.isEmpty()) { String[] a = k.split("\\|", -1); status(a[0], a.length > 1 ? a[1] : "", a.length > 2 ? a[2] : ""); }
    }

    /** The desktop page failed to load, or stopped answering. */
    void lost() {
        if (!opened) return;
        opened = false; misses = 0; shown = ""; asleep = true;
        handler.removeCallbacks(watchdog);
        handler.removeCallbacks(streamCheck);
        web.loadUrl("file:///android_asset/status.html");
        handler.postDelayed(this, 1500);
    }

    private void startExtras() {
        if (extrasStarted) return;
        extrasStarted = true;
        final android.content.Context ctx = getApplicationContext();
        new Thread(new Runnable() { public void run() {
            // While the app runs, the TV is the house's node: home internet address + home network.
            // Offer the home network only if no other VPN on the TV would capture that traffic.
            String share = Ccrdnet.shareHome(NetInfo.otherVpnActive(ctx) ? "" : NetInfo.homeSubnet(ctx));
            if (!share.isEmpty()) android.util.Log.w("ClaudeDesktop", "shareHome: " + share);
            // Keep the house name (DuckDNS) pointed at this home, using the settings Claude put on the desktop.
            Ccrdnet.keepHouseName(DESKTOP_HOST);
            // For the house check-up: which network is home, and permission to hear what devices announce on it
            // (Android filters those announcements on Wi-Fi unless an app asks).
            Ccrdnet.setHome(NetInfo.homeSubnet(ctx), NetInfo.gateway(ctx));
            Ccrdnet.setTimeZone(java.util.TimeZone.getDefault().getID());
            try {
                android.net.wifi.WifiManager wm = (android.net.wifi.WifiManager) ctx.getSystemService(android.content.Context.WIFI_SERVICE);
                android.net.wifi.WifiManager.MulticastLock lock = wm.createMulticastLock("ccrd-house");
                lock.setReferenceCounted(false); lock.acquire();
            } catch (Exception e) { android.util.Log.w("ClaudeDesktop", "multicast: " + e); }
            // A small safe for the desktop's sign-ins, so a replaced cloud machine gets them back from the TV.
            String keep = Ccrdnet.serveKeep(ctx.getFilesDir().getAbsolutePath() + "/keep");
            if (!keep.isEmpty()) android.util.Log.w("ClaudeDesktop", "keep: " + keep);
            String pref = Ccrdnet.preferHomeRelay();
            if (!pref.isEmpty()) android.util.Log.i("ClaudeDesktop", "home relay: " + pref);
            // And the house's fast relay, if the router gives this TV port 443.
            // (Not when another VPN runs on the TV: it would capture the router request and the mapping would go astray.)
            String relay = NetInfo.otherVpnActive(ctx) ? "another VPN is on" : Ccrdnet.startRelay(NetInfo.gateway(ctx));
            if (!relay.isEmpty()) android.util.Log.w("ClaudeDesktop", "relay: " + relay);
            handler.postDelayed(new Runnable() { public void run() {
                android.util.Log.i("ClaudeDesktop", "relay status: " + Ccrdnet.relayStatus());
                String[] lines = Ccrdnet.log().split("\n");
                for (int i = Math.max(0, lines.length - 4); i < lines.length; i++) android.util.Log.i("ClaudeDesktop", "log: " + lines[i]);
                handler.postDelayed(this, 30000);
            } }, 5000);
        } }, "house-node").start();
    }

    private void hideBars() {
        web.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }

    /** Keys on the status screens are handled here, before the page gets them (a WebView swallows OK). */
    @Override
    public boolean dispatchKeyEvent(KeyEvent ev) {
        int code = ev.getKeyCode();
        // Blanked ("off" that keeps the TV awake): any button brings the picture back.
        if (blank != null) {
            if (ev.getAction() == KeyEvent.ACTION_UP) unblank();
            return true;
        }
        if (picker.showing()) {                                 // the computer picker is up: it takes the keys
            if (code == KeyEvent.KEYCODE_BACK || code == KeyEvent.KEYCODE_ESCAPE) {
                if (backHeld) { if (ev.getAction() == KeyEvent.ACTION_UP) backHeld = false; return true; }   // the hold that opened it
                if (ev.getAction() == KeyEvent.ACTION_UP) picker.hide();
                return true;
            }
            return super.dispatchKeyEvent(ev);
        }
        // On the remote, hold Back on a desktop to choose another computer (a short press still goes back).
        if (MANY_COMPUTERS && opened && code == KeyEvent.KEYCODE_BACK) {
            if (ev.getAction() == KeyEvent.ACTION_DOWN && ev.getRepeatCount() > 0) {
                if (!backHeld) { backHeld = true; picker.show(); }
                return true;
            }
            if (ev.getAction() == KeyEvent.ACTION_UP && backHeld) { backHeld = false; return true; }
        }
        // Ctrl+Alt+Tab: switch computers.
        if (MANY_COMPUTERS && code == KeyEvent.KEYCODE_TAB && ev.isCtrlPressed() && ev.isAltPressed()) {
            if (ev.getAction() == KeyEvent.ACTION_DOWN && ev.getRepeatCount() == 0) picker.show();
            return true;
        }
        // On the status screens, left/right on the remote switch computers (when there is more than one).
        if (MANY_COMPUTERS && !opened && !wake.busy() && (code == KeyEvent.KEYCODE_DPAD_LEFT || code == KeyEvent.KEYCODE_DPAD_RIGHT)) {
            if (ev.getAction() == KeyEvent.ACTION_DOWN && picker.count() > 1) picker.show();
            return true;
        }
        // Ctrl+Alt+M: the desktop's microphone (this TV's mic) on or off.
        if (opened && code == KeyEvent.KEYCODE_M && ev.isCtrlPressed() && ev.isAltPressed()) {
            if (ev.getAction() == KeyEvent.ACTION_DOWN && ev.getRepeatCount() == 0) toggleMic();
            return true;
        }
        if (opened || code == KeyEvent.KEYCODE_BACK) return super.dispatchKeyEvent(ev);   // Back: onBackPressed
        boolean down = ev.getAction() == KeyEvent.ACTION_DOWN;
        if (down && wake.key(code)) { swallow = code; return true; }
        if (!down && code == swallow) { swallow = 0; return true; }
        // OK checks again right away (it also checks by itself).
        if (!wake.busy() && (code == KeyEvent.KEYCODE_DPAD_CENTER || code == KeyEvent.KEYCODE_ENTER)) {
            if (down) { shown = ""; handler.post(this); }
            return true;
        }
        return super.dispatchKeyEvent(ev);
    }
    private int swallow = 0;
    private boolean backHeld = false;


    // ---- more than one computer (ComputerPicker.java) ----
    // On: every desktop on the tailnet (Claude sessions, ChatGPT's, Muse's) is a tile; ◀ ▶ on the status screens or
    // Ctrl+Alt+Tab opens them.
    static final boolean MANY_COMPUTERS = true;
    private String host = "ccrd";            // the computer this TV shows
    private ComputerPicker picker;
    String host() { return host; }
    void computersChanged() { if (!opened) refreshHint(); }
    void focusDesktop() { web.requestFocus(); }

    /** Show another computer: the connection follows the new name; the desktop page starts over. */
    void switchTo(String h) {
        picker.hide();
        if (h.equals(host)) return;
        host = h;
        getSharedPreferences("desktop", 0).edit().putString("host", h).apply();
        Ccrdnet.setDesktop(h);
        wake = new Wake(this, web, handler, h);
        android.util.Log.i("ClaudeDesktop", "switched to " + h);
        if (opened) {
            opened = false; misses = 0; reloads = 0;
            handler.removeCallbacks(watchdog);
            handler.removeCallbacks(streamCheck);
        }
        asleep = false; shown = "";
        web.loadUrl("file:///android_asset/status.html");
        handler.removeCallbacks(this);
        handler.postDelayed(this, 1200);
    }

    // ---- Claude's light: a short notice whenever Claude uses the TV itself (TvInfo.notice) ----
    private android.widget.TextView claudeBadge;
    private final Runnable hideClaude = new Runnable() { public void run() { Ui.fadeOut(claudeBadge); } };
    void claudeNotice(String what) {
        boolean shown = claudeBadge.getVisibility() == View.VISIBLE;
        claudeBadge.setText(what);
        if (!shown) Ui.fadeIn(claudeBadge);
        handler.removeCallbacks(hideClaude);
        handler.postDelayed(hideClaude, 5000);
    }

    // ---- the microphone ----
    private boolean mic = false, micPending = false;
    private android.widget.TextView micBadge;
    boolean micOn() { return mic; }
    private boolean hasMicPermission() {
        return android.os.Build.VERSION.SDK_INT < 23
            || checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED;
    }
    private void toggleMic() {
        if (!mic && !hasMicPermission()) {
            micPending = true;
            requestPermissions(new String[] { android.Manifest.permission.RECORD_AUDIO }, 1);
            return;
        }
        setMic(!mic);
    }
    private void setMic(boolean on) {
        mic = on;
        micBadge.setVisibility(on ? View.VISIBLE : View.GONE);
        web.evaluateJavascript("window.postMessage({type:'pipelineControl',pipeline:'microphone',enabled:" + on
            + "},window.location.origin)", null);
    }
    @Override
    public void onRequestPermissionsResult(int req, String[] perms, int[] res) {
        if (req == 1 && micPending) {
            micPending = false;
            if (res.length > 0 && res[0] == android.content.pm.PackageManager.PERMISSION_GRANTED) setMic(true);
        }
    }

    /** What the screen shows, for the TV report: "desktop", or the status screen's kind ("asleep", ...). */
    String showing() {
        if (opened) return "desktop";
        String k = shown;
        return k.isEmpty() ? "starting" : k.split("\\|", -1)[0];
    }

    @Override
    public void onBackPressed() {
        if (!opened && wake.key(KeyEvent.KEYCODE_BACK)) return;
        if (web.canGoBack()) web.goBack(); else super.onBackPressed();
    }

    /** True when a physical keyboard (Bluetooth or USB) is connected. TV remotes don't count. */
    private boolean hasRealKeyboard() {
        android.content.res.Configuration c = getResources().getConfiguration();
        return c.keyboard == android.content.res.Configuration.KEYBOARD_QWERTY
            && c.hardKeyboardHidden != android.content.res.Configuration.HARDKEYBOARDHIDDEN_YES;
    }
}
