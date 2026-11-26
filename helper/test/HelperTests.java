package dev.ccrd.helper;

import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.List;

/** Plain-Java checks of the helper's pure logic (run by tools/test.sh; no Android device needed). */
public class HelperTests {
    static int failed = 0;
    static void check(String what, boolean ok) { System.out.println((ok ? "ok    " : "FAIL  ") + what); if (!ok) failed++; }

    public static void main(String[] a) throws Exception { run(); System.exit(failed == 0 ? 0 : 1); }

    public static void run() throws Exception {
        // Pb: what we write, we read back.
        byte[] m = new Pb().num(1, 639).str(2, "atvremote").msg(10, new Pb().num(1, 23).num(2, 3)).bytes();
        List<Pb.Field> f = Pb.parse(m);
        check("Pb round trip: number", Pb.get(f, 1).val == 639);
        check("Pb round trip: string", new String(Pb.get(f, 2).data, "UTF-8").equals("atvremote"));
        check("Pb round trip: nested key press", Pb.get(Pb.parse(Pb.get(f, 10).data), 1).val == 23);
        java.io.ByteArrayOutputStream o = new java.io.ByteArrayOutputStream();
        Pb.send(o, new Pb().num(1, 300));
        check("Pb framing: length prefix", Pb.parse(Pb.receive(new java.io.ByteArrayInputStream(o.toByteArray()))).get(0).val == 300);

        // Identity: a certificate Java accepts, signed by its own key, a CA with a DNS name (what the TV wants).
        KeyPairGenerator g = KeyPairGenerator.getInstance("RSA"); g.initialize(2048);
        KeyPair kp = g.generateKeyPair();
        X509Certificate x = (X509Certificate) CertificateFactory.getInstance("X.509")
            .generateCertificate(new java.io.ByteArrayInputStream(Identity.makeCert(kp)));
        boolean verified = true; try { x.verify(kp.getPublic()); x.checkValidity(); } catch (Exception e) { verified = false; }
        check("certificate: parses, valid now, self-signed", verified);
        check("certificate: is a CA", x.getBasicConstraints() >= 0);
        check("certificate: has a DNS name", x.getSubjectAlternativeNames() != null);

        // Packets: helper -> TV gets the stranger's address, the answer comes back, checksums stay correct.
        byte[] tv = { (byte) 192, (byte) 168, 1, 50 };
        byte[] p = new byte[40]; p[0] = 0x45; p[3] = 40; p[8] = 64; p[9] = 6;
        System.arraycopy(Packets.ME, 0, p, 12, 4); System.arraycopy(Packets.TV_ALIAS, 0, p, 16, 4);
        p[20] = 0x12; p[21] = 0x34; p[22] = 0x19; p[23] = 0x42; p[32] = 0x50;
        check("packet: helper -> TV is rewritten", Packets.rewrite(p, 40, tv));
        check("packet: now from the stranger to the TV", p[12] == 10 && p[15] == 3 && p[16] == (byte) 192 && p[19] == 50);
        check("packet: IP checksum verifies", Packets.fold(Packets.sum(p, 0, 20, 0)) == 0);
        check("packet: TCP checksum verifies", Packets.fold(Packets.sum(p, 20, 20, Packets.sum(p, 12, 8, 0) + 6 + 20)) == 0);
        byte[] r = p.clone(); System.arraycopy(tv, 0, r, 12, 4); System.arraycopy(Packets.STRANGER, 0, r, 16, 4);
        check("packet: TV's answer is rewritten", Packets.rewrite(r, 40, tv));
        check("packet: answer arrives from 10.111.0.1 at the helper", r[15] == 1 && r[19] == 2 && r[16] == 10);
        byte[] other = p.clone(); other[16] = 8; other[17] = 8; other[18] = 8; other[19] = 8;
        check("packet: unrelated traffic is left alone", !Packets.rewrite(other, 40, tv));
    }
}
