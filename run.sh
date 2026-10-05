#!/usr/bin/env bash
# Builds Caddy with caddy-l4 from a git repository and branch, then shows how long
# the tls handler keeps connections whose TLS handshake never completes.
#
#   ./run.sh                                                         upstream master
#   MATCHER=sni ./run.sh                                             route matched by "tls sni"
#   HANDSHAKE_TIMEOUT=5s ./run.sh https://github.com/cruizba/caddy-l4 fix/tls-handshake-timeout
#
# HOLD (default 30) is how many seconds each client waits for Caddy to close.
set -euo pipefail
cd "$(dirname "$0")"

export CADDY_L4_REPO=${1:-https://github.com/mholt/caddy-l4}
export CADDY_L4_REF=${2:-master}
CADDY_L4_COMMIT=$(git ls-remote "$CADDY_L4_REPO" "refs/heads/$CADDY_L4_REF" | cut -f1)
export CADDY_L4_COMMIT=${CADDY_L4_COMMIT:-unknown}
export MATCHER=${MATCHER:-none}
export HANDSHAKE_TIMEOUT=${HANDSHAKE_TIMEOUT:-}
export HOLD=${HOLD:-30}
export COMPOSE_PROJECT_NAME=caddy-l4-repro-tls-handshake
trap 'docker compose --profile client down -t 1 >/dev/null 2>&1' EXIT

echo ">>> building Caddy with caddy-l4 ${CADDY_L4_REPO} ${CADDY_L4_REF}"
docker compose --profile client build -q
docker compose up -d caddy
until docker compose logs caddy 2>/dev/null | grep -q 'serving initial configuration'; do
  if docker compose ps caddy --status exited | grep -q caddy; then docker compose logs caddy; exit 1; fi
  sleep 0.5
done
# Let Caddy issue the internal certificate before the clients connect.
until docker compose logs caddy 2>/dev/null | grep -q 'certificate obtained successfully'; do sleep 0.5; done
docker compose logs --no-log-prefix caddy | grep '^caddy-l4:'
docker compose up -d probe

docker compose run --rm client
sleep 2
echo ">>> probe (every 5 s, from inside Caddy's network namespace):"
docker compose logs --no-log-prefix probe
