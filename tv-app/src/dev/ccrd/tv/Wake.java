package dev.ccrd.tv;

import android.content.SharedPreferences;
import android.os.Handler;
import android.view.KeyEvent;
import android.webkit.WebView;

import org.json.JSONObject;

/** Waking the computer from the TV, without a phone.
 *
 *  The cloud computer only wakes when its Claude session gets a message. Claude Code's scheduled tasks have an
 *  official way to do that from outside: an "API trigger", a web address plus a token that can do exactly one
 *  thing, start that one task (here: say "desktop on" to the session). The owner generates the token once on
 *  claude.ai; the desktop hands it to this app's safe (ccrdnet ServeKeep, file "wake.json": fire_url + token).
 *
 *  On the "asleep" screen: OK, a 4-digit PIN, and the app calls that address. The PIN is there because the token
 *  starts a live Claude session on someone's account: not everyone who picks up the remote should be able to. */
class Wake {
    private static final int NORMAL = 0, INTRO = 1, PIN_NEW = 3, PIN_AGAIN = 4, PIN_ENTER = 5, WAKING = 6, NOTE = 7;

    private final MainActivity act;
    private final WebView status;      // the app's status page
    private final Handler handler;
    private final SharedPreferences prefs;
    private final java.io.File tokenFile;
    private int mode = NORMAL;
    private String digits = "", first = "";
    private int cur = -1;              // digit being chosen with up/down on a remote without number keys
    private long lastSent = 0;

    /** host: which computer this wakes ("ccrd", "ccrd-work", ...). Each has its own token (the desktop puts it in
     *  its own folder of the keep store) and its own PIN. */
    Wake(MainActivity a, WebView statusView, Handler h, String host) {
        act = a; status = statusView; handler = h;
        boolean first = "ccrd".equals(host);
        prefs = a.getSharedPreferences(first ? "wake" : "wake-" + host, 0);
        tokenFile = new java.io.File(a.getFilesDir(), first ? "keep/wake.json" : "keep/" + host + "/wake.json");
    }

    /** True while one of this class's screens is up: the app's own status messages wait. */
    boolean busy() { return mode != NORMAL && mode != WAKING; }
    boolean waking() { return mode == WAKING; }
    private boolean hasToken() { return tokenFile.length() > 20; }
    /** The PIN belongs to the token it was chosen for: a new token from the desktop asks for a new PIN. */
    private boolean hasPin() { return prefs.contains("pin") && prefs.getLong("pin_for", 0) == tokenFile.lastModified(); }

    /** The extra line on the asleep screen. */
    String hint() {
        if (!hasToken()) return "To wake it from this TV instead, ask Claude once: “set up waking from the TV”.";
        return hasPin() ? "Or wake it from here: press OK and enter your PIN."
                        : "No phone handy? Press OK to choose a PIN for waking it from this TV.";
    }

    /** The desktop came up, or the app is leaving: drop back to normal. */
    void reset() { mode = NORMAL; digits = ""; first = ""; cur = -1; }

    // ---- keys (only called while the desktop is not on screen) ----

    /** Returns true if the key was used. */
    boolean key(int code) {
        boolean ok = code == KeyEvent.KEYCODE_DPAD_CENTER || code == KeyEvent.KEYCODE_ENTER || code == KeyEvent.KEYCODE_NUMPAD_ENTER;
        boolean back = code == KeyEvent.KEYCODE_BACK || code == KeyEvent.KEYCODE_ESCAPE;
        switch (mode) {
            case NORMAL:
                if (!ok || !act.isAsleep() || !hasToken()) return false;
                if (hasPin()) startPin(PIN_ENTER);
                else { mode = INTRO; panel("Wake it from this TV",
                    "Choose a 4-digit PIN. After that, this TV can wake your computer without your phone: press OK on the asleep screen and enter the PIN.",
                    "Press OK to choose a PIN, or Back to cancel.", "🔑"); }
                return true;
            case INTRO:
                if (ok) startPin(PIN_NEW); else if (back) leave();
                return ok || back;
            case NOTE:
                if (ok || back) leave();
                return true;
            case WAKING:
                return ok;   // nothing to do; the app is already checking
            default:
                return pinKey(code, ok, back);
        }
    }

