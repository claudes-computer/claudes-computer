package dev.ccrd.helper;

import android.app.Service;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;

/** Claude's Computer's repair helper. A separate app, so it keeps working while the main app is being updated or
 *  won't start. It drives the TV the way a phone remote does (Remote.java): presses Install on updates, opens the
 *  main app again afterwards, turns the TV on and off.
 *
 *  The TV's remote service refuses connections from the TV itself, so every press goes through a disguise
 *  (LoopVpn.java): a made-up network inside this app, from which the connection arrives as a stranger.
 *
 *  Only Claude's Computer can use it: the caller must be signed with the same key as this helper (they are built
 *  together). Requests arrive as Binder calls; each returns "" or an error message. */
public class HelperService extends Service {
    static final int PAIR_START = 1, PAIR_CODE = 2, KEYS = 3, EXPECT_INSTALL = 4, STATUS = 5, ADB_PAIR = 6, SHELL = 7, HEARTBEAT = 8;
    static final String OPEN_APP = "link:claudescomputer://open";
    static final String BOOT = "dev.ccrd.helper.BOOT";
    private static final String TAG = "ClaudeHelper";

    private SharedPreferences prefs;
    private static Remote remote;          // static: one pairing spans two requests
    private static int busy = 0;
    private static boolean pairing = false;

    @Override public void onCreate() {
        super.onCreate();
        prefs = getSharedPreferences("helper", 0);
    }

