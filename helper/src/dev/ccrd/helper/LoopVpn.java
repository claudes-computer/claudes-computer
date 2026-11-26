package dev.ccrd.helper;

import android.content.Context;
import android.content.Intent;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;

import java.io.FileInputStream;
import java.io.FileOutputStream;

/** The disguise: the TV's remote-control service refuses connections from the TV itself, so the helper reaches it
 *  through a made-up network that only exists inside this app (Android's VPN feature, but nothing leaves the TV).
 *
 *  The helper connects to 10.111.0.1. Those packets come here; we rewrite them to go to the TV's real address,
 *  from a made-up sender 10.111.0.3, and hand them back to Android. The remote service sees a stranger and answers
 *  it; the answers come back here and we turn them back into 10.111.0.1 -> the helper. Only that made-up network
 *  is routed here, so the rest of the TV's traffic is untouched. */
public class LoopVpn extends VpnService implements Runnable {
    static final String FAKE_TV = "10.111.0.1";
    static volatile boolean up = false;
    private static volatile byte[] tv;
    private ParcelFileDescriptor tun;
    private Thread loop;

    static boolean allowed(Context c) { return VpnService.prepare(c) == null; }

    static void start(Context c, String tvAddress) { c.startService(new Intent(c, LoopVpn.class).putExtra("tv", tvAddress)); }
    static void stop(Context c) { c.startService(new Intent(c, LoopVpn.class).setAction("stop")); }

    @Override public int onStartCommand(Intent i, int flags, int id) {
        if (i != null && "stop".equals(i.getAction())) { close(); stopSelf(); return START_NOT_STICKY; }
        try {
            tv = java.net.InetAddress.getByName(i.getStringExtra("tv")).getAddress();
            if (tun == null) {
                // Not limited to this app (addAllowedApplication): the TV's remote service answers the made-up
                // stranger, and those answers have to come back in here too. Tried it; the connection then times out.
                tun = new Builder().setSession("Claude's Computer helper")
                    .addAddress("10.111.0.2", 24).addRoute("10.111.0.0", 24).setBlocking(true).establish();
                if (tun == null) throw new Exception("not allowed");
                loop = new Thread(this, "loop"); loop.start();
            }
            up = true;
        } catch (Exception e) { android.util.Log.w("ClaudeHelper", "vpn: " + e); close(); }
        return START_NOT_STICKY;
    }

    private synchronized void close() {
        up = false;
        try { if (tun != null) tun.close(); } catch (Exception e) { }
        tun = null;
    }

    @Override public void onRevoke() { close(); super.onRevoke(); }
    @Override public void onDestroy() { close(); super.onDestroy(); }

    @Override public void run() {
        ParcelFileDescriptor t = tun;
        if (t == null) return;
        FileInputStream in = new FileInputStream(t.getFileDescriptor());
        FileOutputStream out = new FileOutputStream(t.getFileDescriptor());
        byte[] b = new byte[32767];
        try {
            while (tun == t) {
                int n = in.read(b);
                if (!Packets.rewrite(b, n, tv)) continue;
                out.write(b, 0, n);
            }
        } catch (Exception e) { if (tun == t) android.util.Log.w("ClaudeHelper", "loop: " + e); }
    }
}