    private boolean pinKey(int code, boolean ok, boolean back) {
        int d = -1;
        if (code >= KeyEvent.KEYCODE_0 && code <= KeyEvent.KEYCODE_9) d = code - KeyEvent.KEYCODE_0;
        else if (code >= KeyEvent.KEYCODE_NUMPAD_0 && code <= KeyEvent.KEYCODE_NUMPAD_9) d = code - KeyEvent.KEYCODE_NUMPAD_0;
        if (d >= 0) { digits += d; cur = -1; }
        else if (code == KeyEvent.KEYCODE_DPAD_UP) cur = cur < 0 ? 0 : (cur + 1) % 10;
        else if (code == KeyEvent.KEYCODE_DPAD_DOWN) cur = cur < 0 ? 9 : (cur + 9) % 10;
        else if ((ok || code == KeyEvent.KEYCODE_DPAD_RIGHT) && cur >= 0) { digits += cur; cur = -1; }
        else if (code == KeyEvent.KEYCODE_DEL || code == KeyEvent.KEYCODE_DPAD_LEFT) {
            if (cur >= 0) cur = -1; else if (!digits.isEmpty()) digits = digits.substring(0, digits.length() - 1);
        }
        else if (back) { leave(); return true; }
        else return false;
        if (digits.length() == 4) pinDone(); else drawPin("");
        return true;
    }

    private void startPin(int m) { mode = m; digits = ""; cur = -1; drawPin(""); }

    private void drawPin(String note) {
        String title = mode == PIN_ENTER ? "Enter your PIN" : mode == PIN_NEW ? "Choose a PIN" : "Type it again";
        String msg = mode == PIN_ENTER ? "To wake your computer from this TV."
            : mode == PIN_NEW ? "Four digits. You'll use it to wake your computer from this TV."
            : "Once more, to make sure.";
        String how = "Number keys, or up/down then OK on the remote. Back cancels.";
        status.evaluateJavascript("pin(" + JSONObject.quote(title) + "," + JSONObject.quote(msg) + "," + digits.length()
            + "," + cur + "," + JSONObject.quote(note.isEmpty() ? how : note) + ")", null);
    }

    private void pinDone() {
        String entered = digits; digits = ""; cur = -1;
        if (mode == PIN_NEW) { first = entered; mode = PIN_AGAIN; drawPin(""); return; }
        if (mode == PIN_AGAIN) {
            if (!entered.equals(first)) { mode = PIN_NEW; first = ""; drawPin("Those didn't match. Choose a PIN again."); return; }
            String salt = Long.toHexString(new java.security.SecureRandom().nextLong());
            prefs.edit().putString("salt", salt).putString("pin", hash(salt, entered)).putInt("tries", 0)
                .putLong("pin_for", tokenFile.lastModified()).apply();
            first = ""; mode = NOTE;
            panel("This TV can wake your computer", "Next time it's asleep: press OK here and enter your PIN.", "Press OK.", "✅");
            act.refreshHint();
            return;
        }
        // PIN_ENTER
        long lockedUntil = prefs.getLong("locked", 0), now = System.currentTimeMillis();
        if (now < lockedUntil) { drawPin("Too many wrong tries. Wait " + ((lockedUntil - now) / 1000 + 1) + " s."); return; }
        if (hash(prefs.getString("salt", ""), entered).equals(prefs.getString("pin", ""))) {
            prefs.edit().putInt("tries", 0).putInt("locks", 0).apply();
            send();
        } else {
            int tries = prefs.getInt("tries", 0) + 1;
            SharedPreferences.Editor e = prefs.edit().putInt("tries", tries);
            // Each lockout is twice as long as the last (1, 2, 4 ... minutes, at most an hour), until the right PIN.
            int locks = prefs.getInt("locks", 0);
            long wait = Math.min(60000L << Math.min(locks, 6), 3600000L);
            if (tries >= 5) e.putLong("locked", now + wait).putInt("tries", 0).putInt("locks", locks + 1);
            e.apply();
            drawPin(tries >= 5 ? "Too many wrong tries. Wait " + (wait / 60000) + " min." : "Wrong PIN. Try again.");
        }
    }

