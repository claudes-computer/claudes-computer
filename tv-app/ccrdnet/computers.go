package ccrdnet

// More than one computer. Every Claude Code session is its own computer: "ccrd" is the first one, and others name
// themselves "ccrd-<name>" ("ccrd-work"). TVs are "ccrd-tv", so names starting with "ccrd-tv" are never computers.
// The app shows the one chosen with SetDesktop; Forward follows it, so switching is just changing the name.
// Other agents' desktops (Codex, Muse, ...) count too: anything of the user's serving the stream on port 6081.

import (
	"context"
	"encoding/json"
	"net"
	"sort"
	"strings"
	"sync"
	"time"
)

var desktopHost = "ccrd"

// found: desktops found by their stream (port 6081) under names that don't follow the "ccrd-" pattern, so
// SetDesktop accepts them too.
var found = map[string]bool{}

// IsDesktopName says whether a Tailscale device name is one of the user's computers by its name.
func IsDesktopName(h string) bool {
	h = strings.ToLower(h)
	return h == "ccrd" || (strings.HasPrefix(h, "ccrd-") && !strings.HasPrefix(h, "ccrd-tv") && len(h) > 5)
}

func isTV(h string) bool { return strings.HasPrefix(strings.ToLower(h), "ccrd-tv") }

// SetDesktop chooses which computer the app shows ("ccrd", "ccrd-work", or any desktop Desktops found).
func SetDesktop(h string) {
	h = strings.ToLower(h)
	mu.Lock()
	if isTV(h) || !(IsDesktopName(h) || found[h]) {
		h = "ccrd"
	}
	desktopHost = h
	mu.Unlock()
}

// Desktop is the computer the app shows now.
func Desktop() string { mu.Lock(); defer mu.Unlock(); return desktopHost }

// Desktops lists the user's desktops this TV can see as JSON: [{"host":"ccrd","online":true}, ...], the first
// computer ("ccrd") first, then by name. A desktop is any online device of the same Tailscale user that serves the
// desktop stream on port 6081 (Claude's, Codex's, Muse's, ... whatever it's called), plus the "ccrd"/"ccrd-<name>"
// devices that are asleep. TVs never count.
func Desktops() string {
	mu.Lock()
	s := srv
	mu.Unlock()
	out := []map[string]any{}
	if s != nil {
		if lc, err := s.LocalClient(); err == nil {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			st, err := lc.Status(ctx)
			cancel()
			if err == nil && st != nil && st.Self != nil {
				type cand struct {
					host, ip string
					named    bool
				}
				var probe []cand
				state := map[string]bool{}
				for _, p := range st.Peer {
					h := strings.ToLower(p.HostName)
					if p.UserID != st.Self.UserID || isTV(h) || p.Expired { // signed out for good: not listed
						continue
					}
					named := IsDesktopName(h)
					if p.Online && len(p.TailscaleIPs) > 0 {
						probe = append(probe, cand{h, p.TailscaleIPs[0].String(), named})
					} else if named {
						if _, ok := state[h]; !ok {
							state[h] = false
						}
					}
				}
				// Ask each online device whether it serves the stream, all at once (a second or two at most).
				var wg sync.WaitGroup
				var smu sync.Mutex
				for _, c := range probe {
					wg.Add(1)
					go func(c cand) {
						defer wg.Done()
						ctx, cancel := context.WithTimeout(context.Background(), 2500*time.Millisecond)
						defer cancel()
						on := false
						if conn, err := s.Dial(ctx, "tcp", net.JoinHostPort(c.ip, "6081")); err == nil {
							conn.Close()
							on = true
						}
						smu.Lock()
						defer smu.Unlock()
						if on {
							state[c.host] = true
						} else if c.named {
							if _, ok := state[c.host]; !ok {
								state[c.host] = false // a computer that's up but whose desktop isn't (yet)
							}
						}
					}(c)
				}
				wg.Wait()
				mu.Lock()
				for h, on := range state {
					if on && !IsDesktopName(h) {
						found[h] = true
					}
				}
				mu.Unlock()
				for h, on := range state {
					out = append(out, map[string]any{"host": h, "online": on})
				}
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i]["host"].(string), out[j]["host"].(string)
		if (a == "ccrd") != (b == "ccrd") {
			return a == "ccrd"
		}
		return a < b
	})
	b, _ := json.Marshal(out)
	return string(b)
}
