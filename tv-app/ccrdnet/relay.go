package ccrdnet

// The TV as the house's fast relay: Tailscale's relay (DERP) server running inside the app, reachable
// from the internet on the router's port 443 (opened by the app itself over NAT-PMP), with its own
// Let's Encrypt certificate. Only devices in the user's own tailnet may use it.

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"ccrdnet/autocert"
	"tailscale.com/derp/derpserver"
	"tailscale.com/net/stunserver"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
)

const (
	relayRegion   = 900   // the tailnet policy's region for the home relay
	relayTLSPort  = 28443 // apps can't bind below 1024; the router maps outside 443 here
	relaySTUNPort = 3478
)

var relay struct {
	sync.Mutex
	running bool
	status  string
}

// RelayStatus describes the TV relay: "off", "starting", "running as <name>", or why it stopped.
func RelayStatus() string {
	relay.Lock()
	defer relay.Unlock()
	if relay.status == "" {
		return "off"
	}
	return relay.status
}

func setRelayStatus(format string, args ...any) {
	relay.Lock()
	relay.status = fmt.Sprintf(format, args...)
	relay.Unlock()
	logf("relay: %s", relay.status)
}

// StartRelay starts the relay in the background. gateway is the home router's IPv4 address.
// Returns "" if it started trying, or why it can't.
func StartRelay(gateway string) string {
	relay.Lock()
	if relay.running {
		relay.Unlock()
		return ""
	}
	gw, err := netip.ParseAddr(gateway)
	if err != nil || !gw.Is4() {
		relay.Unlock()
		// Not marked running: a later call (once the network has a router address) can still start it.
		setRelayStatus("no home router address (%q)", gateway)
		return RelayStatus()
	}
	relay.running = true
	relay.Unlock()
	go runRelay(gw)
	return ""
}

