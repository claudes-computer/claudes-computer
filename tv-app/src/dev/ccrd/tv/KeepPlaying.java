package dev.ccrd.tv;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;

/** Keeps the app alive while the person is in another app and the desktop's sound is still playing, the way a
 *  music app does: Android doesn't close an app that runs a media service. MainActivity starts it when the app
 *  leaves the screen and stops it when the app comes back or another app takes the speakers (audio focus). */
public class KeepPlaying extends Service {
    static void start(Context c) {
        Intent i = new Intent(c, KeepPlaying.class);
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
            .setContentText("The desktop's sound keeps playing. Open the app to come back.").setOngoing(true);
        startForeground(1, b.build());
        return START_NOT_STICKY;
    }

    @Override public IBinder onBind(Intent i) { return null; }
}
