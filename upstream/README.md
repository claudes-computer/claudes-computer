# Fixes offered upstream

Small patches that came out of this project and belong in the projects they change.

- **`tailscale-controlhttp-websocket-fallback.patch`** (for [tailscale/tailscale](https://github.com/tailscale/tailscale), against `main`;
  the same commit is the branch [`control-websocket-fallback`](https://github.com/stuckdrew/tailscale/tree/control-websocket-fallback) on a fork):
  lets a normal Tailscale client log in from behind a proxy that intercepts TLS and refuses Tailscale's own
  protocol upgrade but allows WebSockets, as some AI agents' sandboxes do. It is the control-connection half of
  what Tailscale's `feature/derpwebsocket` does for relays, and it is built the same way: a hook in
  `control/controlhttp` (called when the upgrade gets an ordinary HTTP response) and an opt-in package,
  `feature/controlwebsocket`, that a program imports to switch it on. Without the import nothing changes.
  It comes with tests (fallback used, fallback not needed, both refused).

The build this project actually runs (`cloud/tailscale-control-websocket.patch`, against v1.106.0) is an earlier
form of the same idea plus two conveniences: the relay WebSocket fallback linked into tailscaled, and the
`TS_CONTROL_WEBSOCKET=1` / `TS_DERP_WEBSOCKET=1` switches that try WebSocket first.