func runRelay(gw netip.Addr) {
	// Whatever way this ends, the relay can be started again.
	defer func() {
		relay.Lock()
		relay.running = false
		relay.Unlock()
	}()
	setRelayStatus("starting")
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		setRelayStatus("tailnet node not started")
		return
	}
	lc, err := s.LocalClient()
	if err != nil {
		setRelayStatus("local client: %v", err)
		return
	}
	// The relay's public name comes from the tailnet policy (derpMap region 900).
	var host string
	for host == "" {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		dm, err := lc.CurrentDERPMap(ctx)
		cancel()
		if err == nil && dm != nil {
			if r := dm.Regions[relayRegion]; r != nil && len(r.Nodes) > 0 {
				host = r.Nodes[0].HostName
			}
		}
		if host == "" {
			setRelayStatus("waiting for a home relay (region %d) in the tailnet policy", relayRegion)
			time.Sleep(30 * time.Second)
		}
	}

	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", relayTLSPort))
	if err != nil {
		setRelayStatus("can't listen on %d: %v", relayTLSPort, err)
		return
	}
	// Clear this TV's own earlier mappings (an older build used inside port 8443), then ask the
	// router for outside TCP 443 -> relayTLSPort and UDP 3478 -> relaySTUNPort.
	natpmpMap(gw, 2, 8443, 0, 0)
	natpmpMap(gw, 2, relayTLSPort, 0, 0)
	ext, err := natpmpMap(gw, 2, relayTLSPort, 443, 3600)
	if err != nil || ext != 443 {
		setRelayStatus("router did not give us port 443 (got %d, %v); another device may hold it", ext, err)
		natpmpMap(gw, 2, relayTLSPort, 0, 0)
		ln.Close()
		return
	}
	natpmpMap(gw, 1, relaySTUNPort, relaySTUNPort, 3600)
	// Renew the router's mappings while the relay runs; on any way out, stop renewing, give the ports back and
	// close the listener, so nothing points at a port nobody serves.
	stop := make(chan struct{})
	defer func() {
		close(stop)
		ln.Close()
		natpmpMap(gw, 2, relayTLSPort, 0, 0)
		natpmpMap(gw, 1, relaySTUNPort, 0, 0)
	}()
	go func() {
		t := time.NewTicker(25 * time.Minute)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				natpmpMap(gw, 2, relayTLSPort, 443, 3600)
				natpmpMap(gw, 1, relaySTUNPort, relaySTUNPort, 3600)
			}
		}
	}()

	dir := filepath.Join(os.Getenv("HOME"), "relay")
	os.MkdirAll(dir, 0o700)
	priv, err := loadOrMakeKey(filepath.Join(dir, "relay.key"))
	if err != nil {
		setRelayStatus("key: %v", err)
		return
	}
	ds := derpserver.New(priv, func(string, ...any) {})

	// Admission: only nodes our own tailnet node knows about may use the relay.
	adm, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		setRelayStatus("admission listener: %v", err)
		return
	}
	go http.Serve(adm, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req tailcfg.DERPAdmitClientRequest
		allow := false
		if json.NewDecoder(r.Body).Decode(&req) == nil {
			ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
			_, err := lc.WhoIsNodeKey(ctx, req.NodePublic)
			cancel()
			allow = err == nil
		}
		json.NewEncoder(w).Encode(tailcfg.DERPAdmitClientResponse{Allow: allow})
	}))
	ds.SetVerifyClientURL("http://" + adm.Addr().String() + "/")

	go func() {
		ss := stunserver.New(context.Background())
		if err := ss.ListenAndServe(fmt.Sprintf(":%d", relaySTUNPort)); err != nil {
			logf("relay: stun: %v", err)
		}
	}()

	autocert.Logf = logf
	cm := &autocert.Manager{
		Prompt:     autocert.AcceptTOS,
		HostPolicy: autocert.HostWhitelist(host),
		Cache:      autocert.DirCache(filepath.Join(dir, "certs")),
	}
	mux := http.NewServeMux()
	mux.Handle("/derp", derpserver.Handler(ds))
	mux.HandleFunc("/derp/probe", derpserver.ProbeHandler)
	mux.HandleFunc("/derp/latency-check", derpserver.ProbeHandler)
	mux.HandleFunc("/generate_204", derpserver.ServeNoContent)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("Claude's Computer home relay\n")) })
	hs := &http.Server{
		Handler:   mux,
		TLSConfig: cm.TLSConfig(),
	}
	hs.TLSConfig.MinVersion = tls.VersionTLS12
	getCert := hs.TLSConfig.GetCertificate
	hs.TLSConfig.GetCertificate = func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
		c, err := getCert(hello)
		if err != nil {
			logf("relay: certificate for %q: %v", hello.ServerName, err)
			setRelayStatus("running as %s; certificate error: %v", host, err)
		}
		return c, err
	}
	hs.ErrorLog = log.New(logWriter{}, "relay http: ", 0)
	setRelayStatus("running as %s", host)
	err = hs.ServeTLS(ln, "", "")
	setRelayStatus("stopped: %v", err)
}

func loadOrMakeKey(path string) (key.NodePrivate, error) {
	if b, err := os.ReadFile(path); err == nil {
		var k key.NodePrivate
		if err := k.UnmarshalText(b); err == nil {
			return k, nil
		}
	}
	k := key.NewNode()
	b, err := k.MarshalText()
	if err != nil {
		return k, err
	}
	return k, os.WriteFile(path, b, 0o600)
}

