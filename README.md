# caddy-l4: the tls handler waits forever for a handshake that never completes

Minimal reproduction for [caddy-l4](https://github.com/mholt/caddy-l4)
(`master`, 42db569 / v0.1.2) with Caddy v2.11.4.

```
clients ──TCP──▶ Caddy :8443  layer4 { route { tls; echo } }
```

## The problem

The `tls` handler calls `tlsConn.Handshake()` with no deadline. The layer4
matching timeout (3 s by default) does not cover it, because the route clears
the read deadline as soon as it matches, before its handlers run.

- On a route with **no matchers**, the route matches at once, so a client that
  connects and sends no ClientHello, only part of one, or a complete
  ClientHello and nothing else keeps the connection, its socket and its
  goroutine for as long as it stays connected.
- On a route matched by **`tls sni`**, the matcher has to read the whole
  ClientHello within the matching timeout, so the first two clients are closed
  after 3 s. A client that sends a complete ClientHello and then stops is still
  kept forever.

TCP keepalive does not help, because the client's kernel answers the probes.

## Run it

Requirements: Docker with Compose. Caddy is built from source in the image.

```sh
./run.sh                                  # upstream master, route without matchers
MATCHER=sni ./run.sh                      # upstream master, route matched by "tls sni localhost"
HANDSHAKE_TIMEOUT=5s ./run.sh https://github.com/cruizba/caddy-l4 fix/tls-handshake-timeout-v2
```

`HOLD` (default 30) is how many seconds each client waits for Caddy to close.

The client container opens four connections at once:

| client | sends |
|---|---|
| `no-clienthello` | nothing |
| `partial-clienthello` | the 5-byte header of a handshake record |
| `stall-after-clienthello` | a complete ClientHello, then never answers |
| `complete-handshake` | completes the handshake, then stays quiet (control) |

Every 5 s, a probe in Caddy's network namespace counts the goroutines of the
`tls` handler blocked in the handshake (pprof) and Caddy's sockets on :8443.

## Results

Upstream `master`, route without matchers (`HOLD=20 ./run.sh`):

```
caddy-l4: https://github.com/mholt/caddy-l4 master 42db569 proxy_protocol: Adjust go-proxyproto's internal buffer size (#450) | route matcher: none | handshake_timeout: not set
18:50:56 clients: connecting to caddy:8443, waiting up to 20s each
18:51:16 stall-after-clienthello  STILL OPEN after 20.0s
18:51:16 partial-clienthello      STILL OPEN after 20.0s
18:51:16 no-clienthello           STILL OPEN after 20.0s
18:51:16 complete-handshake       STILL OPEN after 20.0s
18:50:53 probe: goroutines in TLS handshake=0 | Caddy sockets on :8443: none
18:50:58 probe: goroutines in TLS handshake=3 | Caddy sockets on :8443: ESTAB=4
18:51:03 probe: goroutines in TLS handshake=3 | Caddy sockets on :8443: ESTAB=4
18:51:08 probe: goroutines in TLS handshake=3 | Caddy sockets on :8443: ESTAB=4
18:51:13 probe: goroutines in TLS handshake=3 | Caddy sockets on :8443: ESTAB=4
18:51:18 probe: goroutines in TLS handshake=0 | Caddy sockets on :8443: none
```

Upstream `master`, route matched by `tls sni` (`HOLD=20 MATCHER=sni ./run.sh`):

```
caddy-l4: https://github.com/mholt/caddy-l4 master 42db569 proxy_protocol: Adjust go-proxyproto's internal buffer size (#450) | route matcher: sni | handshake_timeout: not set
18:51:35 clients: connecting to caddy:8443, waiting up to 20s each
18:51:38 no-clienthello           closed by Caddy after  3.0s
18:51:38 partial-clienthello      closed by Caddy after  3.0s
18:51:55 stall-after-clienthello  STILL OPEN after 20.0s
18:51:55 complete-handshake       STILL OPEN after 20.0s
18:51:33 probe: goroutines in TLS handshake=0 | Caddy sockets on :8443: none
18:51:38 probe: goroutines in TLS handshake=1 | Caddy sockets on :8443: ESTAB=2 TIME-WAIT=2
18:51:43 probe: goroutines in TLS handshake=1 | Caddy sockets on :8443: ESTAB=2 TIME-WAIT=2
18:51:48 probe: goroutines in TLS handshake=1 | Caddy sockets on :8443: ESTAB=2 TIME-WAIT=2
18:51:53 probe: goroutines in TLS handshake=1 | Caddy sockets on :8443: ESTAB=2 TIME-WAIT=2
```

The branch with `handshake_timeout`, set to 5s, route without matchers
(`HOLD=20 HANDSHAKE_TIMEOUT=5s ./run.sh https://github.com/cruizba/caddy-l4 fix/tls-handshake-timeout-v2`):

```
caddy-l4: https://github.com/cruizba/caddy-l4 fix/tls-handshake-timeout-v2 149daec docs: Document the tls handshake_timeout option | route matcher: none | handshake_timeout: 5s
19:20:16 clients: connecting to caddy:8443, waiting up to 20s each
19:20:21 no-clienthello           closed by Caddy after  5.0s
19:20:21 stall-after-clienthello  closed by Caddy after  5.0s
19:20:21 partial-clienthello      closed by Caddy after  5.0s
19:20:36 complete-handshake       STILL OPEN after 20.0s
19:20:12 probe: goroutines in TLS handshake=0 | Caddy sockets on :8443: none
19:20:17 probe: goroutines in TLS handshake=3 | Caddy sockets on :8443: ESTAB=4
19:20:22 probe: goroutines in TLS handshake=0 | Caddy sockets on :8443: ESTAB=1 TIME-WAIT=3
19:20:27 probe: goroutines in TLS handshake=0 | Caddy sockets on :8443: ESTAB=1 TIME-WAIT=3
19:20:32 probe: goroutines in TLS handshake=0 | Caddy sockets on :8443: ESTAB=1 TIME-WAIT=3
19:20:37 probe: goroutines in TLS handshake=0 | Caddy sockets on :8443: TIME-WAIT=3
19:20:42 probe: goroutines in TLS handshake=0 | Caddy sockets on :8443: TIME-WAIT=3
```

The same branch, route matched by `tls sni`
(`HOLD=20 MATCHER=sni HANDSHAKE_TIMEOUT=5s ./run.sh https://github.com/cruizba/caddy-l4 fix/tls-handshake-timeout-v2`):

```
caddy-l4: https://github.com/cruizba/caddy-l4 fix/tls-handshake-timeout-v2 149daec docs: Document the tls handshake_timeout option | route matcher: sni | handshake_timeout: 5s
19:21:26 clients: connecting to caddy:8443, waiting up to 20s each
19:21:29 partial-clienthello      closed by Caddy after  3.0s
19:21:29 no-clienthello           closed by Caddy after  3.0s
19:21:31 stall-after-clienthello  closed by Caddy after  5.0s
19:21:46 complete-handshake       STILL OPEN after 20.0s
```

Without `handshake_timeout`, the branch behaves like upstream `master`
(`HOLD=20 ./run.sh https://github.com/cruizba/caddy-l4 fix/tls-handshake-timeout-v2`):

```
caddy-l4: https://github.com/cruizba/caddy-l4 fix/tls-handshake-timeout-v2 149daec docs: Document the tls handshake_timeout option | route matcher: none | handshake_timeout: not set
19:21:54 clients: connecting to caddy:8443, waiting up to 20s each
19:22:14 no-clienthello           STILL OPEN after 20.0s
19:22:14 partial-clienthello      STILL OPEN after 20.0s
19:22:14 stall-after-clienthello  STILL OPEN after 20.0s
19:22:14 complete-handshake       STILL OPEN after 20.0s
```

In every run, the `complete-handshake` client stays open: `handshake_timeout`
only bounds the handshake, not the traffic that follows it.
