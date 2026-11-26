package ccrdnet

// More than one computer. Every Claude Code session is its own computer: "ccrd" is the first one, and others name
// themselves "ccrd-<name>" ("ccrd-work"). TVs are "ccrd-tv", so names starting with "ccrd-tv" are never computers.
// The app shows the one chosen with SetDesktop; Forward follows it, so switching is just changing the name.

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"
)

var desktopHost = "ccrd"

// IsDesktopName says whether a Tailscale device name is one of the user's computers.
func IsDesktopName(h string) bool {
	h = strings.ToLower(h)
	return h == "ccrd" || (strings.HasPrefix(h, "ccrd-") && !strings.HasPrefix(h, "ccrd-tv") && len(h) > 5)
}

// SetDesktop chooses which computer the app shows ("ccrd", "ccrd-work", ...).
func SetDesktop(h string) {
	if !IsDesktopName(h) {
		h = "ccrd"
	}
	mu.Lock()
	desktopHost = strings.ToLower(h)
	mu.Unlock()
}

// Desktop is the computer the app shows now.
func Desktop() string { mu.Lock(); defer mu.Unlock(); return desktopHost }

// Desktops lists the user's computers this TV can see, awake or asleep, as JSON: [{"host":"ccrd","online":true}, ...],
// the first computer ("ccrd") first, then by name. Only devices of the same Tailscale user as this TV count.
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
				seen := map[string]bool{}
				for _, p := range st.Peer {
					h := strings.ToLower(p.HostName)
					if p.UserID != st.Self.UserID || !IsDesktopName(h) || p.Expired { // signed out for good: not listed
						continue
					}
					seen[h] = seen[h] || p.Online
				}
				for h, on := range seen {
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
