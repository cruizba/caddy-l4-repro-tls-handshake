#!/bin/sh
# Every 5 s: goroutines of the tls handler blocked in the TLS handshake (from the
# admin pprof endpoint) and Caddy's sockets on the TLS port, by TCP state.
ADMIN=${ADMIN:-localhost:2019}
PORT=${PORT:-8443}
while true; do
  goroutines=$(curl -s "http://${ADMIN}/debug/pprof/goroutine?debug=2" |
    awk 'BEGIN { RS = "" } /l4tls\.\(\*Handler\)\.Handle/ && /\(\*Conn\)\.Handshake/ { n++ } END { print n + 0 }')
  sockets=$(ss -tnH state connected "( sport = :${PORT} )" | awk '{ print $1 }' | sort | uniq -c |
    awk '{ printf "%s%s=%s", sep, $2, $1; sep = " " }')
  echo "$(date +%T) probe: goroutines in TLS handshake=${goroutines} | Caddy sockets on :${PORT}: ${sockets:-none}"
  sleep 5
done
