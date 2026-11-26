package dev.ccrd.helper;

/** The address rewrite behind LoopVpn, on raw IPv4 TCP packets. The helper (10.111.0.2) talks to 10.111.0.1; on the
 *  way out that becomes 10.111.0.3 -> the TV's real address, and the TV's answers become 10.111.0.1 -> 10.111.0.2. */
final class Packets {
    static final byte[] ME = { 10, 111, 0, 2 }, TV_ALIAS = { 10, 111, 0, 1 }, STRANGER = { 10, 111, 0, 3 };

    /** Rewrites the packet in b (n bytes) in place. Returns false for a packet that isn't part of the loop. */
    static boolean rewrite(byte[] b, int n, byte[] tv) {
        if (n < 20 || (b[0] >> 4) != 4 || b[9] != 6) return false;               // IPv4 + TCP only
        if (same(b, 16, TV_ALIAS)) { put(b, 12, STRANGER); put(b, 16, tv); }                       // helper -> TV
        else if (same(b, 12, tv) && same(b, 16, STRANGER)) { put(b, 12, TV_ALIAS); put(b, 16, ME); } // TV -> helper
        else return false;
        checksums(b, n);
        return true;
    }

    private static boolean same(byte[] b, int at, byte[] a) {
        return a != null && b[at] == a[0] && b[at + 1] == a[1] && b[at + 2] == a[2] && b[at + 3] == a[3];
    }
    private static void put(byte[] b, int at, byte[] a) { System.arraycopy(a, 0, b, at, 4); }

    /** New IP header and TCP checksums after the addresses changed. */
    static void checksums(byte[] b, int n) {
        int ihl = (b[0] & 0x0F) * 4;
        int total = Math.min(n, ((b[2] & 0xFF) << 8) | (b[3] & 0xFF));
        b[10] = 0; b[11] = 0;
        int ip = fold(sum(b, 0, ihl, 0));
        b[10] = (byte) (ip >> 8); b[11] = (byte) ip;
        int tcpLen = total - ihl;
        b[ihl + 16] = 0; b[ihl + 17] = 0;
        long s = sum(b, 12, 8, 0) + 6 + tcpLen;                                   // pseudo header
        int tcp = fold(sum(b, ihl, tcpLen, s));
        b[ihl + 16] = (byte) (tcp >> 8); b[ihl + 17] = (byte) tcp;
    }

    static long sum(byte[] b, int off, int len, long s) {
        int i = off, end = off + len;
        for (; i + 1 < end; i += 2) s += ((b[i] & 0xFF) << 8) | (b[i + 1] & 0xFF);
        if (i < end) s += (b[i] & 0xFF) << 8;
        return s;
    }

    static int fold(long s) {
        while ((s >> 16) != 0) s = (s & 0xFFFF) + (s >> 16);
        return (int) (~s & 0xFFFF);
    }
}
