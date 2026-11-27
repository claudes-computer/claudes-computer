package dev.ccrd.tv;

import android.os.Handler;
import android.view.View;

import ccrdnet.Ccrdnet;

/** More than one computer: every Claude session is its own computer, and so is every other agent's desktop on the
 *  tailnet (Codex's, Muse's: anything serving the stream; ccrdnet computers.go). This is the "Choose a computer"
 *  tiles over the desktop or the status screen, and the count of computers this TV can see. */
class ComputerPicker {
    private final MainActivity act;
    private final android.widget.FrameLayout root;
    private final Handler handler;
    private android.view.View picker;
    private int computers = 1;              // counted when the list opens and while the TV waits on the asleep screen

    ComputerPicker(MainActivity a, android.widget.FrameLayout r, Handler h) { act = a; root = r; handler = h; }

    boolean showing() { return picker != null; }
    int count() { return computers; }

    /** "ccrd" is Claude's; "ccrd-codex" is ChatGPT's, "ccrd-muse" Muse's; "ccrd-work" is "Work". */
    static String label(String h) {
        if ("ccrd".equals(h)) return "Claude";
        if ("ccrd-codex".equals(h)) return "ChatGPT";
        String n = h.startsWith("ccrd-") ? h.substring(5) : h;
        n = n.replace('-', ' ');
        return n.isEmpty() ? h : Character.toUpperCase(n.charAt(0)) + n.substring(1);
    }

    /** Counts the computers in the background; tells the activity when the number changed. */
    void recount() {
        new Thread(new Runnable() { public void run() {
            int n = 1;
            try { n = Math.max(1, new org.json.JSONArray(Ccrdnet.desktops()).length()); } catch (Exception e) { }
            final int c = n;
            handler.post(new Runnable() { public void run() {
                if (c != computers) { computers = c; act.computersChanged(); }
            } });
        } }, "computers").start();
    }

    void show() {
        new Thread(new Runnable() { public void run() {
            final String list = Ccrdnet.desktops();
            handler.post(new Runnable() { public void run() { draw(list); } });
        } }, "computers").start();
    }

