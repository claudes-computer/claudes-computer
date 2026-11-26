package dev.ccrd.tv;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.IBinder;
import android.os.Parcel;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Talks to the repair helper (../helper, package dev.ccrd.helper): a separate app this one carries inside itself
 *  (assets/helper.apk) and installs when asked. Calls block, so never from the main thread. */
final class HelperLink {
    static final String PKG = "dev.ccrd.helper";
    static final int PAIR_START = 1, PAIR_CODE = 2, KEYS = 3, EXPECT_INSTALL = 4, STATUS = 5, ADB_PAIR = 6, SHELL = 7, HEARTBEAT = 8;

    static boolean installed(Context c) {
        try { c.getPackageManager().getPackageInfo(PKG, 0); return true; } catch (Exception e) { return false; }
    }

    /** Tells the helper's watchdog the app is on screen ("front", repeat every 30 s) or was left ("away"). */
    static void beat(final Context c, final boolean front) {
        if (!installed(c)) return;
        new Thread(new Runnable() { public void run() { call(c, HEARTBEAT, front ? "front" : "away", 5); } }, "beat").start();
    }

    /** Sends one request; returns "" or an error message. */
    static String call(Context c, int code, String arg, int timeoutSec) {
        if (!installed(c)) return "the helper isn't installed";
        final IBinder[] b = new IBinder[1];
        final CountDownLatch up = new CountDownLatch(1);
        ServiceConnection conn = new ServiceConnection() {
            public void onServiceConnected(ComponentName n, IBinder s) { b[0] = s; up.countDown(); }
            public void onServiceDisconnected(ComponentName n) { }
        };
        Context app = c.getApplicationContext();
        try {
            if (!app.bindService(new Intent().setComponent(new ComponentName(PKG, PKG + ".HelperService")), conn, Context.BIND_AUTO_CREATE))
                return "couldn't reach the helper";
            if (!up.await(10, TimeUnit.SECONDS)) return "the helper didn't answer";
            // The call runs on its own thread, so a stuck helper can't hold this one past the time it was given.
            final String[] r = new String[1];
            final CountDownLatch done = new CountDownLatch(1);
            final IBinder binder = b[0]; final int cd = code; final String a = arg;
            new Thread(new Runnable() { public void run() {
                Parcel in = Parcel.obtain(), out = Parcel.obtain();
                try { in.writeString(a); binder.transact(cd, in, out, 0); r[0] = out.readString(); }
                catch (Exception e) { r[0] = "helper: " + e.getClass().getSimpleName(); }
                finally { in.recycle(); out.recycle(); done.countDown(); }
            } }, "helper-call").start();
            if (!done.await(Math.max(timeoutSec, 5), TimeUnit.SECONDS)) return "the helper didn't answer in time";
            return r[0] == null ? "no answer" : r[0];
        } catch (Exception e) {
            return "helper: " + e.getClass().getSimpleName();
        } finally {
            try { app.unbindService(conn); } catch (Exception e) { }
        }
    }
}
