package dev.ccrd.tv;

import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class DesktopClient extends WebViewClient {
    private final MainActivity act;
    public DesktopClient(MainActivity a) { act = a; }
    // The desktop serves Selkies' sidebar (phones and tablets need its on-screen keyboard button). On the TV,
    // with a real keyboard and mouse, hide it so the screen is only the desktop.
    static final String HIDE_SIDEBAR = "(function(){if(document.getElementById('ccrd-tv-css'))return;"
        + "var s=document.createElement('style');s.id='ccrd-tv-css';"
        + "s.textContent='.toggle-handle,aside.sidebar{display:none!important}';"
        + "(document.head||document.documentElement).appendChild(s);})()";
    // The desktop page keeps a hidden text box focused to catch typing; Android TV then slides its own on-screen
    // keyboard over the desktop on every key. Mark every text box "no on-screen keyboard" (the real keyboard still
    // types: its keys reach the page directly), including ones the page adds later.
    static final String NO_TV_KEYBOARD = "(function(){if(window.__ccrdNoIme)return;window.__ccrdNoIme=1;"
        + "var q='input,textarea,[contenteditable]';"
        + "function f(r){if(r.matches&&r.matches(q))r.setAttribute('inputmode','none');"
        + "if(r.querySelectorAll)r.querySelectorAll(q).forEach(function(e){e.setAttribute('inputmode','none');});}"
        + "f(document);new MutationObserver(function(m){m.forEach(function(x){x.addedNodes.forEach(function(n){"
        + "if(n.nodeType===1)f(n);});});}).observe(document.documentElement,{childList:true,subtree:true});})()";
    private static void prepare(WebView v) { v.evaluateJavascript(HIDE_SIDEBAR, null); v.evaluateJavascript(NO_TV_KEYBOARD, null); }

    @Override
    public void onPageCommitVisible(WebView v, String url) {
        if (url != null && url.startsWith("http")) prepare(v);
    }
    @Override
    public void onPageFinished(WebView v, String url) {
        if (url != null && url.startsWith("file:///android_asset/status.html")) act.statusPageReady();
        else if (url != null && url.startsWith("http")) prepare(v);
    }
    @Override
    public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
        if (r.isForMainFrame()) act.lost();
    }
}
