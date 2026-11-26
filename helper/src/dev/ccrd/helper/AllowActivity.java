package dev.ccrd.helper;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

/** Shows Android's one-time "allow this VPN?" question for the helper's disguise (LoopVpn), then closes.
 *  Claude's Computer opens it when asked to set up the helper. */
public class AllowActivity extends Activity {
    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        Intent ask = android.net.VpnService.prepare(this);
        if (ask == null) { finish(); return; }
        startActivityForResult(ask, 1);
    }
    @Override protected void onActivityResult(int req, int res, Intent data) { finish(); }
}
