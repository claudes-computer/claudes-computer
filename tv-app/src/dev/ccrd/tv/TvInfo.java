package dev.ccrd.tv;

import android.content.Context;
import android.graphics.Bitmap;
import android.os.Build;
import android.os.Handler;
import android.view.InputDevice;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** The TV describing itself to the desktop (ccrdnet report.go): served on the app's private tailnet service, so
 *  Claude can see what a TV is doing without a laptop or adb. Only the user's own desktop can ask. */
class TvInfo implements ccrdnet.TVInfo {
    private final MainActivity act;
    private final Context ctx;
    private final Handler main;

    private final Updater updater;

    TvInfo(MainActivity a, Handler h) {
        act = a; ctx = a.getApplicationContext(); main = h;
        updater = new Updater(a, ctx, h);
    }

    @Override public String report() {
        JSONObject j = new JSONObject();
        try {
            android.content.pm.PackageInfo p = ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0);
            j.put("app", new JSONObject().put("id", ctx.getPackageName()).put("version", p.versionName)
                .put("build", Build.VERSION.SDK_INT >= 28 ? p.getLongVersionCode() : p.versionCode));
            j.put("tv", new JSONObject().put("maker", Build.MANUFACTURER).put("model", Build.MODEL)
                .put("android", Build.VERSION.RELEASE));
            android.os.PowerManager pm = (android.os.PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            j.put("screen_on", pm != null && pm.isInteractive());
            j.put("showing", act.showing());
            j.put("blanked", act.blanked());
            j.put("computer", act.host());
            j.put("microphone_on", act.micOn());
            j.put("up_minutes", android.os.SystemClock.elapsedRealtime() / 60000);
            j.put("cameras", cameras());
            j.put("microphones", microphones());
            j.put("input_devices", inputDevices());
        } catch (Exception e) {
            try { j.put("error", e.getClass().getSimpleName()); } catch (Exception ignored) { }
        }
        return j.toString();
    }

    private JSONArray cameras() {
        JSONArray a = new JSONArray();
        try {
            android.hardware.camera2.CameraManager cm = (android.hardware.camera2.CameraManager) ctx.getSystemService(Context.CAMERA_SERVICE);
            for (String id : cm.getCameraIdList()) {
                Integer f = cm.getCameraCharacteristics(id).get(android.hardware.camera2.CameraCharacteristics.LENS_FACING);
                String facing = f == null ? "?" : f == 0 ? "front" : f == 1 ? "back" : "external";
                a.put(new JSONObject().put("id", id).put("facing", facing));
            }
        } catch (Exception e) { a.put("error: " + e.getClass().getSimpleName()); }
        return a;
    }

    private JSONArray microphones() {
        JSONArray a = new JSONArray();
        if (Build.VERSION.SDK_INT < 23) return a;
        try {
            android.media.AudioManager am = (android.media.AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
            for (android.media.AudioDeviceInfo d : am.getDevices(android.media.AudioManager.GET_DEVICES_INPUTS)) {
                int t = d.getType();
                String kind = t == android.media.AudioDeviceInfo.TYPE_BUILTIN_MIC ? "built-in"
                    : t == android.media.AudioDeviceInfo.TYPE_USB_DEVICE || t == android.media.AudioDeviceInfo.TYPE_USB_HEADSET ? "usb"
                    : t == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO ? "bluetooth" : "other";
                if (kind.equals("other")) continue;            // TV tuners, HDMI inputs and the like
                a.put(new JSONObject().put("name", String.valueOf(d.getProductName())).put("kind", kind));
            }
        } catch (Exception e) { a.put("error: " + e.getClass().getSimpleName()); }
        return a;
    }

    private JSONArray inputDevices() {
        JSONArray a = new JSONArray();
        try {
            for (int id : InputDevice.getDeviceIds()) {
                InputDevice d = InputDevice.getDevice(id);
                if (d == null || d.isVirtual()) continue;
                int s = d.getSources();
                boolean kb = d.getKeyboardType() == InputDevice.KEYBOARD_TYPE_ALPHABETIC;
                boolean mouse = (s & InputDevice.SOURCE_MOUSE) == InputDevice.SOURCE_MOUSE;
                if (!kb && !mouse) continue;                    // remotes, buttons, HDMI-CEC
                a.put(new JSONObject().put("name", d.getName()).put("keyboard", kb).put("mouse", mouse));
            }
        } catch (Exception e) { a.put("error: " + e.getClass().getSimpleName()); }
        return a;
    }

    // Updates and the repair helper: Updater.java.
    @Override public String installUpdate(String path) { return updater.installUpdate(path); }
    @Override public String helper(String action, String arg) {
        if ("blank".equals(action)) return blank(!"off".equals(arg));
        return updater.helper(action, arg);
    }

    /** "Off" that keeps the TV awake (MainActivity.blankOn): brings the app to the front first if it isn't. */
    private String blank(final boolean on) {
        if (on && !act.inFront()) {
            if (!HelperLink.installed(ctx)) return "the app isn't in front and there's no helper to open it";
            HelperLink.call(ctx, HelperLink.KEYS, "link:claudescomputer://open", 30);
            for (int i = 0; i < 30 && !act.inFront(); i++) { try { Thread.sleep(200); } catch (InterruptedException e) { break; } }
            if (!act.inFront()) return "couldn't bring the app to the front";
        }
        final CountDownLatch done = new CountDownLatch(1);
        main.post(new Runnable() { public void run() { if (on) act.blankOn(); else act.unblank(); done.countDown(); } });
        try { done.await(5, TimeUnit.SECONDS); } catch (InterruptedException ignored) { }
        return on ? "blank: picture off, TV awake" : "blank off: picture back";
    }

    @Override public void notice(final String what) {
        main.post(new Runnable() { public void run() { act.claudeNotice(what); } });
    }

    /** The app's window as a PNG (PixelCopy, Android 8+). Waits up to 5 seconds for the main thread. */
    @Override public byte[] screenshot() {
        if (Build.VERSION.SDK_INT < 26) return new byte[0];
        final Bitmap[] out = new Bitmap[1];
        final CountDownLatch done = new CountDownLatch(1);
        main.post(new Runnable() { public void run() {
            try {
                android.view.View v = act.getWindow().getDecorView();
                final Bitmap bm = Bitmap.createBitmap(Math.max(1, v.getWidth()), Math.max(1, v.getHeight()), Bitmap.Config.ARGB_8888);
                android.view.PixelCopy.request(act.getWindow(), bm, new android.view.PixelCopy.OnPixelCopyFinishedListener() {
                    public void onPixelCopyFinished(int result) {
                        if (result == android.view.PixelCopy.SUCCESS) out[0] = bm;
                        done.countDown();
                    }
                }, main);
            } catch (Exception e) { done.countDown(); }
        } });
        try { done.await(5, TimeUnit.SECONDS); } catch (InterruptedException ignored) { }
        if (out[0] == null) return new byte[0];
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        out[0].compress(Bitmap.CompressFormat.PNG, 100, b);
        return b.toByteArray();
    }
}
