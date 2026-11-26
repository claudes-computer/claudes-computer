package dev.ccrd.tv;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;

/** Keeps the app alive while it isn't on screen: while the desktop's sound keeps playing behind another app (the way
 *  a music app does), and, quietly, after the desktop hung up (the TV turned off, or another app took the speakers).
 *  Without it Android 12+ freezes the app within seconds (its cached-app freezer), and a frozen app drops off the
 *  private network, so Claude can't reach the TV. MainActivity stops it when the app comes back on screen. */
public class KeepPlaying extends Service {
    static void start(Context c) { start(c, false); }
    /** standby: the desktop hung up; only stay reachable. */
    static void start(Context c, boolean standby) {
        Intent i = new Intent(c, KeepPlaying.class).putExtra("standby", standby);
        try {
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i); else c.startService(i);
        } catch (Exception e) { android.util.Log.w("ClaudeDesktop", "keep playing: " + e); }
    }

    static void stop(Context c) { c.stopService(new Intent(c, KeepPlaying.class)); }

    @Override public int onStartCommand(Intent intent, int flags, int id) {
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            nm.createNotificationChannel(new NotificationChannel("sound", "Desktop sound", NotificationManager.IMPORTANCE_LOW));
            b = new Notification.Builder(this, "sound");
        } else {
            b = new Notification.Builder(this);
        }
        b.setSmallIcon(getApplicationInfo().icon).setContentTitle("Claude's Computer")
            .setContentText(intent != null && intent.getBooleanExtra("standby", false)
                ? "Standing by. Open the app to come back to your desktop."
                : "The desktop's sound keeps playing. Open the app to come back.").setOngoing(true);
        startForeground(1, b.build());
        return START_NOT_STICKY;
    }

    @Override public IBinder onBind(Intent i) { return null; }
}
