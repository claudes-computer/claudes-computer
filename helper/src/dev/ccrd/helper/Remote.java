package dev.ccrd.helper;

import java.io.InputStream;
import java.io.OutputStream;
import java.math.BigInteger;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.security.interfaces.RSAPublicKey;
import java.util.List;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/** The TV's own remote-control service, the one a phone's Google TV app uses (ports 6467: pairing, 6466: keys).
 *  Our identity is a key pair kept in Android's keystore; the TV trusts it after a one-time pairing, where it shows
 *  a 6-character code that has to be entered here. Protocol as in Home Assistant's androidtvremote2. */
final class Remote {
    private static final String ALIAS = "ccrd-helper";
    static final int PAIR_PORT = 6467, KEY_PORT = 6466;
    // Features we ask for: ping, keys, power, app links.
    private static final int FEATURES = 1 | 2 | 32 | 512;

    private final String host;
    private final android.content.Context ctx;
    Remote(android.content.Context c, String host) { ctx = c; this.host = host; }

    private SSLSocket connect(int port) throws Exception {
        // Always present our own certificate: Android's default picker skips it when the TV's list of expected
        // issuers doesn't match byte for byte, and the TV then drops the connection.
        Identity id = Identity.get(ctx);
        final java.security.PrivateKey key = id.key;
        final X509Certificate cert = id.cert;
        javax.net.ssl.KeyManager[] mine = { new javax.net.ssl.X509KeyManager() {
            public String chooseClientAlias(String[] t, java.security.Principal[] i, java.net.Socket s) { return ALIAS; }
            public String chooseServerAlias(String t, java.security.Principal[] i, java.net.Socket s) { return null; }
            public X509Certificate[] getCertificateChain(String a) { return new X509Certificate[] { cert }; }
            public String[] getClientAliases(String t, java.security.Principal[] i) { return new String[] { ALIAS }; }
            public String[] getServerAliases(String t, java.security.Principal[] i) { return null; }
            public java.security.PrivateKey getPrivateKey(String a) { return key; }
        } };
        TrustManager[] any = { new X509TrustManager() {          // the TV's certificate is its own, self-made
            public void checkClientTrusted(X509Certificate[] c, String a) { }
            public void checkServerTrusted(X509Certificate[] c, String a) { }
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        } };
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(mine, any, null);
        SSLSocket s = (SSLSocket) ctx.getSocketFactory().createSocket();
        s.connect(new java.net.InetSocketAddress(host, port), 5000);
        s.setSoTimeout(15000);
        s.startHandshake();
        return s;
    }

    // ---- pairing (the TV shows a code; finish() takes it) ----

    private SSLSocket pairing;

    private static Pb outer() { return new Pb().num(1, 2).num(2, 200); }
    private static Pb hexEncoding() { return new Pb().num(1, 3).num(2, 6); }

    private static List<Pb.Field> expect(InputStream in, int field) throws Exception {
        List<Pb.Field> m = Pb.parse(Pb.receive(in));
        Pb.Field st = Pb.get(m, 2);
        if (st != null && st.val != 200) throw new Exception("the TV said " + st.val);
        if (Pb.get(m, field) == null) throw new Exception("unexpected answer from the TV");
        return m;
    }

    /** Closes a pairing that was started and never finished. */
    synchronized void closePairing() {
        if (pairing != null) try { pairing.close(); } catch (Exception e) { }
        pairing = null;
    }

    /** Starts pairing: the TV shows a code. Returns when it's on screen. */
    synchronized void startPairing(String name) throws Exception {
        if (pairing != null) try { pairing.close(); } catch (Exception e) { }
        pairing = connect(PAIR_PORT);
        pairing.setSoTimeout(30000);
        OutputStream o = pairing.getOutputStream(); InputStream in = pairing.getInputStream();
        Pb.send(o, outer().msg(10, new Pb().str(1, "atvremote").str(2, name)));
        expect(in, 11);
        Pb.send(o, outer().msg(20, new Pb().msg(1, hexEncoding()).num(3, 1)));
        expect(in, 20);
        Pb.send(o, outer().msg(30, new Pb().msg(1, hexEncoding()).num(2, 1)));
        expect(in, 31);
        pairing.setSoTimeout(15000);
    }