    private void draw(String json) {
        hide();
        org.json.JSONArray a;
        try { a = new org.json.JSONArray(json); } catch (Exception e) { a = new org.json.JSONArray(); }
        computers = Math.max(1, a.length());

        // A dimmed screen with one rounded card in the middle.
        android.widget.FrameLayout scrim = new android.widget.FrameLayout(act);
        scrim.setBackgroundColor(0x99000000);
        android.widget.LinearLayout card = new android.widget.LinearLayout(act);
        card.setOrientation(android.widget.LinearLayout.VERTICAL);
        card.setBackground(Ui.round(act, Ui.PANEL, 24, Ui.EDGE));
        card.setPadding(Ui.dp(act, 28), Ui.dp(act, 26), Ui.dp(act, 28), Ui.dp(act, 22));
        if (android.os.Build.VERSION.SDK_INT >= 21) card.setElevation(Ui.dp(act, 16));

        android.widget.TextView title = Ui.text(act, "Choose a computer", 24, Ui.TEXT, Ui.MEDIUM);
        title.setPadding(Ui.dp(act, 6), 0, 0, Ui.dp(act, 18));
        card.addView(title);

        android.view.View first = null;
        final int perRow = 3;
        android.widget.LinearLayout line = null;
        for (int i = 0; i < a.length(); i++) {
            org.json.JSONObject c = a.optJSONObject(i);
            if (c == null) continue;
            final String h = c.optString("host");
            boolean on = c.optBoolean("online"), current = h.equals(act.host());
            if (line == null || line.getChildCount() == perRow) {
                line = new android.widget.LinearLayout(act);
                line.setOrientation(android.widget.LinearLayout.HORIZONTAL);
                card.addView(line);
            }
            android.view.View tile = tile(h, on, current);
            tile.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { act.switchTo(h); } });
            android.widget.LinearLayout.LayoutParams tp = new android.widget.LinearLayout.LayoutParams(Ui.dp(act, 196), Ui.dp(act, 132));
            tp.setMargins(Ui.dp(act, 6), Ui.dp(act, 6), Ui.dp(act, 6), Ui.dp(act, 6));
            line.addView(tile, tp);
            if (first == null || current) first = tile;
        }
        if (a.length() == 0) {
            android.widget.TextView none = Ui.text(act, "No computers found yet.", 17, Ui.MUTED, Ui.REGULAR);
            none.setPadding(Ui.dp(act, 6), Ui.dp(act, 6), 0, Ui.dp(act, 6));
            card.addView(none);
        }
        android.widget.TextView how = Ui.text(act,
            "Every desktop on your Tailscale shows up here: another Claude session (“desktop on, call it Work”), "
            + "or ChatGPT's and Muse's computers.", 14, Ui.MUTED, Ui.REGULAR);
        how.setLineSpacing(0, 1.25f);
        how.setPadding(Ui.dp(act, 8), Ui.dp(act, 14), Ui.dp(act, 8), 0);
        card.addView(how, new android.widget.LinearLayout.LayoutParams(Ui.dp(act, 3 * 208), android.widget.LinearLayout.LayoutParams.WRAP_CONTENT));

        android.widget.FrameLayout.LayoutParams cl = new android.widget.FrameLayout.LayoutParams(
            android.widget.FrameLayout.LayoutParams.WRAP_CONTENT, android.widget.FrameLayout.LayoutParams.WRAP_CONTENT, android.view.Gravity.CENTER);
        scrim.addView(card, cl);
        root.addView(scrim, new android.widget.FrameLayout.LayoutParams(
            android.widget.FrameLayout.LayoutParams.MATCH_PARENT, android.widget.FrameLayout.LayoutParams.MATCH_PARENT));
        picker = scrim;
        scrim.setAlpha(0f); scrim.animate().alpha(1f).setDuration(180).start();
        card.setScaleX(0.97f); card.setScaleY(0.97f); card.animate().scaleX(1f).scaleY(1f).setDuration(180).start();
        if (first != null) first.requestFocus();
    }

    /** Each desktop's own colors, from its wallpaper: Claude's coral on dark, ChatGPT's white on black, Muse's
     *  lavender with dark text; others plain. {background, text}. */
    static int[] colors(String h) {
        if ("ccrd".equals(h)) return new int[] { 0xFF262626, 0xFFF2F2F2, 0xFFD97757 };
        if ("ccrd-codex".equals(h)) return new int[] { 0xFF0B0C0C, 0xFFFFFFFF, 0xFFFFFFFF };
        if ("ccrd-muse".equals(h)) return new int[] { 0xFFCDD0FD, 0xFF14141F, 0xFF14141F };
        return new int[] { 0xFF303030, 0xFFF2F2F2, 0xFFD97757 };
    }

    /** One computer as a tile: its name big, whether it's on or asleep, and a check if it's the one on screen. */
    private android.view.View tile(String h, boolean on, boolean current) {
        final int[] col = colors(h);
        final android.widget.LinearLayout t = new android.widget.LinearLayout(act);
        t.setOrientation(android.widget.LinearLayout.VERTICAL);
        t.setGravity(android.view.Gravity.BOTTOM);
        t.setPadding(Ui.dp(act, 16), Ui.dp(act, 12), Ui.dp(act, 16), Ui.dp(act, 14));
        t.setFocusable(true); t.setClickable(true);
        final android.graphics.drawable.Drawable idle = Ui.round(act, col[0], 16, current ? col[2] : Ui.EDGE);
        final android.graphics.drawable.Drawable lit = Ui.round(act, col[0], 16, 0xFFFFFFFF);
        t.setBackground(idle);
        if (!on) t.setAlpha(0.6f);
        t.setOnFocusChangeListener(new View.OnFocusChangeListener() { public void onFocusChange(View v, boolean f) {
            v.setBackground(f ? lit : idle);
            v.animate().scaleX(f ? 1.05f : 1f).scaleY(f ? 1.05f : 1f).setDuration(120).start();
        } });

        android.widget.TextView top = Ui.text(act, current ? "\u2713 On screen" : "", 13, col[2], Ui.MEDIUM);
        t.addView(top, new android.widget.LinearLayout.LayoutParams(android.widget.LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));

        android.widget.TextView n = Ui.text(act, label(h), 24, col[1], Ui.MEDIUM);
        n.setSingleLine(true); n.setEllipsize(android.text.TextUtils.TruncateAt.END);
        t.addView(n);

        android.widget.TextView st = Ui.text(act, on ? "On" : "Asleep", 14, col[1], Ui.REGULAR);
        st.setAlpha(0.75f);
        st.setCompoundDrawablesWithIntrinsicBounds(Ui.dot(act, on ? Ui.ON : 0xFF6B6B6B, 7), null, null, null);
        st.setCompoundDrawablePadding(Ui.dp(act, 7));
        st.setGravity(android.view.Gravity.CENTER_VERTICAL);
        t.addView(st);
        return t;
    }

    void hide() {
        if (picker == null) return;
        root.removeView(picker);
        picker = null;
        act.focusDesktop();
    }
}
