# Fixes offered upstream

Small patches that came out of this project and belong in the projects they change.

- **`tailscale-controlhttp-websocket-fallback.patch`** (for [tailscale/tailscale](https://github.com/tailscale/tailscale), against v1.106.0):
  lets a normal Tailscale client log in from behind a proxy that intercepts TLS and refuses Tailscale's own
  protocol upgrade but allows WebSockets, as some AI agents' sandboxes do. It is the control-connection half of
  what Tailscale's `feature/derpwebsocket` does for relays. About 80 lines in `control/controlhttp`.
  Apply with `patch -p1`, build `./cmd/tailscaled`, run with `HTTPS_PROXY` set; the log says
  `controlhttp: connected over WebSocket`. `TS_CONTROL_WEBSOCKET=1` tries WebSocket first.

The build this project actually runs (`cloud/tailscale-control-websocket.patch`) is this plus two conveniences:
the relay WebSocket fallback linked into tailscaled, and `TS_DERP_WEBSOCKET=1`.
