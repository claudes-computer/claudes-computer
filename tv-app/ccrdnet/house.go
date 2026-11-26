package ccrdnet

import (
	"bufio"
	"context"
	"encoding/json"
	"encoding/xml"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// The house check-up: what is on the home network right now.
//
// The cloud desktop can reach home devices through this TV (the subnet route), but only one address at a time,
// and it can't hear the announcements devices make on the local network. The TV is on that network, so it does
// the looking: which addresses answer, which common doors (ports) are open on each, what each device calls
// itself (mDNS and UPnP announcements, the router's own name service), and its hardware address. The desktop asks
// for the list (GET /house/scan on the app's tailnet port, desktop only) and Claude explains it.

// Device is one thing found on the home network.
type Device struct {
	IP    string   `json:"ip"`
	MAC   string   `json:"mac,omitempty"`
	Names []string `json:"names,omitempty"` // what it calls itself (mDNS, UPnP, reverse DNS)
	Kinds []string `json:"kinds,omitempty"` // service types it announces, e.g. "_googlecast._tcp", "upnp:MediaRenderer"
	Maker string   `json:"maker,omitempty"` // from its UPnP description
	Model string   `json:"model,omitempty"`
	Ports []int    `json:"open_ports,omitempty"`
	Self  bool     `json:"this_tv,omitempty"`
	Gate  bool     `json:"router,omitempty"`
}

// HouseScan is the whole answer.
type HouseScan struct {
	Subnet   string    `json:"subnet"`
	Router   string    `json:"router"`
	Took     string    `json:"took"`
	Devices  []*Device `json:"devices"`
	Skipped  string    `json:"skipped,omitempty"`
	Scanned  int       `json:"addresses_scanned"`
	PortList []int     `json:"ports_checked"`
}

var (
	houseMu     sync.Mutex
	houseSubnet string
	houseRouter string
	houseTZ     string
)

// SetTimeZone records the TV's time zone (e.g. "America/Chicago"); the desktop sets its clock from it.
func SetTimeZone(tz string) {
	houseMu.Lock()
	houseTZ = tz
	houseMu.Unlock()
}

func timeZone() string {
	houseMu.Lock()
	defer houseMu.Unlock()
	return houseTZ
}

// SetHome tells the library which network is home (e.g. "192.168.1.0/24") and the router's address.
func SetHome(subnet string, router string) {
	houseMu.Lock()
	houseSubnet, houseRouter = subnet, router
	houseMu.Unlock()
}

// Ports worth knowing about on a home device: remote logins, admin pages, file sharing, cameras, printers,
// casting, debugging doors that should usually be closed.
var housePorts = []int{21, 22, 23, 53, 80, 139, 443, 445, 554, 631, 1883, 1900, 3389, 5000, 5555, 5900,
	7000, 8008, 8009, 8080, 8443, 8883, 9100, 49152, 62078}

func scanHouse(ctx context.Context) *HouseScan {
	houseMu.Lock()
	subnet, router := houseSubnet, houseRouter
	houseMu.Unlock()
	start := time.Now()
	res := &HouseScan{Subnet: subnet, Router: router, PortList: housePorts}
	pfx, err := netip.ParsePrefix(subnet)
	if err != nil || !pfx.Addr().Is4() {
		res.Skipped = "this TV doesn't know its home network yet"
		return res
	}
	if pfx.Bits() < 20 {
		res.Skipped = "the home network is larger than 4,096 addresses; not scanning all of it"
		return res
	}
	devs := map[string]*Device{}
	var mu sync.Mutex
	get := func(ip string) *Device {
		d := devs[ip]
		if d == nil {
			d = &Device{IP: ip}
			devs[ip] = d
		}
		return d
	}

	// 1. Find which addresses have a device. A knock on each address is enough: even a device that ignores the
	//    knock has to tell the TV its hardware address first, and that shows up in the TV's neighbour table.
	//    (Where Android doesn't let apps read that table, only devices that answer the knock are found.)
	var wg sync.WaitGroup
	sem := make(chan struct{}, 200)
	knock := func(ip string, port int, timeout time.Duration, record bool) {
		defer wg.Done()
		defer func() { <-sem }()
		d := net.Dialer{Timeout: timeout}
		c, err := d.DialContext(ctx, "tcp4", net.JoinHostPort(ip, itoa(port)))
		// "Unreachable" for a device we know is there means the TV's neighbour table is still full from the
		// sweep (see below): give it a moment and ask again.
		for try := 0; record && err != nil && try < 4 && strings.Contains(err.Error(), "unreachable"); try++ {
			select {
			case <-ctx.Done():
				return
			case <-time.After(3 * time.Second):
			}
			c, err = d.DialContext(ctx, "tcp4", net.JoinHostPort(ip, itoa(port)))
		}
		if err == nil {
			c.Close()
			mu.Lock()
			dev := get(ip)
			if record {
				dev.Ports = append(dev.Ports, port)
			}
			mu.Unlock()
		} else if strings.Contains(err.Error(), "refused") {
			mu.Lock()
			get(ip)
			mu.Unlock()
		}
	}
	// Every address knocked on takes a slot in the TV's neighbour table for a few seconds, and the table is small
	// (1,024 on this kind of TV): fill it and the TV can't reach anything, the router included ("network is
	// unreachable"). So go 120 addresses at a time, note who answered, and let the table drain in between.
	scanDone := make(chan struct{})
	go func() {
		defer close(scanDone)
		batch := 0
		for a := pfx.Masked().Addr().Next(); pfx.Contains(a); a = a.Next() {
			res.Scanned++
			for _, port := range []int{80, 443} {
				wg.Add(1)
				sem <- struct{}{}
				go knock(a.String(), port, 600*time.Millisecond, false)
			}
			if batch++; batch == 120 {
				batch = 0
				wg.Wait()
				mu.Lock()
				for ip, mac := range arpTable() {
					if inPrefix(pfx, ip) {
						get(ip).MAC = mac
					}
				}
				mu.Unlock()
				select {
				case <-ctx.Done():
					return
				case <-time.After(5 * time.Second):
				}
			}
		}
		wg.Wait()
	}()

	// 2. Meanwhile, listen to what devices announce about themselves.
	var dwg sync.WaitGroup
	dwg.Add(2)
	go func() {
		defer dwg.Done()
		for _, a := range ssdpDiscover(ctx) {
			if !inPrefix(pfx, a.ip) {
				continue
			}
			mu.Lock()
			d := get(a.ip)
			d.Names = addOnce(d.Names, a.name)
			d.Kinds = addOnce(d.Kinds, a.kind)
			if a.maker != "" {
				d.Maker = a.maker
			}
			if a.model != "" {
				d.Model = a.model
			}
			mu.Unlock()
		}
	}()
	go func() {
		defer dwg.Done()
		for _, a := range mdnsDiscover(ctx) {
			if !inPrefix(pfx, a.ip) {
				continue
			}
			mu.Lock()
			d := get(a.ip)
			d.Names = addOnce(d.Names, a.name)
			d.Kinds = addOnce(d.Kinds, a.kind)
			mu.Unlock()
		}
	}()
	dwg.Wait()
	<-scanDone

	// 3. Hardware addresses from the neighbour table, then the common doors of each device that is there.
	for ip, mac := range arpTable() {
		if inPrefix(pfx, ip) {
			get(ip).MAC = mac
		}
	}
	live := make([]string, 0, len(devs))
	for ip := range devs {
		live = append(live, ip)
	}
	for _, ip := range live {
		for _, port := range housePorts {
			wg.Add(1)
			sem <- struct{}{}
			go knock(ip, port, 900*time.Millisecond, true)
		}
	}
	wg.Wait()
	// Devices just spoken to are in the neighbour table for sure now: pick up any hardware address missed earlier.
	for ip, mac := range arpTable() {
		if d := devs[ip]; d != nil && d.MAC == "" {
			d.MAC = mac
		}
	}

	// 4. Names the router knows.
	var nwg sync.WaitGroup
	for _, d := range devs {
		nwg.Add(1)
		go func(d *Device) {
			defer nwg.Done()
			c, cancel := context.WithTimeout(ctx, 2*time.Second)
			defer cancel()
			if names, err := net.DefaultResolver.LookupAddr(c, d.IP); err == nil {
				for _, n := range names {
					mu.Lock()
					d.Names = addOnce(d.Names, strings.TrimSuffix(n, "."))
					mu.Unlock()
				}
			}
		}(d)
	}
	nwg.Wait()

	self := map[string]bool{}
	if ifs, err := getInterfaces(); err == nil {
		for _, i := range ifs {
			for _, a := range i.AltAddrs {
				if n, ok := a.(*net.IPNet); ok {
					self[n.IP.String()] = true
				}
			}
		}
	}
	for ip, d := range devs {
		d.Self = self[ip]
		d.Gate = ip == router
		sort.Ints(d.Ports)
		sort.Strings(d.Names)
		sort.Strings(d.Kinds)
		res.Devices = append(res.Devices, d)
	}
	sort.Slice(res.Devices, func(i, j int) bool {
		a, _ := netip.ParseAddr(res.Devices[i].IP)
		b, _ := netip.ParseAddr(res.Devices[j].IP)
		return a.Less(b)
	})
	res.Took = time.Since(start).Round(time.Second).String()
	if ctx.Err() != nil && res.Skipped == "" {
		// Ran out of time (a big home network): say so, so a short list isn't mistaken for the whole house.
		res.Skipped = "ran out of time; this list may be missing devices"
	}
	return res
}

// sameDevice reports whether an announced description address is a plain http URL on the announcing device
// itself: no user part (http://<ip>@elsewhere/), no look-alike host (http://<ip>.elsewhere/ or a longer address).
func sameDevice(loc, ip string) bool {
	u, err := url.Parse(loc)
	return err == nil && u.Scheme == "http" && u.User == nil && u.Hostname() == ip
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

func inPrefix(p netip.Prefix, ip string) bool {
	a, err := netip.ParseAddr(ip)
	return err == nil && p.Contains(a)
}

func addOnce(list []string, s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return list
	}
	for _, x := range list {
		if strings.EqualFold(x, s) {
			return list
		}
	}
	return append(list, s)
}

// arpTable reads the kernel's neighbour table: IP -> hardware address, for devices this TV has talked to.
func arpTable() map[string]string {
	out := map[string]string{}
	f, err := os.Open("/proc/net/arp")
	if err != nil {
		return out // newer Android versions don't let apps read it
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Scan() // header
	for sc.Scan() {
		p := strings.Fields(sc.Text())
		if len(p) >= 4 && p[3] != "00:00:00:00:00:00" {
			out[p[0]] = p[3]
		}
	}
	return out
}

type announce struct{ ip, name, kind, maker, model string }

// ssdpDiscover asks "who's there?" the UPnP way and reads each answering device's description.
func ssdpDiscover(ctx context.Context) []announce {
	pc, err := net.ListenPacket("udp4", ":0")
	if err != nil {
		return nil
	}
	defer pc.Close()
	msg := "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n"
	dst := &net.UDPAddr{IP: net.IPv4(239, 255, 255, 250), Port: 1900}
	for i := 0; i < 2; i++ {
		pc.WriteTo([]byte(msg), dst)
	}
	pc.SetReadDeadline(time.Now().Add(4 * time.Second))
	locs := map[string]string{} // description URL -> ip
	var out []announce
	buf := make([]byte, 4096)
	for {
		n, from, err := pc.ReadFrom(buf)
		if err != nil {
			break
		}
		ip := from.(*net.UDPAddr).IP.String()
		var st, loc string
		for _, line := range strings.Split(string(buf[:n]), "\r\n") {
			k, v, ok := strings.Cut(line, ":")
			if !ok {
				continue
			}
			switch strings.ToUpper(strings.TrimSpace(k)) {
			case "ST":
				st = strings.TrimSpace(v)
			case "LOCATION":
				loc = strings.TrimSpace(v)
			}
		}
		kind := ""
		if i := strings.Index(st, ":device:"); i >= 0 {
			kind = "upnp:" + strings.Split(st[i+8:], ":")[0]
		}
		out = append(out, announce{ip: ip, kind: kind})
		if loc != "" {
			locs[loc] = ip
		}
	}
	// Each description is a small XML file on the device itself: its friendly name, maker and model.
	// No redirects: a description is read only from the device that announced it.
	client := &http.Client{Timeout: 3 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	n := 0
	for loc, ip := range locs {
		if n++; n > 40 {
			break
		}
		if !sameDevice(loc, ip) {
			continue // only read a description from the device that announced it
		}
		req, err := http.NewRequestWithContext(ctx, "GET", loc, nil)
		if err != nil {
			continue
		}
		res, err := client.Do(req)
		if err != nil {
			continue
		}
		var d struct {
			Device struct {
				FriendlyName string `xml:"friendlyName"`
				Manufacturer string `xml:"manufacturer"`
				ModelName    string `xml:"modelName"`
			} `xml:"device"`
		}
		b, _ := io.ReadAll(io.LimitReader(res.Body, 256<<10))
		res.Body.Close()
		if xml.Unmarshal(b, &d) == nil {
			out = append(out, announce{ip: ip, name: d.Device.FriendlyName, maker: d.Device.Manufacturer, model: d.Device.ModelName})
		}
	}
	return out
}

// Service types asked for by name, besides whatever devices list themselves.
var mdnsTypes = []string{"_services._dns-sd._udp", "_googlecast._tcp", "_airplay._tcp", "_raop._tcp", "_ipp._tcp",
	"_ipps._tcp", "_printer._tcp", "_hap._tcp", "_matter._tcp", "_hue._tcp", "_smb._tcp", "_ssh._tcp", "_http._tcp",
	"_spotify-connect._tcp", "_amzn-wplay._tcp", "_companion-link._tcp", "_androidtvremote2._tcp", "_workstation._tcp"}

// mdnsDiscover asks the local network which services exist (the way phones find printers and speakers) and
// collects, per answering address, the names and service types it mentions.
func mdnsDiscover(ctx context.Context) []announce {
	pc, err := net.ListenPacket("udp4", ":0")
	if err != nil {
		return nil
	}
	defer pc.Close()
	dst := &net.UDPAddr{IP: net.IPv4(224, 0, 0, 251), Port: 5353}
	for round := 0; round < 2; round++ {
		for _, t := range mdnsTypes {
			name, err := dnsmessage.NewName(t + ".local.")
			if err != nil {
				continue
			}
			m := dnsmessage.Message{Questions: []dnsmessage.Question{{
				Name: name, Type: dnsmessage.TypePTR,
				Class: dnsmessage.ClassINET | 0x8000, // ask for a reply straight to us
			}}}
			if b, err := m.Pack(); err == nil {
				pc.WriteTo(b, dst)
			}
		}
		time.Sleep(300 * time.Millisecond)
	}
	pc.SetReadDeadline(time.Now().Add(4 * time.Second))
	var out []announce
	buf := make([]byte, 9000)
	for {
		n, from, err := pc.ReadFrom(buf)
		if err != nil {
			break
		}
		ip := from.(*net.UDPAddr).IP.String()
		var p dnsmessage.Parser
		if _, err := p.Start(buf[:n]); err != nil {
			continue
		}
		p.SkipAllQuestions()
		read := func(next func() (dnsmessage.Resource, error)) {
			for {
				r, err := next()
				if err != nil {
					return
				}
				owner := strings.TrimSuffix(r.Header.Name.String(), ".local.")
				switch b := r.Body.(type) {
				case *dnsmessage.PTRResource:
					target := strings.TrimSuffix(b.PTR.String(), ".local.")
					if strings.HasPrefix(owner, "_services._dns-sd") {
						out = append(out, announce{ip: ip, kind: target})
					} else {
						// "Living Room TV._googlecast._tcp" -> name "Living Room TV", kind "_googlecast._tcp"
						inst := strings.TrimSuffix(target, "."+owner)
						out = append(out, announce{ip: ip, kind: owner, name: unescapeDNS(inst)})
					}
				case *dnsmessage.AResource:
					out = append(out, announce{ip: ip, name: owner})
				}
			}
		}
		read(p.Answer)
		p.SkipAllAuthorities()
		read(p.Additional)
	}
	return out
}

// unescapeDNS turns "Living\032Room" (how DNS writes a space) back into "Living Room".
func unescapeDNS(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) && isDigit(s[i+1]) && isDigit(s[i+2]) && isDigit(s[i+3]) {
			b.WriteByte((s[i+1]-'0')*100 + (s[i+2]-'0')*10 + (s[i+3] - '0'))
			i += 3
		} else if s[i] == '\\' && i+1 < len(s) {
			i++
			b.WriteByte(s[i])
		} else {
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }
