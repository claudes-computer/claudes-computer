package dev.ccrd.tv;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.View;
import android.widget.TextView;

/** The app's look for things drawn over the desktop: soft dark panels, rounded corners, calm type. */
final class Ui {
    static final int PANEL = 0xF2202020;      // near-black, slightly see-through
    static final int EDGE = 0x1FFFFFFF;       // a hairline edge so panels read on dark desktops
    static final int TEXT = 0xFFF2F2F2;
    static final int MUTED = 0xFF9A9A9A;
    static final int CORAL = 0xFFD97757;      // the logo's color, used sparingly
    static final int ON = 0xFF6FCF97;
    static final Typeface MEDIUM = Typeface.create("sans-serif-medium", Typeface.NORMAL);
    static final Typeface REGULAR = Typeface.create("sans-serif", Typeface.NORMAL);

    private Ui() { }

    static int dp(Context c, float v) { return Math.round(v * c.getResources().getDisplayMetrics().density); }

    static GradientDrawable round(Context c, int color, float radiusDp, int edge) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(dp(c, radiusDp));
        if (edge != 0) g.setStroke(Math.max(1, dp(c, 1)), edge);
        return g;
    }

    static GradientDrawable dot(Context c, int color, float sizeDp) {
        GradientDrawable g = new GradientDrawable();
        g.setShape(GradientDrawable.OVAL);
        g.setColor(color);
        g.setSize(dp(c, sizeDp), dp(c, sizeDp));
        return g;
    }

    static TextView text(Context c, String s, float sp, int color, Typeface face) {
        TextView t = new TextView(c);
        t.setText(s); t.setTextSize(sp); t.setTextColor(color); t.setTypeface(face);
        t.setIncludeFontPadding(false);
        return t;
    }

    /** A small pill: a colored dot and a short line of text. Used for Claude's notice and the microphone badge. */
    static TextView pill(Context c, int dotColor) {
        TextView t = text(c, "", 15, TEXT, MEDIUM);
        t.setBackground(round(c, PANEL, 999, EDGE));
        t.setPadding(dp(c, 14), dp(c, 9), dp(c, 18), dp(c, 9));
        t.setCompoundDrawablesWithIntrinsicBounds(dot(c, dotColor, 8), null, null, null);
        t.setCompoundDrawablePadding(dp(c, 10));
        t.setGravity(android.view.Gravity.CENTER_VERTICAL);
        if (android.os.Build.VERSION.SDK_INT >= 21) t.setElevation(dp(c, 6));
        return t;
    }

    static void fadeIn(View v) {
        v.animate().cancel();
        v.setAlpha(0f); v.setTranslationY(-dp(v.getContext(), 6)); v.setVisibility(View.VISIBLE);
        v.animate().alpha(1f).translationY(0).setDuration(220).start();
    }

    static void fadeOut(final View v) {
        v.animate().cancel();
        v.animate().alpha(0f).setDuration(260).withEndAction(new Runnable() { public void run() { v.setVisibility(View.GONE); } }).start();
    }

    static int white(int alpha) { return Color.argb(alpha, 255, 255, 255); }
}
