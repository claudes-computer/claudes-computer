//go:build android

package ccrdnet

import "tailscale.com/net/netmon"

func setDefaultRouteInterface(name string) { netmon.UpdateLastKnownDefaultRouteInterface(name) }
