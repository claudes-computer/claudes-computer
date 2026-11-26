package dev.ccrd.helper;

import android.content.Context;

import java.io.ByteArrayOutputStream;
import java.math.BigInteger;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.PKCS8EncodedKeySpec;

/** The helper's identity toward the TV: an RSA key and a self-signed certificate made the same way as the one
 *  Home Assistant's remote library uses (CN=atvremote, CA:true, a DNS name), which this TV's remote service accepts.
 *  Android's own keystore makes certificates without those fields, and the TV's key port turns them away.
 *  Both files stay in this app's private storage. */
final class Identity {
    final PrivateKey key;
    final X509Certificate cert;

    private Identity(PrivateKey k, X509Certificate c) { key = k; cert = c; }

    static synchronized Identity get(Context c) throws Exception {
        java.io.File kf = new java.io.File(c.getFilesDir(), "remote3.key"), cf = new java.io.File(c.getFilesDir(), "remote3.crt");
        if (!kf.exists() || !cf.exists()) {
            KeyPairGenerator g = KeyPairGenerator.getInstance("RSA");
            g.initialize(2048);
            KeyPair kp = g.generateKeyPair();
            write(kf, kp.getPrivate().getEncoded());
            write(cf, makeCert(kp));
        }
        PrivateKey k = KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(read(kf)));
        X509Certificate x = (X509Certificate) CertificateFactory.getInstance("X.509")
            .generateCertificate(new java.io.ByteArrayInputStream(read(cf)));
        return new Identity(k, x);
    }

    // ---- a minimal X.509 certificate in DER ----

    static byte[] makeCert(KeyPair kp) throws Exception {
        // A name of its own: the TV finds paired remotes by name, so two remotes called the same get mixed up.
        String cn = "ccrd-helper-" + Long.toHexString(new java.security.SecureRandom().nextLong() & 0xFFFFFFFFFFL);
        byte[] name = seq(set(seq(oid("2.5.4.3"), tlv(0x0C, cn.getBytes("UTF-8")))));
        long now = System.currentTimeMillis();
        byte[] alg = seq(oid("1.2.840.113549.1.1.11"), new byte[] { 0x05, 0x00 });          // sha256WithRSAEncryption
        byte[] ext = seq(
            seq(oid("2.5.29.19"), tlv(0x04, seq(new byte[] { 0x01, 0x01, (byte) 0xFF }, integer(BigInteger.ZERO)))), // CA:true, pathlen 0
            seq(oid("2.5.29.17"), tlv(0x04, seq(tlv(0x82, "atvremote".getBytes("UTF-8"))))));                         // DNS:atvremote
        byte[] tbs = seq(
            tlv(0xA0, integer(BigInteger.valueOf(2))),                                        // version 3
            integer(BigInteger.valueOf(System.currentTimeMillis())),
            alg, name,
            seq(time(now - 86400000L), time(now + 10L * 365 * 86400000L)),
            name,
            kp.getPublic().getEncoded(),                                                       // SubjectPublicKeyInfo
            tlv(0xA3, ext));
        Signature s = Signature.getInstance("SHA256withRSA");
        s.initSign(kp.getPrivate()); s.update(tbs);
        byte[] sig = s.sign();
        byte[] bits = new byte[sig.length + 1]; System.arraycopy(sig, 0, bits, 1, sig.length);
        return seq(tbs, alg, tlv(0x03, bits));
    }

    private static byte[] time(long ms) throws Exception {
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("yyMMddHHmmss'Z'", java.util.Locale.US);
        f.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
        return tlv(0x17, f.format(new java.util.Date(ms)).getBytes("US-ASCII"));               // UTCTime (until 2049)
    }

    private static byte[] integer(BigInteger v) { return tlv(0x02, v.toByteArray()); }

    private static byte[] oid(String dotted) {
        String[] p = dotted.split("\\.");
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        o.write(Integer.parseInt(p[0]) * 40 + Integer.parseInt(p[1]));
        for (int i = 2; i < p.length; i++) {
            long v = Long.parseLong(p[i]);
            byte[] tmp = new byte[10]; int n = 0;
            do { tmp[n++] = (byte) (v & 0x7F); v >>= 7; } while (v > 0);
            for (int j = n - 1; j >= 0; j--) o.write(tmp[j] | (j > 0 ? 0x80 : 0));
        }
        return tlv(0x06, o.toByteArray());
    }

    private static byte[] seq(byte[]... parts) { return tlv(0x30, cat(parts)); }
    private static byte[] set(byte[]... parts) { return tlv(0x31, cat(parts)); }

    private static byte[] cat(byte[]... parts) {
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        for (byte[] p : parts) o.write(p, 0, p.length);
        return o.toByteArray();
    }

    private static byte[] tlv(int tag, byte[] v) {
        ByteArrayOutputStream o = new ByteArrayOutputStream();
        o.write(tag);
        int n = v.length;
        if (n < 128) o.write(n);
        else if (n < 256) { o.write(0x81); o.write(n); }
        else if (n < 65536) { o.write(0x82); o.write(n >> 8); o.write(n & 0xFF); }
        else { o.write(0x83); o.write(n >> 16); o.write((n >> 8) & 0xFF); o.write(n & 0xFF); }
        o.write(v, 0, v.length);
        return o.toByteArray();
    }

    private static void write(java.io.File f, byte[] b) throws Exception {
        java.io.FileOutputStream o = new java.io.FileOutputStream(f);
        try { o.write(b); } finally { o.close(); }
    }

    private static byte[] read(java.io.File f) throws Exception {
        byte[] b = new byte[(int) f.length()];
        java.io.FileInputStream in = new java.io.FileInputStream(f);
        try { int n = 0; while (n < b.length) { int r = in.read(b, n, b.length - n); if (r < 0) break; n += r; } } finally { in.close(); }
        return b;
    }
}
