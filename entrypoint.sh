#!/usr/bin/env bash
# In-VM workload: boot Postgres, run tapes, capture something, drain to $TAPES_OUT.
#
# $TAPES_OUT is a smolvm `:staged` mount. Everything written there is a
# guest-local copy until `smolvm machine sync` or a graceful stop tars it back
# to the host directory. So "drain" here just means "write files to $TAPES_OUT".
set -euo pipefail

OUT="${TAPES_OUT:-/var/tapes/out}"
HOLD="${DEMO_HOLD_SECONDS:-300}"
PG_DSN="postgres://tapes:tapes@127.0.0.1:5432/tapes?sslmode=disable"
mkdir -p "$OUT/sessions"

log() { printf '[smol-tapes %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# ---- 1. Postgres -----------------------------------------------------------
log "starting postgres"
docker-entrypoint.sh postgres >"$OUT/postgres.log" 2>&1 &
PG_PID=$!
for _ in $(seq 1 60); do
  pg_isready -h 127.0.0.1 -U tapes -q && break
  sleep 1
done
pg_isready -h 127.0.0.1 -U tapes -q || { log "postgres never came up"; exit 1; }

# ---- 2. tapes --------------------------------------------------------------
log "starting tapes serve"
tapes serve \
  --postgres "$PG_DSN" \
  --provider "${TAPES_PROVIDER:-anthropic}" \
  --upstream "${TAPES_UPSTREAM:-https://api.anthropic.com}" \
  --proxy-listen :8080 --api-listen :8081 --ingest-listen :8082 \
  --project smol-tapes-demo --disable-telemetry \
  >"$OUT/tapes.log" 2>&1 &
TAPES_PID=$!
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:8081/v1/sessions?limit=1" 2>/dev/null && break
  sleep 1
done
curl -fsS -o /dev/null "http://127.0.0.1:8081/v1/sessions?limit=1" || { log "tapes API never came up"; tail -20 "$OUT/tapes.log"; exit 1; }
log "tapes API up"

# ---- 3. Workload: produce captured sessions ----------------------------------
log "seeding demo sessions"
tapesctl seed --api-url http://127.0.0.1:8081 || log "seed failed (continuing)"

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  # A real call through the in-VM capture proxy. With smolvm --credential the
  # key in this env is a placeholder; the host swaps in the real one only for
  # HTTPS to api.anthropic.com.
  log "calling Anthropic through the tapes proxy"
  curl -sS -m 60 http://127.0.0.1:8080/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":40,"messages":[{"role":"user","content":"Say hi to smolvm in five words."}]}' \
    | tee "$OUT/anthropic-reply.json" | jq -r '.content[0].text // .error.message' || true
  sleep 2
fi

# ---- 4. Drain: tapes -> files on the staged mount ----------------------------
drain() {
  log "draining to $OUT"
  local api=http://127.0.0.1:8081 n=0
  tapesctl sessions list --api-url $api --json --limit 200 \
    > "$OUT/sessions.json" 2>/dev/null || echo '{"items":[]}' > "$OUT/sessions.json"
  # One JSON file per session: the session record, its traces, and every trace's
  # spans. (`tapesctl export` needs an export cassette this deployment does not
  # serve, so this walks the read API instead.)
  for id in $(jq -r '.items[].id' "$OUT/sessions.json"); do
    {
      curl -fsS "$api/v1/sessions/$id"
      tapesctl traces list "$id" --api-url $api --json
      for tid in $(tapesctl traces list "$id" --api-url $api --json | jq -r '.items[].trace_id'); do
        tapesctl traces get "$tid" --api-url $api --json
      done
    } | jq -c . > "$OUT/sessions/$id.jsonl" 2>/dev/null && n=$((n+1))
  done
  pg_dump -h 127.0.0.1 -U tapes tapes | gzip > "$OUT/tapes.sql.gz"
  jq -n --arg at "$(date -u +%FT%TZ)" --argjson n "$n" \
    --arg host "$(hostname)" --arg tapes "$(tapes version | head -1)" \
    '{drained_at:$at, sessions_exported:$n, guest_hostname:$host, tapes:$tapes}' \
    > "$OUT/manifest.json"
  log "drained $n session export(s) + pg_dump"
}
drain

# ---- 5. Hold so the host can pull live, then exit (stop_on_exit halts the VM) --
trap 'log "SIGTERM: final drain"; drain; kill $TAPES_PID $PG_PID 2>/dev/null; exit 0' TERM INT
log "holding ${HOLD}s for live pulls (heartbeat in $OUT/heartbeat)"
for i in $(seq 1 "$HOLD"); do
  date -u +%FT%TZ > "$OUT/heartbeat"
  sleep 1 &
  wait $! || true
done
log "hold over: final drain and exit"
drain
kill $TAPES_PID $PG_PID 2>/dev/null || true
