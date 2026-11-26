package dev.ccrd.tv;

import android.content.Context;
import android.os.Build;
import android.os.Handler;

/** Installing things on the TV: this app's own updates (sent by the desktop, ccrdnet desktop.go) and the repair
 *  helper it carries (assets/helper.apk), plus the desktop's requests to that helper (HelperLink.java). */
class Updater {
    static final String INSTALL_STATUS = "dev.ccrd.tv.INSTALL_STATUS";
    private static boolean registered;
    private static final java.util.Set<Integer> SESSIONS = java.util.Collections.synchronizedSet(new java.util.HashSet<Integer>());
    private final MainActivity act;
    private final Context ctx;
    private final Handler main;

    Updater(MainActivity a, Context c, Handler h) {
        act = a; ctx = c; main = h;
        // Android answers an update here, not to the screen, so a settings page left open can't swallow it.
        // Once per process (the activity can be created many times), and only for install sessions this app
        // started: any app could send this broadcast, but it can't know a session number we haven't used.
        synchronized (Updater.class) { if (registered) return; registered = true; }
        ctx.registerReceiver(new android.content.BroadcastReceiver() {
            @Override public void onReceive(Context c, android.content.Intent i) {
                if (!SESSIONS.contains(i.getIntExtra(android.content.pm.PackageInstaller.EXTRA_SESSION_ID, -1))) return;
                int st = i.getIntExtra(android.content.pm.PackageInstaller.EXTRA_STATUS, -999);
                android.util.Log.i("ClaudeDesktop", "update: status " + st + " " + i.getStringExtra(android.content.pm.PackageInstaller.EXTRA_STATUS_MESSAGE));
                if (st != android.content.pm.PackageInstaller.STATUS_PENDING_USER_ACTION) return;
                android.content.Intent confirm = (android.content.Intent) i.getParcelableExtra(android.content.Intent.EXTRA_INTENT);
                if (confirm != null) c.startActivity(confirm.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK));
            }
        }, new android.content.IntentFilter(INSTALL_STATUS));
    }

    /** Hands a downloaded APK to Android's installer. Android shows its own "update this app?" screen and only
     *  accepts a file signed with this app's key. The first time, the user must allow this app to install apps.
     *  With the repair helper paired, the helper presses Install and opens the app again afterwards. */
    String installUpdate(String path) {
        try {
            java.io.File f = new java.io.File(path);
            return install(new java.io.FileInputStream(f), f.length(), ctx.getPackageName(), true);
        } catch (Exception e) { return "install: " + e.getClass().getSimpleName() + " " + e.getMessage(); }
    }

    private String install(java.io.InputStream in, long size, String pkg, boolean helperPresses) {
        try {
            if (Build.VERSION.SDK_INT >= 26 && !ctx.getPackageManager().canRequestPackageInstalls()) {
                main.post(new Runnable() { public void run() {
                    act.startActivity(new android.content.Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        android.net.Uri.parse("package:" + ctx.getPackageName())).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK));
                } });
                return "allow this app to install apps on the TV (the setting is open now), then try again";
            }
            android.content.pm.PackageInstaller pi = ctx.getPackageManager().getPackageInstaller();
            android.content.pm.PackageInstaller.SessionParams sp = new android.content.pm.PackageInstaller.SessionParams(
                android.content.pm.PackageInstaller.SessionParams.MODE_FULL_INSTALL);
            sp.setAppPackageName(pkg);
            int id = pi.createSession(sp);
            SESSIONS.add(id);
            android.content.pm.PackageInstaller.Session s = pi.openSession(id);
            java.io.OutputStream out = s.openWrite("app", 0, size);
            byte[] buf = new byte[65536]; int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            s.fsync(out); out.close(); in.close();
            if (helperPresses) HelperLink.call(ctx, HelperLink.EXPECT_INSTALL, pkg, 5);   // no helper: the person presses
            android.content.Intent back = new android.content.Intent(INSTALL_STATUS).setPackage(ctx.getPackageName());
            int flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? 1 << 25 : 0);   // mutable
            s.commit(android.app.PendingIntent.getBroadcast(ctx, id, back, flags).getIntentSender());
            s.close();
            return "";
        } catch (Exception e) {
            return "install: " + e.getClass().getSimpleName() + " " + e.getMessage();
        }
    }

    /** The repair helper, for the desktop (POST /tv/helper): install it (from inside this app; the person presses
     *  Install once), pair it (the TV shows a code; the person reads it to Claude, who sends it with "code"), press
     *  keys ("keys": key:<keycode>,link:<uri>,wait:<ms>), power, status. */
    String helper(String action, String arg) {
        switch (action) {
            case "install":
                // Also updates an older helper (Android asks the person to confirm either way).
                try { android.content.res.AssetFileDescriptor a = ctx.getAssets().openFd("helper.apk");
                      return install(a.createInputStream(), a.getLength(), HelperLink.PKG, false); }
                catch (Exception e) {
                    try { java.io.InputStream i = ctx.getAssets().open("helper.apk"); return install(i, i.available(), HelperLink.PKG, false); }
                    catch (Exception e2) { return "no helper in this build"; }
                }
            case "allow":                                       // Android's one-time "allow the helper's VPN?"
                main.post(new Runnable() { public void run() {
                    try { act.startActivity(new android.content.Intent().setComponent(
                        new android.content.ComponentName(HelperLink.PKG, HelperLink.PKG + ".AllowActivity"))); }
                    catch (Exception e) { android.util.Log.w("ClaudeDesktop", "allow: " + e); }
                } });
                return "";
            case "pair":   return HelperLink.call(ctx, HelperLink.PAIR_START, "", 40);
            case "code":   return HelperLink.call(ctx, HelperLink.PAIR_CODE, arg, 30);
            case "keys":   return HelperLink.call(ctx, HelperLink.KEYS, arg, 40);
            case "power":  return HelperLink.call(ctx, HelperLink.KEYS, "key:26", 30);
            case "adbpair": return HelperLink.call(ctx, HelperLink.ADB_PAIR, arg, 40);
            case "shell":  return HelperLink.call(ctx, HelperLink.SHELL, arg, 90);
            case "status": return HelperLink.installed(ctx) ? HelperLink.call(ctx, HelperLink.STATUS, "", 10) : "not installed";
            default:       return "unknown: " + action;
        }
    }
}