    private static String hash(String salt, String pin) {
        try {
            byte[] b = (salt + ":" + pin).getBytes("UTF-8");
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            for (int i = 0; i < 5000; i++) b = md.digest(b);
            StringBuilder s = new StringBuilder();
            for (byte x : b) s.append(String.format("%02x", x));
            return s.toString();
        } catch (Exception e) { return ""; }
    }

    private void panel(String title, String msg, String detail, String icon) {
        status.evaluateJavascript("panel(" + JSONObject.quote(title) + "," + JSONObject.quote(msg) + ","
            + JSONObject.quote(detail) + "," + JSONObject.quote(icon) + ")", null);
    }

    private void leave() { reset(); act.refreshStatus(); }

    // ---- the wake call ----

    private void send() {
        mode = WAKING;
        panel("Waking your computer…", "Asking Claude to turn it on. This takes about a minute; the desktop opens by itself.", "", "⏳");
        act.wakeRequested();
        if (System.currentTimeMillis() - lastSent < 90000) return;      // already asked a moment ago
        new Thread(new Runnable() { public void run() {
            final int code = fire();
            handler.post(new Runnable() { public void run() {
                android.util.Log.i("ClaudeDesktop", "wake: HTTP " + code);
                if (code >= 200 && code < 300) { lastSent = System.currentTimeMillis(); return; }
                if (mode != WAKING) return;
                mode = NOTE;
                panel("Couldn't wake it from here",
                    code == 401 || code == 403 || code == 404 ? "The wake token isn't valid anymore. Ask Claude to set up waking from the TV again."
                    : code == 429 ? "Too many wake-ups in the last hour. Try again later."
                    : code == 0 ? "This TV couldn't reach Claude. Check its internet connection."
                    : "Claude answered with error " + code + ".",
                    "You can still say “desktop on” in the Claude app on your phone. Press OK.", "⚠️");
            } });
        } }, "wake").start();
    }

    /** POSTs to the task's fire address. Returns the HTTP status, or 0 if the call couldn't be made. */
    private int fire() {
        java.net.HttpURLConnection c = null;
        try {
            byte[] raw = new byte[(int) tokenFile.length()];
            java.io.FileInputStream in = new java.io.FileInputStream(tokenFile);
            try { int n = 0; while (n < raw.length) { int r = in.read(raw, n, raw.length - n); if (r < 0) break; n += r; } } finally { in.close(); }
            JSONObject j = new JSONObject(new String(raw, "UTF-8"));
            String url = j.getString("fire_url"), token = j.getString("token");
            if (!url.startsWith("https://api.anthropic.com/")) return 0;     // the token only ever goes to Anthropic
            c = (java.net.HttpURLConnection) new java.net.URL(url).openConnection();
            c.setConnectTimeout(15000); c.setReadTimeout(30000);
            c.setRequestMethod("POST"); c.setDoOutput(true);
            c.setRequestProperty("Authorization", "Bearer " + token);
            c.setRequestProperty("anthropic-beta", "experimental-cc-routine-2026-04-01");
            c.setRequestProperty("anthropic-version", "2023-06-01");
            c.setRequestProperty("Content-Type", "application/json");
            c.getOutputStream().write("{}".getBytes("UTF-8"));
            return c.getResponseCode();
        } catch (Exception e) {
            android.util.Log.w("ClaudeDesktop", "wake: " + e.getClass().getSimpleName());
            return 0;
        } finally { if (c != null) c.disconnect(); }
    }
}
