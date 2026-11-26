package dev.ccrd.helper;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** The TV was turned on or restarted: open Claude's Computer, so the TV is back on the private network (Tailscale
 *  lives inside the app) without anyone touching the remote. The helper does it as the TV's own remote. */
public class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent i) {
        String a = i.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(a) && !"android.intent.action.LOCKED_BOOT_COMPLETED".equals(a)) return;
        Intent s = new Intent(c, HelperService.class).setAction(HelperService.BOOT);
        try {
            if (android.os.Build.VERSION.SDK_INT >= 26) c.startForegroundService(s); else c.startService(s);
        } catch (Exception e) { android.util.Log.w("ClaudeHelper", "boot: " + e); }
    }
}
