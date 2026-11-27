package dev.ccrd.alarmprobe;

import android.app.Activity;
import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.SystemClock;

/** am start -n dev.ccrd.alarmprobe/.Start --es host H --ei port P --ei every SECONDS : remembers where to
 *  connect, sets the first alarm and closes. Each alarm (Tick) tries one connection and sets the next alarm. */
public class Start extends Activity {
    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        Intent i = getIntent();
        getSharedPreferences("p", 0).edit().putString("host", i.getStringExtra("host"))
            .putInt("port", i.getIntExtra("port", 8099)).putInt("every", i.getIntExtra("every", 60)).apply();
        next(this);
        android.util.Log.i("AlarmProbe", "armed");
        finish();
    }
    static void next(Context c) {
        int every = c.getSharedPreferences("p", 0).getInt("every", 60);
        PendingIntent pi = PendingIntent.getBroadcast(c, 1, new Intent(c, Tick.class), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        ((AlarmManager) c.getSystemService(Context.ALARM_SERVICE))
            .setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + every * 1000L, pi);
    }
}
