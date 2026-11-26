// Package ccrdnet embeds a Tailscale node (tsnet) in the TV app, so the app itself joins the
// user's tailnet. No separate Tailscale app or VPN permission is needed on the TV.
package ccrdnet

import (
	"context"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/ipn"
	"tailscale.com/net/tsaddr"
	"tailscale.com/tsnet"
)

var (
	mu      sync.Mutex
	srv     *tsnet.Server
	authURL string
	state   = "Starting"
	lastErr string
	logTail []string
)

// debugLogf sends Tailscale's internal log to the Android system log (tag GoLog) when CCRD_DEBUG is set.
func debugLogf(format string, args ...any) {
	if os.Getenv("CCRD_DEBUG") != "" {
		log.Printf(format, args...)
	}
}

func logf(format string, args ...any) {
	line := fmt.Sprintf(format, args...)
	mu.Lock()
	logTail = append(logTail, line)
	if len(logTail) > 60 {
		logTail = logTail[len(logTail)-60:]
	}
	mu.Unlock()
}

// Start brings the embedded node up in the background. dir is app-private storage that keeps the
// node's identity between launches. Safe to call more than once.
func Start(dir string, hostname string) {
	mu.Lock()
	if srv != nil {
		mu.Unlock()
		return
	}
	os.Setenv("HOME", dir)
	// Don't upload Tailscale's diagnostic logs to Tailscale (the same as tailscaled --no-logs-no-support).
	envknob.SetNoLogsNoSupport()
	os.Setenv("TS_LOGS_DIR", dir)
	// Set CCRD_DEBUG=1 here to send Tailscale's log to logcat (tag GoLog) while debugging.
	os.MkdirAll(dir, 0o700)
	s := &tsnet.Server{Dir: dir, Hostname: hostname, Logf: debugLogf, UserLogf: logf}
	// Optional one-time sign-in without the QR code: an auth key left in dir/authkey (the app writes it there
	// when started with "adb shell am start ... --es authkey tskey-..."). Used once, then deleted.
	if b, err := os.ReadFile(dir + "/authkey"); err == nil {
		s.AuthKey = strings.TrimSpace(string(b))
		os.Remove(dir + "/authkey")
	}
	s.RegisterFallbackTCPHandler(forwardOut)
	srv = s
	mu.Unlock()
	go watch(s)
}

func watch(s *tsnet.Server) {
	if err := s.Start(); err != nil {
		setErr(err)
		return
	}
	lc, err := s.LocalClient()
	if err != nil {
		setErr(err)
		return
	}
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		st, err := lc.StatusWithoutPeers(ctx)
		cancel()
		mu.Lock()
		if err != nil {
			lastErr = err.Error()
		} else {
			state = st.BackendState
			authURL = st.AuthURL
			lastErr = ""
		}
		mu.Unlock()
		time.Sleep(time.Second)
	}
}

func setErr(err error) {
	mu.Lock()
	lastErr = err.Error()
	state = "Error"
	mu.Unlock()
}

// State is the node's state: "Starting", "NeedsLogin", "Running", "Error", ...
func State() string { mu.Lock(); defer mu.Unlock(); return state }

// AuthURL is the sign-in link to show (as a QR code) while State is "NeedsLogin".
func AuthURL() string { mu.Lock(); defer mu.Unlock(); return authURL }

// LastError is the most recent error, or "".
func LastError() string { mu.Lock(); defer mu.Unlock(); return lastErr }

// Log returns the node's recent user-facing log lines.
func Log() string { mu.Lock(); defer mu.Unlock(); return strings.Join(logTail, "\n") }

