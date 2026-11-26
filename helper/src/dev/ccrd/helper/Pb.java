package dev.ccrd.helper;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

/** Just enough protocol buffers for the TV's remote protocol: write varints, strings, bytes and nested messages;
 *  read a message's top-level fields. Messages on the wire are prefixed with their length as a varint. */
final class Pb {
    private final ByteArrayOutputStream b = new ByteArrayOutputStream();

    Pb num(int field, long v) { tag(field, 0); varint(b, v); return this; }
    Pb str(int field, String s) { try { return raw(field, s.getBytes("UTF-8")); } catch (Exception e) { throw new RuntimeException(e); } }
    Pb raw(int field, byte[] v) { tag(field, 2); varint(b, v.length); b.write(v, 0, v.length); return this; }
    Pb msg(int field, Pb m) { return raw(field, m.bytes()); }
    byte[] bytes() { return b.toByteArray(); }

    private void tag(int field, int type) { varint(b, ((long) field << 3) | type); }

    static void varint(OutputStream o, long v) {
        try {
            while ((v & ~0x7FL) != 0) { o.write((int) ((v & 0x7F) | 0x80)); v >>>= 7; }
            o.write((int) v);
        } catch (IOException e) { throw new RuntimeException(e); }
    }

    static void send(OutputStream o, Pb m) throws IOException {
        byte[] x = m.bytes();
        ByteArrayOutputStream f = new ByteArrayOutputStream();
        varint(f, x.length); f.write(x, 0, x.length);
        o.write(f.toByteArray()); o.flush();
    }

    static long readVarint(InputStream in) throws IOException {
        long v = 0; int shift = 0;
        while (true) {
            int c = in.read();
            if (c < 0) throw new IOException("connection closed");
            v |= (long) (c & 0x7F) << shift;
            if ((c & 0x80) == 0) return v;
            shift += 7;
            if (shift > 63) throw new IOException("bad varint");
        }
    }

    static byte[] receive(InputStream in) throws IOException {
        int n = (int) readVarint(in);
        if (n < 0 || n > 1 << 20) throw new IOException("bad length");
        byte[] x = new byte[n]; int r = 0;
        while (r < n) { int k = in.read(x, r, n - r); if (k < 0) throw new IOException("connection closed"); r += k; }
        return x;
    }

    /** One top-level field of a message: its number, and either a number (varint) or bytes (strings, messages). */
    static final class Field { int num; long val; byte[] data; }

    static List<Field> parse(byte[] x) {
        List<Field> out = new ArrayList<>();
        int[] p = { 0 };
        while (p[0] < x.length) {
            long key = varAt(x, p);
            Field f = new Field(); f.num = (int) (key >>> 3);
            int type = (int) (key & 7);
            if (type == 0) f.val = varAt(x, p);
            else if (type == 2) { int n = (int) varAt(x, p); f.data = java.util.Arrays.copyOfRange(x, p[0], p[0] + n); p[0] += n; }
            else if (type == 5) p[0] += 4;
            else if (type == 1) p[0] += 8;
            else break;
            out.add(f);
        }
        return out;
    }

    static Field get(List<Field> fs, int num) { for (Field f : fs) if (f.num == num) return f; return null; }

    private static long varAt(byte[] x, int[] p) {
        long v = 0; int shift = 0;
        while (p[0] < x.length) {
            int c = x[p[0]++] & 0xFF;
            v |= (long) (c & 0x7F) << shift;
            if ((c & 0x80) == 0) break;
            shift += 7;
        }
        return v;
    }
}
