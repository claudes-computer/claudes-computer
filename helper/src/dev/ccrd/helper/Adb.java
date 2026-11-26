package dev.ccrd.helper;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** A terminal on the TV for Claude: the TV's own wireless debugging, reached from the TV itself (unlike the remote
 *  service, adb accepts that). The helper carries Google's adb built for Android (lib/<abi>/libadb.so, from the LADB
 *  project; see THIRD_PARTY_NOTICES) and runs it like any program. One-time pairing: the person opens Developer
 *  options -> Wireless debugging -> "Pair device with pairing code" and reads the code to Claude. After that the TV's
 *  debugging port is found by its network announcement (_adb-tls-connect._tcp), as long as wireless debugging is on. */
final class Adb {
    private final Context ctx;
    Adb(Context c) { ctx = c; }

    /** Runs adb with the given arguments; returns what it printed. */
    String run(String input, int timeoutSec, String... args) throws Exception {
        List<String> cmd = new ArrayList<>();
        cmd.add(ctx.getApplicationInfo().nativeLibraryDir + "/libadb.so");
        for (String a : args) cmd.add(a);
        ProcessBuilder pb = new ProcessBuilder(cmd).redirectErrorStream(true);
        pb.environment().put("HOME", ctx.getFilesDir().getPath());
        pb.environment().put("TMPDIR", ctx.getCacheDir().getPath());
        final Process p = pb.start();
        if (input != null) { p.getOutputStream().write((input + "\n").getBytes("UTF-8")); p.getOutputStream().flush(); }
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        Thread reader = new Thread(new Runnable() { public void run() {
            try { InputStream in = p.getInputStream(); byte[] b = new byte[8192]; int n;
                  while ((n = in.read(b)) > 0) synchronized (out) { if (out.size() < 1 << 20) out.write(b, 0, n); } }
            catch (Exception e) { }
        } });
        reader.start();
        if (!p.waitFor(timeoutSec, TimeUnit.SECONDS)) { p.destroyForcibly(); reader.join(1000); return out.toString("UTF-8") + "\n(timed out)"; }
        reader.join(2000);
        synchronized (out) { return out.toString("UTF-8"); }
    }

    /** Pairs with the TV's wireless debugging. code: the 6 digits on the pairing screen; port: shown there too, or
     *  found by its announcement when left empty. */
    String pair(String code, String port) throws Exception {
        if (port == null || port.isEmpty()) port = find("_adb-tls-pairing._tcp");
        if (port == null) return "couldn't find the pairing screen: open Developer options > Wireless debugging > Pair device with pairing code";
        return run(code, 20, "pair", "127.0.0.1:" + port).trim();
    }

    /** Runs a shell command on the TV through adb and returns its output. */
    String shell(String command, int timeoutSec) throws Exception {
        String target = connect();
        return run(null, timeoutSec, "-s", target, "shell", command);
    }

    /** Connects to the TV's wireless debugging; returns the device's adb name. */
    String connect() throws Exception {
        String port = find("_adb-tls-connect._tcp");
        if (port != null) {
            String target = "127.0.0.1:" + port;
            String r = run(null, 30, "connect", target);
            if (r.contains("connected")) return target;
        }
        // The TV doesn't always announce it (after a restart it sometimes doesn't): look for the port ourselves.
        // Wireless debugging listens on a random port from 30000 up; only it answers adb's handshake.
        for (int p : openPorts(30000, 50000)) {
            String target = "127.0.0.1:" + p;
            String r = run(null, 8, "connect", target);
            if (r.contains("connected") && run(null, 10, "-s", target, "shell", "echo ok").trim().equals("ok")) return target;
            run(null, 5, "disconnect", target);
        }
        throw new Exception("wireless debugging isn't on (Developer options > Wireless debugging)");
    }

    /** The TCP ports open on this TV between from and to (connections to the TV itself fail fast when closed). */
    private static java.util.List<Integer> openPorts(int from, int to) throws Exception {
        final java.util.List<Integer> open = java.util.Collections.synchronizedList(new ArrayList<Integer>());
        java.util.concurrent.ExecutorService ex = java.util.concurrent.Executors.newFixedThreadPool(64);
        for (int p = from; p < to; p++) {
            final int port = p;
            ex.execute(new Runnable() { public void run() {
                java.net.Socket s = new java.net.Socket();
                try { s.connect(new java.net.InetSocketAddress("127.0.0.1", port), 200); open.add(port); }
                catch (Exception e) { }
                finally { try { s.close(); } catch (Exception e) { } }
            } });
        }
        ex.shutdown(); ex.awaitTermination(30, TimeUnit.SECONDS);
        java.util.Collections.sort(open);
        return open;
    }

    /** The port of a service this TV announces on the network (this TV's own addresses only). */
    private String find(String type) throws Exception {
        final NsdManager nsd = (NsdManager) ctx.getSystemService(Context.NSD_SERVICE);
        final List<NsdServiceInfo> found = new ArrayList<>();
        NsdManager.DiscoveryListener l = new NsdManager.DiscoveryListener() {
            public void onStartDiscoveryFailed(String t, int e) { }
            public void onStopDiscoveryFailed(String t, int e) { }
            public void onDiscoveryStarted(String t) { }
            public void onDiscoveryStopped(String t) { }
            public void onServiceFound(NsdServiceInfo s) { synchronized (found) { found.add(s); } }
            public void onServiceLost(NsdServiceInfo s) { }
        };
        nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, l);
        Thread.sleep(3000);
        try { nsd.stopServiceDiscovery(l); } catch (Exception e) { }
        java.util.Set<String> mine = TvAddress.all();
        List<NsdServiceInfo> list; synchronized (found) { list = new ArrayList<>(found); }
        for (NsdServiceInfo s : list) {                                   // resolve one at a time (Android's rule)
            final NsdServiceInfo[] got = new NsdServiceInfo[1];
            final CountDownLatch done = new CountDownLatch(1);
            nsd.resolveService(s, new NsdManager.ResolveListener() {
                public void onResolveFailed(NsdServiceInfo i, int e) { done.countDown(); }
                public void onServiceResolved(NsdServiceInfo i) { got[0] = i; done.countDown(); }
            });
            done.await(4, TimeUnit.SECONDS);
            if (got[0] != null && got[0].getHost() != null && mine.contains(got[0].getHost().getHostAddress()))
                return String.valueOf(got[0].getPort());
        }
        return null;
    }
}