    /** While in the middle of something (a pairing, waiting for an update), stay running: Android would otherwise
     *  close an idle helper between requests. A notification is the price of that on Android 8+. */
    private synchronized void hold() {
        if (busy++ > 0) return;
        try {
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                android.app.NotificationManager nm = (android.app.NotificationManager) getSystemService(NOTIFICATION_SERVICE);
                nm.createNotificationChannel(new android.app.NotificationChannel("work", "Helper", android.app.NotificationManager.IMPORTANCE_LOW));
                startForegroundService(new Intent(this, HelperService.class));
                startForeground(1, new android.app.Notification.Builder(this, "work").setSmallIcon(android.R.drawable.stat_sys_download)
                    .setContentTitle("Claude's Computer helper").setContentText("Working").build());
            } else startService(new Intent(this, HelperService.class));
        } catch (Exception e) { android.util.Log.w(TAG, "hold: " + e); }
    }
    private synchronized void release() {
        if (busy == 0 || --busy > 0) return;
        try { stopForeground(true); } catch (Exception e) { }
        stopSelf();
    }

    @Override public int onStartCommand(Intent i, int flags, int id) {
        if (i != null && BOOT.equals(i.getAction())) {
            // The TV just started (BootReceiver): wireless debugging switches itself off at every restart; turn it
            // back on (allowed once through adb: pm grant dev.ccrd.helper android.permission.WRITE_SECURE_SETTINGS).
            // Then wait for the network and open the app as the TV's remote.
            try { android.provider.Settings.Global.putInt(getContentResolver(), "adb_wifi_enabled", 1); }
            catch (Exception e) { android.util.Log.i(TAG, "boot: can't turn on wireless debugging (" + e + ")"); }
            hold();
            new Thread(new Runnable() { public void run() {
                try {
                    if (prefs.getBoolean("paired", false)) {
                        for (int t = 0; t < 4; t++) {
                            Thread.sleep(t == 0 ? 20000 : 15000);
                            try { openApp(); android.util.Log.i(TAG, "boot: opened the app"); break; }
                            catch (Exception e) { android.util.Log.w(TAG, "boot: " + e); }
                        }
                    }
                } catch (InterruptedException e) { }
                finally { release(); }
            } }, "boot").start();
        }
        return START_NOT_STICKY;
    }

    // ---- watchdog: the app says "front" every 30 s while it is on screen and "away" when the person leaves it.
    // If it was in front and goes silent (it crashed, or Android closed it), open it again. Up to 3 tries. ----
    private static boolean watching = false;
    private static volatile long lastBeat = 0;
    private static int tries = 0;
    private final android.os.Handler main = new android.os.Handler(android.os.Looper.getMainLooper());
    private final Runnable watch = new Runnable() { public void run() {
        if (!watching) return;
        // A TV that was turned off isn't a crashed app: never reopen (and so wake) a sleeping TV.
        if (!screenIsOn()) { lastBeat = System.currentTimeMillis(); main.postDelayed(this, 30000); return; }
        if (System.currentTimeMillis() - lastBeat > 90000 && tries < 3 && prefs.getBoolean("paired", false)) {
            tries++; lastBeat = System.currentTimeMillis();
            android.util.Log.i(TAG, "the app went silent: opening it again (try " + tries + ")");
            new Thread(new Runnable() { public void run() {
                try { openApp(); } catch (Exception e) { android.util.Log.w(TAG, "reopen: " + e); }
            } }, "reopen").start();
        }
        main.postDelayed(this, 30000);
    } };
    private synchronized void beat(boolean front) {
        if (front) {
            lastBeat = System.currentTimeMillis(); tries = 0;
            if (!watching) { watching = true; hold(); main.removeCallbacks(watch); main.postDelayed(watch, 30000); }
        } else if (watching) {
            watching = false; main.removeCallbacks(watch); release();
        }
    }

    private Remote remote() {
        if (remote == null) remote = new Remote(this, TvAddress.find(this));
        return remote;
    }

    private final Binder binder = new Binder() {
        @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
            if (code < PAIR_START || code > HEARTBEAT) {
                try { return super.onTransact(code, data, reply, flags); } catch (Exception e) { return false; }
            }
            String out;
            if (getPackageManager().checkSignatures(android.os.Process.myUid(), Binder.getCallingUid()) != PackageManager.SIGNATURE_MATCH) {
                out = "not allowed";
            } else {
                String arg = data.readString();
                try { out = handle(code, arg == null ? "" : arg); }
                catch (Exception e) { out = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage(); }
            }
            if (code != HEARTBEAT) android.util.Log.i(TAG, "request " + code + ": " + (out.isEmpty() ? "ok" : out));
            if (reply != null) reply.writeString(out);
            return true;
        }
    };

    private String handle(int code, String arg) throws Exception {
        switch (code) {
            case PAIR_START:
                if (remote != null) remote.closePairing();       // pairing again: drop the unfinished one
                remote = null;                                   // the TV's address may have changed
                boolean held = !pairing;
                if (held) hold();                                // until the code arrives, or 3 minutes (once)
                try { remote().startPairing("Claude's Computer helper"); }
                catch (Exception e) { if (held) release(); throw e; }
                new android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(new Runnable() { public void run() {
                    if (pairing) { pairing = false; release(); }
                } }, 180000);
                pairing = true;
                return "";
            case PAIR_CODE:
                try { remote().finishPairing(arg); }
                finally { if (pairing) { pairing = false; release(); } }
                prefs.edit().putBoolean("paired", true).apply();
                return "";
            case KEYS:
                if (!prefs.getBoolean("paired", false)) return "not paired yet";
                disguised(arg.split(","));
                return "";
            case EXPECT_INSTALL:
                if (!prefs.getBoolean("paired", false)) return "not paired yet";
                pressInstall(arg);
                return "";
            case HEARTBEAT:
                beat("front".equals(arg));
                return "";
            case ADB_PAIR: {                                    // "123456" or "123456 41234" (code, pairing port)
                String[] a = arg.trim().split("\\s+");
                return new Adb(this).pair(a[0], a.length > 1 ? a[1] : "");
            }
            case SHELL:
                hold();
                try { return new Adb(this).shell(arg, 60); } finally { release(); }
            default:
                return prefs.getBoolean("paired", false) ? "paired" : "not paired";
        }
    }

    private boolean screenIsOn() {
        return ((android.os.PowerManager) getSystemService(POWER_SERVICE)).isInteractive();
    }

    /** Opens the main app. With "display over other apps" (granted once through adb: appops set dev.ccrd.helper
     *  SYSTEM_ALERT_WINDOW allow), Android lets the helper open it directly; otherwise, or if Android quietly
     *  refused, press it open as the TV's remote. The app says "front" (heartbeat) when it is on screen. */
    private void openApp() throws Exception {
        if (android.os.Build.VERSION.SDK_INT >= 23 && android.provider.Settings.canDrawOverlays(this)) {
            long asked = System.currentTimeMillis();
            try {
                startActivity(new Intent(Intent.ACTION_VIEW, android.net.Uri.parse("claudescomputer://open"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                for (int i = 0; i < 20; i++) { Thread.sleep(500); if (lastBeat >= asked) return; }
                android.util.Log.i(TAG, "opened directly but the app didn't answer: pressing it open instead");
            } catch (Exception e) { android.util.Log.i(TAG, "open directly: " + e); }
        }
        disguised(OPEN_APP);
    }

    /** Runs remote actions through the disguise (LoopVpn): the TV refuses remote control from itself, so the
     *  connection goes to a made-up address and arrives at the TV from a made-up sender. */
    private void disguised(String... actions) throws Exception {
        if (!LoopVpn.allowed(this)) throw new Exception("the disguise isn't allowed yet (ask Claude's Computer to open AllowActivity)");
        hold();
        try {
            LoopVpn.start(this, TvAddress.find(this));
            for (int i = 0; i < 30 && !LoopVpn.up; i++) Thread.sleep(100);
            if (!LoopVpn.up) throw new Exception("the disguise didn't start");
            Exception last = null;
            for (int i = 0; i < 4; i++) {                        // Android takes a moment to route into it
                Thread.sleep(i == 0 ? 1500 : 1000);
                try { new Remote(this, LoopVpn.FAKE_TV).run(actions); return; }
                catch (Exception e) { last = e; }
            }
            throw last;
        } finally { LoopVpn.stop(this); release(); }
    }

    /** The main app is about to ask Android to install its update: press Install on the screen Android shows, wait
     *  for the new version to be in place, then open the app again (Android closes it while updating). */
    private void pressInstall(final String pkg) {
        hold();
        new Thread(new Runnable() { public void run() {
            try {
                long before = updatedAt(pkg);
                Thread.sleep(3500);
                // The installer's buttons are [Update] [Cancel] with Cancel chosen: left, then OK.
                disguised("key:21", "key:23");
                long until = System.currentTimeMillis() + 120000;
                while (System.currentTimeMillis() < until && updatedAt(pkg) == before) Thread.sleep(2000);
                if (updatedAt(pkg) == before) { android.util.Log.w(TAG, "update didn't go in"); return; }
                Thread.sleep(3000);
                openApp();
                android.util.Log.i(TAG, "updated and reopened " + pkg);
            } catch (Exception e) { android.util.Log.w(TAG, "install: " + e); }
            finally { new android.os.Handler(android.os.Looper.getMainLooper()).post(new Runnable() { public void run() { release(); } }); }
        } }, "install").start();
    }

    private long updatedAt(String pkg) {
        try { return getPackageManager().getPackageInfo(pkg, 0).lastUpdateTime; } catch (Exception e) { return -1; }
    }

    @Override public IBinder onBind(Intent i) { return binder; }
}
