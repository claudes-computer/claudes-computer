package ccrdnet

import (
	"fmt"
	"net"
	"net/netip"
	"strings"

	"tailscale.com/net/netmon"
)

// Android doesn't let apps list network interfaces the way Go does (netlink is blocked), so the
// app reads them through Android's own API and hands them over as text. Same approach as
// Tailscale's Android app. One interface per line:
//
//	name index mtu up broadcast loopback pointToPoint multicast|addr/prefix addr/prefix ...
var ifaceText string

func init() { netmon.RegisterInterfaceGetter(getInterfaces) }

// SetInterfaces gives the node the device's network interfaces and the name of the one that
// carries the default route (for example "wlan0"). Call it before Start, and again when the
// network changes.
func SetInterfaces(text string, defaultIf string) {
	mu.Lock()
	ifaceText = text
	mu.Unlock()
	if defaultIf != "" {
		setDefaultRouteInterface(defaultIf)
	}
}

func getInterfaces() ([]netmon.Interface, error) {
	mu.Lock()
	text := ifaceText
	mu.Unlock()
	var out []netmon.Interface
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		head, addrPart, _ := strings.Cut(line, "|")
		var name string
		var index, mtu int
		var up, bc, lo, p2p, mc bool
		if _, err := fmt.Sscanf(head, "%s %d %d %t %t %t %t %t", &name, &index, &mtu, &up, &bc, &lo, &p2p, &mc); err != nil {
			continue
		}
		ni := &net.Interface{Name: name, Index: index, MTU: mtu}
		if up {
			ni.Flags |= net.FlagUp | net.FlagRunning
		}
		if bc {
			ni.Flags |= net.FlagBroadcast
		}
		if lo {
			ni.Flags |= net.FlagLoopback
		}
		if p2p {
			ni.Flags |= net.FlagPointToPoint
		}
		if mc {
			ni.Flags |= net.FlagMulticast
		}
		addrs := []net.Addr{}
		for _, a := range strings.Fields(addrPart) {
			pfx, err := netip.ParsePrefix(a)
			if err != nil {
				continue
			}
			addrs = append(addrs, &net.IPNet{IP: pfx.Addr().AsSlice(), Mask: net.CIDRMask(pfx.Bits(), pfx.Addr().BitLen())})
		}
		out = append(out, netmon.Interface{Interface: ni, AltAddrs: addrs})
	}
	return out, nil
}
