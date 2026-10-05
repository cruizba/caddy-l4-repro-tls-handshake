#!/bin/sh
# Writes the Caddy config and runs Caddy: a layer4 server on :8443 whose route
# terminates TLS (certificate for "localhost" from Caddy's internal CA) and echoes.
# MATCHER=none gives the route no matchers; MATCHER=sni matches it with
# "tls sni localhost". HANDSHAKE_TIMEOUT adds the tls handler's handshake_timeout
# option, which only exists in builds that implement it.
set -e
CONFIG=${CONFIG:-/etc/caddy.json}
MATCHER=${MATCHER:-none}
timeout_field=""
[ -n "${HANDSHAKE_TIMEOUT:-}" ] && timeout_field=", \"handshake_timeout\": \"${HANDSHAKE_TIMEOUT}\""
match_field=""
[ "$MATCHER" = sni ] && match_field="\"match\": [{\"tls\": {\"sni\": [\"localhost\"]}}],"
cat >"$CONFIG" <<EOF
{
  "admin": {"listen": "${ADMIN:-localhost:2019}"},
  "logging": {"logs": {"default": {"level": "DEBUG"}}},
  "apps": {
    "tls": {
      "certificates": {"automate": ["localhost"]},
      "automation": {"policies": [{"subjects": ["localhost"], "issuers": [{"module": "internal"}]}]}
    },
    "layer4": {
      "servers": {
        "tls": {
          "listen": ["${LISTEN:-:8443}"],
          "routes": [
            {${match_field} "handle": [{"handler": "tls"${timeout_field}}, {"handler": "echo"}]}
          ]
        }
      }
    }
  }
}
EOF
echo "caddy-l4: ${CADDY_L4_VERSION:-$(cat /caddy-l4-version 2>/dev/null || echo unknown)} | route matcher: ${MATCHER} | handshake_timeout: ${HANDSHAKE_TIMEOUT:-not set}"
exec "${CADDY:-caddy}" run --config "$CONFIG"
