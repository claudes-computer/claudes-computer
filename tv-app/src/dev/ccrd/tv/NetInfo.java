package dev.ccrd.tv;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;

import java.net.InetAddress;
import java.net.InterfaceAddress;
import java.net.NetworkInterface;
import java.util.Collections;
import java.util.List;

/** Reads the TV's network interfaces through Android's API, in the text form ccrdnet.SetInterfaces expects. */
final class NetInfo {
    private NetInfo() { }

    static String describe() {
        StringBuilder sb = new StringBuilder();
        try {
            List<NetworkInterface> all = Collections.list(NetworkInterface.getNetworkInterfaces());
            for (NetworkInterface ni : all) {
                boolean broadcast = false;
                StringBuilder addrs = new StringBuilder();
                for (InterfaceAddress ia : ni.getInterfaceAddresses()) {
                    InetAddress a = ia.getAddress();
                    if (a == null) continue;
                    if (ia.getBroadcast() != null) broadcast = true;
                    String host = a.getHostAddress();
                    int pct = host.indexOf('%');
                    if (pct >= 0) host = host.substring(0, pct);
                    addrs.append(host).append('/').append(ia.getNetworkPrefixLength()).append(' ');
                }
                sb.append(ni.getName()).append(' ').append(ni.getIndex()).append(' ').append(ni.getMTU()).append(' ')
                  .append(ni.isUp()).append(' ').append(broadcast).append(' ').append(ni.isLoopback()).append(' ')
                  .append(ni.isPointToPoint()).append(' ').append(ni.supportsMulticast())
                  .append('|').append(addrs.toString().trim()).append('\n');
            }
        } catch (Exception e) {
            // An empty list makes the node report no network; it retries when called again.
        }
        return sb.toString();
    }

    /** True when the TV has a working network connection (Wi-Fi or Ethernet). */
    @SuppressWarnings("deprecation")
    static boolean online(Context ctx) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            android.net.NetworkInfo ni = cm.getActiveNetworkInfo();
            return ni != null && ni.isConnected();
        } catch (Exception e) {
            return true;  // can't tell: don't claim the TV is offline
        }
    }

    static String defaultInterface(Context ctx) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            Network n = cm.getActiveNetwork();
            LinkProperties lp = n == null ? null : cm.getLinkProperties(n);
            if (lp != null && lp.getInterfaceName() != null) return lp.getInterfaceName();
        } catch (Exception e) { }
        return "";
    }

    /** The home network the TV is on, as "a.b.c.d/len" (IPv4), or "" if unknown. Skips VPNs (such as the
     *  Tailscale app, if it is also installed) and Tailscale's own 100.64.0.0/10 addresses. */
    static String homeSubnet(Context ctx) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            for (Network n : cm.getAllNetworks()) {
                android.net.NetworkCapabilities nc = cm.getNetworkCapabilities(n);
                if (nc == null || nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) continue;
                if (!nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)
                        && !nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET)) continue;
                LinkProperties lp = cm.getLinkProperties(n);
                if (lp == null) continue;
                for (android.net.LinkAddress la : lp.getLinkAddresses()) {
                    InetAddress a = la.getAddress();
                    if (!(a instanceof java.net.Inet4Address) || a.isLoopbackAddress()) continue;
                    byte[] b = a.getAddress();
                    if ((b[0] & 0xff) == 100 && (b[1] & 0xc0) == 64) continue;   // 100.64.0.0/10
                    int len = la.getPrefixLength();
                    int ip = ((b[0] & 0xff) << 24) | ((b[1] & 0xff) << 16) | ((b[2] & 0xff) << 8) | (b[3] & 0xff);
                    int net = len == 0 ? 0 : ip & (0xffffffff << (32 - len));
                    return ((net >>> 24) & 0xff) + "." + ((net >>> 16) & 0xff) + "." + ((net >>> 8) & 0xff) + "." + (net & 0xff) + "/" + len;
                }
            }
        } catch (Exception e) { }
        return "";
    }
    /** DNS servers of the TV's Wi-Fi or Ethernet network (not a VPN), space-separated. */
    static String dnsServers(Context ctx) {
        StringBuilder sb = new StringBuilder();
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            for (Network n : cm.getAllNetworks()) {
                android.net.NetworkCapabilities nc = cm.getNetworkCapabilities(n);
                if (nc == null || nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) continue;
                LinkProperties lp = cm.getLinkProperties(n);
                if (lp == null) continue;
                for (InetAddress a : lp.getDnsServers()) {
                    String h = a.getHostAddress(); int pct = h.indexOf('%'); if (pct >= 0) h = h.substring(0, pct);
                    sb.append(h).append(' ');
                }
                if (sb.length() > 0) break;
            }
        } catch (Exception e) { }
        return sb.toString().trim();
    }
    /** Sends this app's own connections straight out over Wi-Fi/Ethernet, past any VPN on the TV (such as the
     *  Tailscale app, which would otherwise capture home-network traffic). Returns true if bound. */
    static boolean bindToHomeNetwork(Context ctx) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            for (Network n : cm.getAllNetworks()) {
                android.net.NetworkCapabilities nc = cm.getNetworkCapabilities(n);
                if (nc == null || nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) continue;
                if (nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)
                        || nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET)) {
                    return cm.bindProcessToNetwork(n);
                }
            }
        } catch (Exception e) { }
        return false;
    }
    /** True if another app's VPN is running on the TV (for example the Tailscale app). Android won't let this
     *  app step around it, so home-network traffic sent through this TV would be captured and lost. */
    static boolean otherVpnActive(Context ctx) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            for (Network n : cm.getAllNetworks()) {
                android.net.NetworkCapabilities nc = cm.getNetworkCapabilities(n);
                if (nc != null && nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) return true;
            }
        } catch (Exception e) { }
        return false;
    }
    /** The home router's IPv4 address (default gateway of the Wi-Fi/Ethernet network), or "". */
    static String gateway(Context ctx) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            for (Network n : cm.getAllNetworks()) {
                android.net.NetworkCapabilities nc = cm.getNetworkCapabilities(n);
                if (nc == null || nc.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) continue;
                LinkProperties lp = cm.getLinkProperties(n);
                if (lp == null) continue;
                for (android.net.RouteInfo r : lp.getRoutes()) {
                    InetAddress g = r.getGateway();
                    if (r.isDefaultRoute() && g instanceof java.net.Inet4Address) return g.getHostAddress();
                }
            }
        } catch (Exception e) { }
        return "";
    }
}
