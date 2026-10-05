#!/usr/bin/env bash
# End-to-end POC: build image -> boot smolvm with tapes inside -> pull live -> drain on stop.
set -euo pipefail
cd "$(dirname "$0")"
NAME="${SMOL_TAPES_NAME:-smol-tapes}"
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "1. Build image and export a docker-save archive for smolvm"
docker build -q -t smol-tapes:latest . >/dev/null
docker save smol-tapes:latest -o build/smol-tapes.tar
ls -lh build/smol-tapes.tar

step "2. Fresh machine from Smolfile (staged mount ./out, port 18081)"
smolvm machine stop --name "$NAME" >/dev/null 2>&1 || true
smolvm machine delete --name "$NAME" >/dev/null 2>&1 || true
rm -rf out live-pull && mkdir -p out live-pull
CRED=()
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  # Guest sees a placeholder; host substitutes the real key only on HTTPS to api.anthropic.com.
  CRED=(--credential anthropic=ANTHROPIC_API_KEY@api.anthropic.com)
fi
smolvm machine create --name "$NAME" -s Smolfile "${CRED[@]}"
smolvm machine start --name "$NAME"

step "3. Wait for the in-VM tapes API on host port 18081"
for _ in $(seq 1 90); do
  curl -fsS -o /dev/null "http://localhost:18081/v1/sessions?limit=1" 2>/dev/null && break
  sleep 2
done
curl -fsS "http://localhost:18081/v1/sessions?limit=1" >/dev/null || { echo "tapes API not reachable"; smolvm machine status --name "$NAME"; exit 1; }
# Give the workload time to seed + drain once.
for _ in $(seq 1 60); do
  smolvm machine exec --name "$NAME" -- test -f /var/tapes/out/manifest.json 2>/dev/null && break
  sleep 2
done

step "4a. PULL (live, over the published port): sessions the in-VM tapes captured"
curl -s "http://localhost:18081/v1/sessions?limit=50" | jq -r '.items[] | "\(.id)  \(.harness_id)  \(.display_title // .name // "-")"'

step "4b. PULL (live, machine cp): grab the in-guest manifest without stopping"
smolvm machine cp "$NAME:/var/tapes/out/manifest.json" live-pull/manifest.json
cat live-pull/manifest.json

step "4c. Staged mount is guest-local until synced: ./out on the host is still empty"
ls -A out || true

step "4d. DRAIN on demand: smolvm machine sync"
smolvm machine sync --name "$NAME"
ls -la out out/sessions | head -20

step "5. DRAIN on shutdown: graceful stop syncs the staged mount again"
rm -f out/heartbeat
smolvm machine stop --name "$NAME"
echo "heartbeat written in-guest right before stop:"; cat out/heartbeat; echo
echo "manifest:"; cat out/manifest.json; echo
echo "exports:"; ls out/sessions | wc -l | xargs echo " session files:"
echo "pg_dump:"; ls -lh out/tapes.sql.gz
smolvm machine status --name "$NAME" || true

step "done. Inspect ./out (drained) and ./live-pull (pulled live)."
