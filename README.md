# smol-tapes

A proof of concept: run [tapes](https://tapes.dev) (agent telemetry) and its
Postgres database **inside a [smolvm](https://github.com/smol-machines/smolvm)
microVM**, then get the captured data back out two ways:

- **Pull while running** — the in-VM tapes read API is published on a host port,
  and `smolvm machine cp` copies individual files out of the live guest.
- **Drain on shutdown** — the output directory is a smolvm **staged mount**.
  smolvm copies it back to the host on `machine sync` and on every graceful
  stop (including `stop_on_exit`), so the guest's exports land on the host the
  moment the VM powers down.

This validates the hypothesis: *spin up a VM with tapes inside, and have
pullable tapes, or drain on shutdown.*

## How it maps to the hypothesis

| Hypothesis | Mechanism | Where |
|---|---|---|
| tapes inside a VM | OCI image booted as a microVM | `Dockerfile`, `Smolfile` |
| pullable (live) | published port `18081:8081` + `machine cp` | `Smolfile`, `demo.sh` step 4a/4b |
| drain on shutdown | `:staged` volume, synced on graceful stop | `Smolfile`, `demo.sh` step 5 |
| drain on demand | `smolvm machine sync` | `demo.sh` step 4d |

## Layout

- `Dockerfile` — `postgres:16-alpine` + Linux `tapes`/`tapesctl` binaries. Runs
  under plain Docker too; nothing is smolvm-specific.
- `entrypoint.sh` — the in-VM workload: boot Postgres, run `tapes serve`, seed
  demo sessions, optionally make one real Anthropic call through the capture
  proxy, then **drain** (session + trace/span JSON per session, plus a
  `pg_dump`) to `/var/tapes/out`.
- `Smolfile` — declares the machine: image, `net`, the published port, the
  `:staged` output mount, egress allowlist (`api.anthropic.com` only), and
  `stop_on_exit`.
- `demo.sh` — builds the image, boots the VM, pulls live, drains on demand,
  stops, and shows the drained files.

## Run it

Requires `docker`, `smolvm` (`brew install smol-machines/tap/smolvm`), and `jq`.
`ANTHROPIC_API_KEY` is optional — without it the demo still seeds and drains
sessions; with it, one real call is captured.

```bash
./demo.sh
```

Then inspect:

- `out/` — drained on the host: `manifest.json`, `sessions.json`,
  `sessions/<id>.jsonl` (session record + traces + spans), `tapes.sql.gz`.
- `live-pull/` — a file pulled with `machine cp` while the VM was still running.

## What the POC demonstrated

- tapes + Postgres boot and capture inside the microVM.
- The read API is reachable from the host on `:18081` while the VM runs.
- `machine cp` pulls a file out of the live guest.
- The staged mount is **guest-local until synced**: `out/` on the host stays
  empty until `machine sync` or stop — so the drain is explicit, never a
  half-written mid-run copy.
- `machine stop` flushes the staged mount; the host sees a heartbeat written in
  the guest in the VM's final second.
- With `--credential anthropic=ANTHROPIC_API_KEY@api.anthropic.com`, the guest's
  env holds only `SMOL_PLACEHOLDER…`; smolvm substitutes the real key on the
  host, only for HTTPS to the allowed host. The key never enters the VM.

## Known sharp edges

- **tapes is Postgres-only.** The database rides inside the VM. `tapes.sql.gz`
  is a `pg_dump` taken while Postgres runs — consistent. Do **not** instead copy
  Postgres's raw data directory on stop; that would snapshot a torn state.
- **Do not touch the host side of a staged mount while the VM runs.** The guest
  copy is authoritative until a sync; concurrent host writes are lost.
- **The read API serves no `export` cassette** in this build, so the drain walks
  `sessions` → `traces` → `traces get` (spans) rather than `tapesctl export`.
- **`stop_on_exit` fires only on the workload exiting**, not on `machine exec`
  sessions ending. The demo holds the workload open (`DEMO_HOLD_SECONDS`) so you
  can pull live before it self-stops.

## Alternative shape (not built here)

Keep Postgres on the host and run only the agent + tapes proxy in the VM; the
guest reaches host services through the smolvm gateway. That avoids an in-VM
database but gives up the self-contained "tapes travels with the VM" property
this POC is demonstrating.
