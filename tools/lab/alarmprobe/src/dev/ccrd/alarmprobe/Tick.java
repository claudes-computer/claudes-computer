package dev.ccrd.alarmprobe;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.PowerManager;
import java.net.InetSocketAddress;
import java.net.Socket;

/** The alarm went off: try one connection right away and one 20 seconds later (after the alarm's window should
 *  have closed), log both, set the next alarm. */
public class Tick extends BroadcastReceiver {
    @Override public void onReceive(final Context c, Intent i) {
        final PendingResult done = goAsync();
        final String host = c.getSharedPreferences("p", 0).getString("host", "");
        final int port = c.getSharedPreferences("p", 0).getInt("port", 8099);
        final boolean screenOn = ((PowerManager) c.getSystemService(Context.POWER_SERVICE)).isInteractive();
        Start.next(c);
        new Thread(new Runnable() { public void run() {
            android.util.Log.i("AlarmProbe", "alarm screen=" + (screenOn ? "on" : "off") + " connect=" + tryConnect(host, port));
            done.finish();
            try { Thread.sleep(20000); } catch (InterruptedException e) { }
            android.util.Log.i("AlarmProbe", "20s-later screen=" + (screenOn ? "on" : "off") + " connect=" + tryConnect(host, port));
        } }).start();
    }
    static String tryConnect(String host, int port) {
        try (Socket s = new Socket()) { s.connect(new InetSocketAddress(host, port), 4000); return "OK"; }
        catch (Exception e) { return "FAIL(" + e.getClass().getSimpleName() + ")"; }
    }
}
