package ccrdnet

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

// resolveTarget turns "ccrd:6081" into the address of the online device that asked to be called "ccrd".
// When the cloud machine is replaced, the new one may get the name "ccrd-1" while the old one is still listed,
// so looking the name up in DNS can find the wrong (dead) machine. Tailscale keeps the name each device asked
// for (HostName), so pick the online one with that name, the newest if there are several.
func resolveTarget(s *tsnet.Server, target string) string {
	host, port, err := net.SplitHostPort(target)
	if err != nil {
		return target
	}
	if _, err := netip.ParseAddr(host); err == nil {
		return target
	}
	lc, err := s.LocalClient()
	if err != nil {
		return target
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	st, err := lc.Status(ctx)
	if err != nil || st == nil {
		return target
	}
	var best *ipnstate.PeerStatus
	for _, p := range st.Peer {
		if !p.Online || !strings.EqualFold(p.HostName, host) || len(p.TailscaleIPs) == 0 {
			continue
		}
		// A name is only a claim. The desktop must also belong to the same Tailscale user as this TV, which
		// rules out devices other people shared into the tailnet.
		if st.Self == nil || p.UserID != st.Self.UserID {
			continue
		}
		if best == nil || p.Created.After(best.Created) {
			best = p
		}
	}
	if best == nil {
		return target
	}
	return net.JoinHostPort(best.TailscaleIPs[0].String(), port)
}

var keepName = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

// ServeKeep runs the app's small service for the desktop on tailnet port 6084: a store where the cloud desktop
// keeps its sign-ins (Drive's rclone.conf), and the house check-up (GET /house/scan, see house.go). The cloud machine is replaced now and then and starts empty; the TV stays, so the new machine
// gets them back from here. Only a device named "ccrd" (the desktop) may read or write. Files live in dir,
// this app's private storage. Returns "" or an error message.
func ServeKeep(dir string) string {
	mu.Lock()
	s := srv
	mu.Unlock()
	if s == nil {
		return "not started"
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err.Error()
	}
	ln, err := s.Listen("tcp", ":6084")
	if err != nil {
		return err.Error()
	}
	lc, err := s.LocalClient()
	if err != nil {
		return err.Error()
	}
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		// Only the desktop: a device named "ccrd" that belongs to the same Tailscale user as this TV. The name
		// alone is only a claim; the user is what Tailscale vouches for (a device someone shared into the tailnet
		// belongs to them, not to you).
		who, err := lc.WhoIs(ctx, r.RemoteAddr)
		self, serr := lc.StatusWithoutPeers(ctx)
		if err != nil || serr != nil || who.Node == nil || who.UserProfile == nil || self.Self == nil ||
			who.Node.IsTagged() || who.UserProfile.ID != self.Self.UserID ||
			!IsDesktopName(who.Node.Hostinfo.Hostname()) {
			http.Error(w, "only the desktop", http.StatusForbidden)
			return
		}
		// Each computer keeps its own things (sign-ins, wake token): the first one in dir, others in dir/<name>.
		kdir := dir
		if h := strings.ToLower(who.Node.Hostinfo.Hostname()); h != "ccrd" {
			kdir = filepath.Join(dir, h)
			os.MkdirAll(kdir, 0o700)
		}
		// The house check-up (house.go): what's on the home network. Takes about half a minute.
		if r.URL.Path == "/house/scan" && r.Method == http.MethodGet {
			if t := currentTVInfo(); t != nil {
				t.Notice("Claude is checking your home network")
			}
			sctx, scancel := context.WithTimeout(r.Context(), 90*time.Second)
			defer scancel()
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(scanHouse(sctx))
			return
		}
		if r.URL.Path == "/house/timezone" && r.Method == http.MethodGet {
			io.WriteString(w, timeZone())
			return
		}
		// A new version of the app, sent by the desktop (report.go).
		if r.URL.Path == "/tv/update" && r.Method == http.MethodPut {
			t := currentTVInfo()
			if t == nil {
				http.Error(w, "not ready", http.StatusServiceUnavailable)
				return
			}
			apk := filepath.Join(filepath.Dir(dir), "update.apk")
			f, err := os.OpenFile(apk+".part", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
			if err != nil {
				http.Error(w, "can't save", http.StatusInternalServerError)
				return
			}
			n, err := io.Copy(f, io.LimitReader(r.Body, 64<<20))
			f.Close()
			if err != nil || n < 1<<20 || os.Rename(apk+".part", apk) != nil {
				os.Remove(apk + ".part")
				http.Error(w, "upload failed", http.StatusBadRequest)
				return
			}
			logf("update: received %d bytes; asking Android to install", n)
			t.Notice("Claude is updating this app")
			if msg := t.InstallUpdate(apk); msg != "" {
				http.Error(w, msg, http.StatusInternalServerError)
				return
			}
			io.WriteString(w, "waiting for the user to confirm on the TV\n")
			return
		}
		// The repair helper (report.go): POST /tv/helper?do=install|pair|code|keys|power|status&arg=...
		if r.URL.Path == "/tv/helper" && r.Method == http.MethodPost {
			t := currentTVInfo()
			if t == nil {
				http.Error(w, "not ready", http.StatusServiceUnavailable)
				return
			}
			do, arg := r.URL.Query().Get("do"), r.URL.Query().Get("arg")
			switch do {
			case "keys", "power":
				t.Notice("Claude is using the remote")
			case "pair", "adbpair":
				t.Notice("Claude is pairing the helper")
			case "shell":
				t.Notice("Claude is adjusting this TV")
			}
			msg := t.Helper(do, arg)
			if msg == "" {
				msg = "ok"
			}
			io.WriteString(w, msg+"\n")
			return
		}
		// The TV describing itself (report.go).
		if (r.URL.Path == "/tv/report" || r.URL.Path == "/tv/screen") && r.Method == http.MethodGet {
			t := currentTVInfo()
			if t == nil {
				http.Error(w, "not ready", http.StatusServiceUnavailable)
				return
			}
			if r.URL.Path == "/tv/report" {
				w.Header().Set("Content-Type", "application/json")
				io.WriteString(w, t.Report())
				return
			}
			t.Notice("Claude took a look at the screen")
			time.Sleep(400 * time.Millisecond) // the notice is in the picture too
			png := t.Screenshot()
			if len(png) == 0 {
				http.Error(w, "no picture", http.StatusServiceUnavailable)
				return
			}
			w.Header().Set("Content-Type", "image/png")
			w.Write(png)
			return
		}
		name := strings.TrimPrefix(r.URL.Path, "/keep/")
		if !keepName.MatchString(name) {
			http.Error(w, "bad name", http.StatusBadRequest)
			return
		}
		path := filepath.Join(kdir, name)
		switch r.Method {
		case http.MethodGet:
			b, err := os.ReadFile(path)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			w.Write(b)
		case http.MethodPut:
			b, err := io.ReadAll(io.LimitReader(r.Body, 256<<10))
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			if old, err := os.ReadFile(path); err == nil && string(old) == string(b) {
				return // unchanged: keep the file's date (the wake PIN is tied to it)
			}
			tmp := path + ".new"
			if err := os.WriteFile(tmp, b, 0o600); err != nil || os.Rename(tmp, path) != nil {
				http.Error(w, "can't save", http.StatusInternalServerError)
				return
			}
			logf("keep: saved %s (%d bytes) for the desktop", name, len(b))
		case http.MethodDelete:
			os.Remove(path)
		default:
			http.Error(w, "method", http.StatusMethodNotAllowed)
		}
	})
	go http.Serve(ln, h)
	return ""
}