    /** Finishes pairing with the code the TV shows (6 hex characters). */
    synchronized void finishPairing(String code) throws Exception {
        if (pairing == null) throw new Exception("pairing wasn't started");
        code = code.trim().toUpperCase();
        if (!code.matches("[0-9A-F]{6}")) throw new Exception("the code is 6 characters, 0-9 and A-F");
        try {
            RSAPublicKey me = (RSAPublicKey) Identity.get(ctx).cert.getPublicKey();
            RSAPublicKey tv = (RSAPublicKey) pairing.getSession().getPeerCertificates()[0].getPublicKey();
            MessageDigest h = MessageDigest.getInstance("SHA-256");
            h.update(unsigned(me.getModulus())); h.update(unsigned(me.getPublicExponent()));
            h.update(unsigned(tv.getModulus())); h.update(unsigned(tv.getPublicExponent()));
            h.update(hex(code.substring(2)));
            byte[] secret = h.digest();
            if ((secret[0] & 0xFF) != Integer.parseInt(code.substring(0, 2), 16)) throw new Exception("that code doesn't match; check it again");
            Pb.send(pairing.getOutputStream(), outer().msg(40, new Pb().raw(1, secret)));
            expect(pairing.getInputStream(), 41);
        } finally {
            try { pairing.close(); } catch (Exception e) { }
            pairing = null;
        }
    }

    private static byte[] unsigned(BigInteger v) {
        byte[] b = v.toByteArray();
        return b.length > 1 && b[0] == 0 ? java.util.Arrays.copyOfRange(b, 1, b.length) : b;
    }

    private static byte[] hex(String s) {
        byte[] b = new byte[s.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        return b;
    }

    // ---- remote control (keys, app links) ----

    /** Opens a remote session, does the TV's handshake, runs the given actions, and closes it.
     *  Each action is "key:<android keycode number>", "link:<uri>" or "wait:<ms>". */
    synchronized void run(String... actions) throws Exception {
        SSLSocket s;
        try { s = connect(KEY_PORT); }
        catch (Exception e) { throw new Exception("connect " + host + ":" + KEY_PORT + ": " + e); }
        String step = "handshake";
        try {
            OutputStream o = s.getOutputStream(); InputStream in = s.getInputStream();
            long deadline = System.currentTimeMillis() + 10000;
            boolean started = false;
            while (!started && System.currentTimeMillis() < deadline) {
                List<Pb.Field> m = Pb.parse(Pb.receive(in));
                Pb.Field f;
                step = "after message " + (m.isEmpty() ? "?" : String.valueOf(m.get(0).num));
                if ((f = Pb.get(m, 1)) != null) {                       // remote_configure
                    Pb.Field code1 = Pb.get(Pb.parse(f.data), 1);
                    int feats = FEATURES & (code1 == null ? FEATURES : (int) code1.val);
                    Pb.send(o, new Pb().msg(1, new Pb().num(1, feats).msg(2,
                        new Pb().num(3, 1).str(4, "1").str(5, "atvremote").str(6, "1.0.0"))));
                } else if ((f = Pb.get(m, 2)) != null) {                // remote_set_active
                    Pb.send(o, new Pb().msg(2, new Pb().num(1, FEATURES)));
                } else if ((f = Pb.get(m, 8)) != null) {                // ping
                    Pb.Field v = Pb.get(Pb.parse(f.data), 1);
                    Pb.send(o, new Pb().msg(9, new Pb().num(1, v == null ? 0 : v.val)));
                } else if (Pb.get(m, 40) != null) {                     // remote_start: ready
                    started = true;
                }
            }
            if (!started) throw new Exception("the TV didn't start the remote session");
            Thread.sleep(1000);                       // the TV needs a moment to set up its virtual remote; earlier keys are lost
            for (String a : actions) {
                if (a.startsWith("key:")) Pb.send(o, new Pb().msg(10, new Pb().num(1, Integer.parseInt(a.substring(4))).num(2, 3)));
                else if (a.startsWith("link:")) Pb.send(o, new Pb().msg(90, new Pb().str(1, a.substring(5))));
                else if (a.startsWith("wait:")) Thread.sleep(Long.parseLong(a.substring(5)));
                Thread.sleep(400);
            }
            Thread.sleep(500);
        } catch (Exception e) {
            throw new Exception(step + ": " + e);
        } finally {
            try { s.close(); } catch (Exception e) { }
        }
    }
}
