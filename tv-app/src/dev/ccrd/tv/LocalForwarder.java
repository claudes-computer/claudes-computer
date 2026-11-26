package dev.ccrd.tv;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;

/**
 * Listens on the TV's own localhost and passes every connection to the desktop over the tailnet.
 * The stream's video decoder only runs on a "secure" origin (HTTPS or localhost); this makes the
 * tailnet address look like localhost, so no certificates are needed.
 */
public class LocalForwarder implements Runnable {
    private final int localPort;
    private final String host;
    private final int port;

    public LocalForwarder(int localPort, String host, int port) {
        this.localPort = localPort; this.host = host; this.port = port;
    }

    public void start() { Thread t = new Thread(this, "ccrd-forwarder"); t.setDaemon(true); t.start(); }

    @Override
    public void run() {
        try {
            ServerSocket server = new ServerSocket(localPort, 50, InetAddress.getByName("127.0.0.1"));
            while (true) {
                Socket in = server.accept();
                // The computer chosen in the picker, if there is one (several computers: ccrd, ccrd-work, ...).
                String h = host;
                try { String d = ccrdnet.Ccrdnet.desktop(); if (d != null && !d.isEmpty()) h = d; } catch (Throwable e) { }
                Thread t = new Thread(new Conn(in, h, port), "ccrd-conn"); t.setDaemon(true); t.start();
            }
        } catch (Exception e) { /* port already bound by an earlier instance: that one keeps serving */ }
    }

    static class Conn implements Runnable {
        private final Socket in; private final String host; private final int port;
        Conn(Socket in, String host, int port) { this.in = in; this.host = host; this.port = port; }
        @Override
        public void run() {
            Socket out = new Socket();
            try {
                out.connect(new InetSocketAddress(host, port), 4000);
                in.setTcpNoDelay(true); out.setTcpNoDelay(true);
                Thread t = new Thread(new Pipe(out.getInputStream(), in.getOutputStream(), in, out), "ccrd-down");
                t.setDaemon(true); t.start();
                new Pipe(in.getInputStream(), out.getOutputStream(), in, out).run();
            } catch (Exception e) {
                try { in.close(); } catch (Exception x) { }
                try { out.close(); } catch (Exception x) { }
            }
        }
    }

    static class Pipe implements Runnable {
        private final InputStream from; private final OutputStream to; private final Socket a; private final Socket b;
        Pipe(InputStream from, OutputStream to, Socket a, Socket b) { this.from = from; this.to = to; this.a = a; this.b = b; }
        @Override
        public void run() {
            byte[] buf = new byte[65536];
            try {
                int n;
                while ((n = from.read(buf)) > 0) { to.write(buf, 0, n); to.flush(); }
            } catch (Exception e) { }
            try { a.close(); } catch (Exception x) { }
            try { b.close(); } catch (Exception x) { }
        }
    }
}