// Forward listens on 127.0.0.1:localPort and carries each connection to target ("host:port") over
// the tailnet. The stream's video decoder only runs on a localhost or HTTPS origin; this makes the
// desktop's tailnet address look like localhost. Returns "" on success or an error message.
func Forward(localPort int, target string) string {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return "not started"
	}
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", localPort))
	if err != nil {
		return err.Error()
	}
	go func() {
		for {
			in, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer in.Close()
				ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
				t := target
				if h, port, err := net.SplitHostPort(target); err == nil && h == "ccrd" {
					t = net.JoinHostPort(Desktop(), port) // whichever computer is chosen (computers.go)
				}
				out, err := s.Dial(ctx, "tcp", resolveTarget(s, t))
				cancel()
				if err != nil {
					logf("dial %s: %v", target, err)
					return
				}
				defer out.Close()
				go io.Copy(out, in)
				io.Copy(in, out)
			}()
		}
	}()
	return ""
}

// ShareHome makes the TV the house's node while the app runs: it offers its internet connection
// (exit node, so the cloud desktop browses from the home address) and its home network lanCIDR
// (e.g. "192.168.1.0/24", for printers and other devices). Tailscale still has to approve the
// routes (admin console, or autoApprovers in the tailnet policy). Returns "" or an error message.
func ShareHome(lanCIDR string) string {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return "not started"
	}
	lc, err := s.LocalClient()
	if err != nil {
		return err.Error()
	}
	routes := []netip.Prefix{netip.MustParsePrefix("0.0.0.0/0"), netip.MustParsePrefix("::/0")}
	if lanCIDR != "" {
		p, err := netip.ParsePrefix(lanCIDR)
		if err != nil {
			return "bad home network " + lanCIDR + ": " + err.Error()
		}
		routes = append(routes, p.Masked())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err = lc.EditPrefs(ctx, &ipn.MaskedPrefs{
		Prefs:              ipn.Prefs{AdvertiseRoutes: routes},
		AdvertiseRoutesSet: true,
	})
	if err != nil {
		return err.Error()
	}
	logf("sharing home: %v", routes)
	return ""
}

// SetDNS tells Go's resolver which DNS servers to use ("ip ip ..."). Android has no /etc/resolv.conf,
// so without this, name lookups from the app (and for the cloud desktop when the TV is its exit node) fail.
func SetDNS(servers string) {
	list := strings.Fields(servers)
	if len(list) == 0 {
		return
	}
	var n uint32
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var d net.Dialer
			i := int(atomic.AddUint32(&n, 1)) % len(list)
			return d.DialContext(ctx, network, net.JoinHostPort(list[i], "53"))
		},
	}
}

// forwardOut carries TCP connections that peers send through this TV (exit node and home-network
// traffic) out over the TV's own connection. tsnet drops such connections unless a handler claims them.
func forwardOut(src, dst netip.AddrPort) (func(net.Conn), bool) {
	if tsaddr.IsTailscaleIP(dst.Addr()) {
		return nil, false
	}
	// No IPv6 at home: refuse before the handshake, so the other side falls back to IPv4 at once.
	if dst.Addr().Is6() && !dst.Addr().Is4In6() && !haveIPv6() {
		return nil, false
	}
	return func(in net.Conn) {
		defer in.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		var d net.Dialer
		out, err := d.DialContext(ctx, "tcp", dst.String())
		cancel()
		if err != nil {
			debugLogf("ccrd: forward %v -> %v: %v", src, dst, err)
			return
		}
		defer out.Close()
		go func() { io.Copy(out, in); out.(*net.TCPConn).CloseWrite() }()
		io.Copy(in, out)
	}, true
}

var v6 struct {
	sync.Mutex
	ok      bool
	checked time.Time
}

// haveIPv6 reports whether the TV has a route to the IPv6 internet (checked at most once a minute;
// a UDP "connect" sends nothing, it only asks the system for a route).
func haveIPv6() bool {
	v6.Lock()
	defer v6.Unlock()
	if time.Since(v6.checked) < time.Minute {
		return v6.ok
	}
	c, err := net.Dial("udp6", "[2001:4860:4860::8888]:53")
	if c != nil {
		c.Close()
	}
	v6.ok, v6.checked = err == nil, time.Now()
	return v6.ok
}