// natpmpMap asks the router (NAT-PMP, RFC 6886) to map an outside port to internalPort on this device.
// op 1 = UDP, 2 = TCP. lifetime 0 removes the mapping. Returns the outside port the router assigned.
func natpmpMap(gw netip.Addr, op byte, internalPort, externalPort uint16, lifetime uint32) (uint16, error) {
	c, err := net.DialUDP("udp4", nil, net.UDPAddrFromAddrPort(netip.AddrPortFrom(gw, 5351)))
	if err != nil {
		return 0, err
	}
	defer c.Close()
	req := make([]byte, 12)
	req[1] = op
	binary.BigEndian.PutUint16(req[4:], internalPort)
	binary.BigEndian.PutUint16(req[6:], externalPort)
	binary.BigEndian.PutUint32(req[8:], lifetime)
	c.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := c.Write(req); err != nil {
		return 0, err
	}
	resp := make([]byte, 16)
	n, err := c.Read(resp)
	if err != nil {
		return 0, err
	}
	if n < 16 {
		return 0, errors.New("short NAT-PMP reply")
	}
	if rc := binary.BigEndian.Uint16(resp[2:]); rc != 0 {
		return 0, fmt.Errorf("NAT-PMP result %d", rc)
	}
	return binary.BigEndian.Uint16(resp[10:]), nil
}

type logWriter struct{}

func (logWriter) Write(b []byte) (int, error) {
	logf("%s", strings.TrimSpace(string(b)))
	return len(b), nil
}

// PreferHomeRelay tells this node to use the home relay (tailnet policy region 900) as its home relay
// whenever it answers. Tailscale otherwise keeps whichever relay it picked first, for example one it
// fell back to while the home relay was briefly down. The setting lasts until the app restarts.
func PreferHomeRelay() string {
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
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	dm, err := lc.CurrentDERPMap(ctx)
	if err != nil || dm == nil || dm.Regions[relayRegion] == nil {
		return "no home relay in the tailnet policy"
	}
	b, _ := json.Marshal(relayRegion)
	if err := lc.DebugActionBody(ctx, "force-prefer-derp", bytes.NewReader(b)); err != nil {
		return err.Error()
	}
	logf("preferring the home relay (region %d)", relayRegion)
	return ""
}

// tvConfig is what the cloud desktop tells the TV app (served at http://<desktop>:6083/tv-config.json
// over the tailnet). Claude writes it on the desktop during setup.
type tvConfig struct {
	DuckDNSName  string `json:"duckdns_name"`  // e.g. "my-house" (without .duckdns.org)
	DuckDNSToken string `json:"duckdns_token"` // the account token; never logged
}

// KeepHouseName starts a loop that reads the desktop's TV settings and keeps the house's DuckDNS
// name pointed at this home's internet address (the TV's own connection). desktopHost is the
// desktop's tailnet address.
func KeepHouseName(desktopHost string) {
	go func() {
		for {
			if msg := updateHouseName(desktopHost); msg != "" {
				logf("house name: %s", msg)
			}
			time.Sleep(10 * time.Minute)
		}
	}()
}

func updateHouseName(desktopHost string) string {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return "tailnet node not started"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", "http://"+resolveTarget(s, desktopHost+":6083")+"/tv-config.json", nil)
	res, err := s.HTTPClient().Do(req)
	if err != nil {
		return "no settings from the desktop yet"
	}
	defer res.Body.Close()
	var cfg tvConfig
	if res.StatusCode != 200 || json.NewDecoder(res.Body).Decode(&cfg) != nil || cfg.DuckDNSName == "" || cfg.DuckDNSToken == "" {
		return "no house name in the desktop's settings"
	}
	u := "https://www.duckdns.org/update?domains=" + cfg.DuckDNSName + "&token=" + cfg.DuckDNSToken
	req2, _ := http.NewRequestWithContext(ctx, "GET", u, nil)
	res2, err := http.DefaultClient.Do(req2)
	if err != nil {
		return "update failed: " + strings.ReplaceAll(err.Error(), cfg.DuckDNSToken, "***")
	}
	defer res2.Body.Close()
	b := make([]byte, 16)
	n, _ := res2.Body.Read(b)
	return cfg.DuckDNSName + ".duckdns.org update: " + strings.TrimSpace(string(b[:n]))
}
