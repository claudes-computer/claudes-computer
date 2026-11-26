package dev.ccrd.tv;

import android.os.Handler;
import android.view.View;

import ccrdnet.Ccrdnet;

/** More than one computer: every Claude session is its own computer (ccrdnet computers.go). This is the
 *  "Which computer?" list over the desktop or the status screen, and the count of computers this TV can see. */
class ComputerPicker {
    private final MainActivity act;
    private final android.widget.FrameLayout root;
    private final Handler handler;
    private android.view.View picker;
    private int computers = 1;              // counted when the list opens and while the TV waits on the asleep screen

    ComputerPicker(MainActivity a, android.widget.FrameLayout r, Handler h) { act = a; root = r; handler = h; }

    boolean showing() { return picker != null; }
    int count() { return computers; }

    /** "ccrd" is the first computer; "ccrd-work" is "Work". */
    static String label(String h) {
        if ("ccrd".equals(h)) return "Your computer";
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
        for (int i = 0; i < a.length(); i++) {
            org.json.JSONObject c = a.optJSONObject(i);
            if (c == null) continue;
            final String h = c.optString("host");
            boolean on = c.optBoolean("online"), current = h.equals(act.host());
            android.view.View row = row(label(h), on, current);
            row.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { act.switchTo(h); } });
            android.widget.LinearLayout.LayoutParams rp = new android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.MATCH_PARENT, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT);
            rp.setMargins(0, 0, 0, Ui.dp(act, 6));
            card.addView(row, rp);
            if (first == null || current) first = row;
        }
        if (a.length() == 0) {
            android.widget.TextView none = Ui.text(act, "No computers found yet.", 17, Ui.MUTED, Ui.REGULAR);
            none.setPadding(Ui.dp(act, 6), Ui.dp(act, 6), 0, Ui.dp(act, 6));
            card.addView(none);
        }
        android.widget.TextView how = Ui.text(act,
            "To add one, start another Claude session and say \u201cdesktop on, call it Work\u201d.", 14, Ui.MUTED, Ui.REGULAR);
        how.setLineSpacing(0, 1.25f);
        how.setPadding(Ui.dp(act, 6), Ui.dp(act, 14), Ui.dp(act, 6), 0);
        card.addView(how);

        android.widget.FrameLayout.LayoutParams cl = new android.widget.FrameLayout.LayoutParams(
            Ui.dp(act, 520), android.widget.FrameLayout.LayoutParams.WRAP_CONTENT, android.view.Gravity.CENTER);
        scrim.addView(card, cl);
        root.addView(scrim, new android.widget.FrameLayout.LayoutParams(
            android.widget.FrameLayout.LayoutParams.MATCH_PARENT, android.widget.FrameLayout.LayoutParams.MATCH_PARENT));
        picker = scrim;
        scrim.setAlpha(0f); scrim.animate().alpha(1f).setDuration(180).start();
        card.setScaleX(0.97f); card.setScaleY(0.97f); card.animate().scaleX(1f).scaleY(1f).setDuration(180).start();
        if (first != null) first.requestFocus();
    }

    /** One computer: its name, a check if it's the one on screen, and whether it's on or asleep. */
    private android.view.View row(String name, boolean on, boolean current) {
        final android.widget.LinearLayout r = new android.widget.LinearLayout(act);
        r.setOrientation(android.widget.LinearLayout.HORIZONTAL);
        r.setGravity(android.view.Gravity.CENTER_VERTICAL);
        r.setPadding(Ui.dp(act, 16), Ui.dp(act, 14), Ui.dp(act, 16), Ui.dp(act, 14));
        r.setFocusable(true); r.setClickable(true);
        final android.graphics.drawable.Drawable idle = Ui.round(act, 0x00000000, 14, 0);
        final android.graphics.drawable.Drawable lit = Ui.round(act, Ui.white(26), 14, 0x99D97757);
        r.setBackground(idle);
        r.setOnFocusChangeListener(new View.OnFocusChangeListener() { public void onFocusChange(View v, boolean f) {
            v.setBackground(f ? lit : idle);
        } });

        android.widget.TextView check = Ui.text(act, current ? "\u2713" : "", 18, Ui.CORAL, Ui.MEDIUM);
        check.setGravity(android.view.Gravity.CENTER);
        r.addView(check, new android.widget.LinearLayout.LayoutParams(Ui.dp(act, 26), android.widget.LinearLayout.LayoutParams.WRAP_CONTENT));

        android.widget.TextView n = Ui.text(act, name, 19, Ui.TEXT, current ? Ui.MEDIUM : Ui.REGULAR);
        r.addView(n, new android.widget.LinearLayout.LayoutParams(0, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

        android.widget.TextView st = Ui.text(act, on ? "On" : "Asleep", 14, Ui.MUTED, Ui.REGULAR);
        st.setCompoundDrawablesWithIntrinsicBounds(Ui.dot(act, on ? Ui.ON : 0xFF6B6B6B, 7), null, null, null);
        st.setCompoundDrawablePadding(Ui.dp(act, 7));
        st.setGravity(android.view.Gravity.CENTER_VERTICAL);
        r.addView(st);
        return r;
    }

    void hide() {
        if (picker == null) return;
        root.removeView(picker);
        picker = null;
        act.focusDesktop();
    }
}
