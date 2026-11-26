package dev.ccrd.helper;

import android.content.Context;

/** Where this TV's remote-control service listens: its own address on the home network (the service may not
 *  answer on 127.0.0.1). */
final class TvAddress {
    static String find(Context c) {
        try {
            for (java.net.NetworkInterface n : java.util.Collections.list(java.net.NetworkInterface.getNetworkInterfaces())) {
                if (!n.isUp() || n.isLoopback() || n.getName().startsWith("tun")) continue;
                for (java.net.InetAddress a : java.util.Collections.list(n.getInetAddresses()))
                    if (a instanceof java.net.Inet4Address && a.isSiteLocalAddress()) return a.getHostAddress();
            }
        } catch (Exception e) { }
        return "127.0.0.1";
    }

    /** Every address this TV has (a TV can be on Ethernet and Wi-Fi, or have a Wi-Fi Direct interface for casting). */
    static java.util.Set<String> all() {
        java.util.Set<String> s = new java.util.HashSet<>();
        try {
            for (java.net.NetworkInterface n : java.util.Collections.list(java.net.NetworkInterface.getNetworkInterfaces()))
                for (java.net.InetAddress a : java.util.Collections.list(n.getInetAddresses())) {
                    String h = a.getHostAddress(); int pct = h.indexOf('%');
                    s.add(pct < 0 ? h : h.substring(0, pct));
                }
        } catch (Exception e) { }
        return s;
    }
}
