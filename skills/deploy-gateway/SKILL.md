---
name: deploy-gateway
description: Deploy and validate a Graph Horizon subgraph gateway with gib (github.com/nuthatch-org/gib). Use when the user wants to stand up / deploy / launch a Graph gateway, a gib gateway, a self-hosted subgraph gateway on Arbitrum One, run their own query gateway, or asks to "deploy gib". This is the concierge: it interviews, hardens the box, deploys gib at its pinned release, and validates the payment path end-to-end with `gib smoke` — it does NOT reimplement gib's mechanics.
---

# Deploy a gib gateway

You are the concierge for standing up a Graph Horizon subgraph gateway. The mechanics live in
[gib](https://github.com/nuthatch-org/gib) — its `scripts/` and `docker compose` do the work.
**Your job is judgment**: interview the operator, harden the box if it's shared, drive gib's own
scripts to deploy, then run `gib smoke` and *interpret* it. You do not generate or hand-roll the
stack.

**Read `reference/gotchas.md` before you start, and keep it open.** Half of what looks like an
error here is expected (the 402 especially). That file is how you tell the difference.

**Non-negotiable key hygiene** (read this before touching any key):
- The **sender and signer private keys are generated on the target box** by `gib`'s `gen-keys.sh`
  and **never leave it**. Do not print, echo, cat, or paste a private key into the conversation —
  not to "confirm" it, not in a log. If asked to show one, **refuse and say why**: a signing key in
  a transcript is a leaked key. You only ever handle the **public sender address**.
- The **read-only topology (Studio) key is the ONLY key allowed through chat** — it signs nothing
  and holds no funds. Even so, note the rotation habit: it can be rotated in Studio any time, and
  should be after it's been pasted anywhere.
- If you generate anything on the box, keep it on the box (`secrets/`, mode 600, gitignored).

## Step 1 — Interview (~8 questions)

Ask these (use the AskUserQuestion tool; offer the defaults and reasoning, let them override).
Infer what you safely can from the user's brief; only ask what you can't.

| # | Question | Why it matters / default |
|---|---|---|
| 1 | **Target box** — fresh & dedicated, or shared with other services? (and how you reach it: SSH host/IP + key) | A **shared** box triggers the hardening path (Step 2). A fresh dedicated box is the gold standard for a fund-handling service; a shared box is fine for a proof but must be hardened and isolated. |
| 2 | **Two vhost domains** — one for the gateway (`gw.`), one for the aggregator (`agg.`) | The aggregator MUST be internet-reachable by indexers via a stable DNS name (not a bare IP). The gateway is your query endpoint. Both are fronted by Caddy TLS; the containers stay loopback-bound. |
| 3 | **Topology source** — bundled adapter + a read-only Studio key (default), or sovereign (self-index / cooperating indexer)? | There is **no keyless source** (gotchas). The adapter is the pragmatic default: fast, needs a read-only Studio key. Sovereign paths need no key but are heavier (self-index) or need a relationship (cooperating indexer). Explain the tradeoff from gib `docs/06-topology.md`. |
| 4 | **Consumer API key count** — how many `GATEWAY_API_KEYS` to mint? | These are the keys your users present (`Authorization: Bearer`). Each is `openssl rand -hex 16` (EXACTLY 32 hex — gotchas). Default: 1. |
| 5 | **`query_fees_target`** — target fee paid to indexers per query, in USD | gib default **`20e-6`** ($0.00002/query). It bounds what the gateway will pay per indexer request. Offer the default with this reasoning; let them raise it (favour more indexers / better QoS) or lower it. |
| 6 | **Stage 1 only, or Stage-2 ambitions?** | **Stage 1** (default): serve + sign, no funds, no escrow — what `gib smoke` proves. **Stage 2** (real payments) needs escrow funding AND changes topology advice: the escrow-manager **cannot use the adapter envelope** — it needs a *raw* network-subgraph source. Flag this now, not after (gotchas). |
| 7 | **Monitoring?** — bring up the Prometheus/Grafana profile? | Optional `monitoring` compose profile: escrow/query dashboards. Default: no for a proof, yes for anything you'll watch. |

Confirm the answers back before proceeding. If the box is shared → Step 2. If fresh/dedicated and
the user still wants hardening → Step 2 (recommended regardless). Otherwise → Step 3.

## Step 2 — Harden (shared box, or on request)

Copy `assets/harden.sh` to the box and run it. **`--check` first, always** — never `--apply`
blind.

```bash
scp assets/harden.sh <box>:/root/harden.sh
ssh <box> 'bash /root/harden.sh --check'      # report drift, change nothing
```

Read the drift report to the user. Then apply, and — critically — **keep a second SSH session
open across the sshd reload** so a bad config can't lock everyone out:

```bash
ssh <box> 'bash /root/harden.sh --apply'
ssh <box> 'true'                              # prove key login still works BEFORE trusting it
```

Then verify the shield **from a different host** (the box can't test its own firewall honestly):

```bash
ssh <other-box> "bash harden.sh --verify-remote <box-ip>"
```

Teach the operator the load-bearing fact while you do it: **Docker publishes container ports past
UFW.** UFW is the backstop; the real lock is that gib binds the gateway/aggregator to `127.0.0.1`.
The `--check` output's loopback section flags any gib port that's on `0.0.0.0` — if it is, fix
`.env` (`127.0.0.1:PORT`) before going further. UFW will not protect a published Docker port.

## Step 3 — Deploy (gib's own scripts do the work)

Clone gib **at its pinned release tag** (not `main`), then follow its runbook with the interview
answers. Resolve the tag robustly — `git ls-remote --tags | tail` returns the peeled annotated-tag
ref `vX.Y.Z^{}`, which is **not** cloneable; use `--refs` (or `gh release view`):

```bash
TAG=$(git ls-remote --tags --refs https://github.com/nuthatch-org/gib 'v*' | sed 's#.*/##' | sort -V | tail -1)
git clone --branch "$TAG" https://github.com/nuthatch-org/gib && cd gib   # detached HEAD at the tag — expected
cp .env.example .env
```

Fill `.env` from the interview: `SENDER_ADDRESS` (from Step 3's key gen, below),
`TOPOLOGY_STUDIO_KEY` (the read-only key), `GATEWAY_API_KEYS` (`openssl rand -hex 16` × the count),
`QUERY_FEES_TARGET`, the Caddy vhost hostnames, and keep gateway/aggregator ports **loopback**
(`GATEWAY_PORT=127.0.0.1:7700`, `AGGREGATOR_PORT=127.0.0.1:7610`). **On a shared box, first check
those host ports are free** (`ss -tlnp | grep -E ':(7700|7610) '`); if taken, pick free loopback
ports (e.g. `127.0.0.1:17700`) — `gib smoke` reaches the containers by name on the compose network,
so the host port choice doesn't affect validation. Then:

```bash
./scripts/fetch-addresses.sh     # canonical Horizon addresses — NEVER hand-copy (gotchas)
./scripts/gen-keys.sh            # sender + signer keys, ON THE BOX, mode 600. Uses cast, or
                                 # falls back to the Foundry Docker image. Read ONLY the
                                 # public sender Address from its output into SENDER_ADDRESS.
./scripts/render.sh              # -> runtime/{gateway.json, escrow-manager.json, .env}
docker compose --env-file runtime/.env pull   # published images (public GHCR), not a native build
docker compose --env-file runtime/.env up -d  # Stage 1: gateway + redpanda + tap-aggregator + adapter
```

- **Do not** start the escrow-manager for Stage 1 — it is `--profile escrow` and only matters when
  funding escrow (and needs a raw topology source; gotchas).
- Add `--profile monitoring` to `up` if they chose monitoring.
- Front `gw.`/`agg.` with the box's Caddy (reverse_proxy to the loopback ports). If Caddy isn't
  present, that's part of setup — the aggregator must be reachable by indexers over TLS.
- Watch for healthy: topology is loaded once the gateway logs
  `subgraphs=… deployments=… indexings=…` (strip ANSI to grep it). The one-time
  `trusted indexers exhausted` warning at boot is benign and self-heals (gotchas).

## Step 4 — Validate with `gib smoke`, and INTERPRET

Run gib's own self-test against the running deployment:

```bash
docker compose --env-file runtime/.env --profile smoke run --rm smoke
```

Parse the table and translate every line into plain meaning. Report per check:

| Check | Plain meaning | If it FAILS — diagnosis |
|---|---|---|
| (a) topology sync | The gateway loaded the network subgraph; indexer/subgraph counts are sane | Adapter unhealthy (no/invalid Studio key), or quota exhausted. Check adapter `/health` and the key. |
| (b) query dispatched | A real query selected candidate indexers and attached signed receipts | Topology empty, or no indexers serve the test subgraph. Try a well-indexed subgraph. |
| (c) runtime signer | The **running** gateway signed with your configured signer (read from its own Kafka record) | Signer mismatch = `.env`/render drift. Re-render; confirm `receipts.signer`. |
| (d) RAV recovers / domain / value | Receipts aggregate into a RAV that recovers to your signer, right EIP-712 domain, `value == Σ` | Domain mismatch = wrong `CHAIN_ID`/verifier; re-run `fetch-addresses.sh`. |
| (e) RAV payer / dataService | RAV fields match your configured sender + SubgraphService | Config drift; re-render. |
| (f) negative tests | Tampered and wrong-key receipts are **rejected** | If a bad receipt is ACCEPTED, stop — aggregator misconfigured. |

`RESULT: PASS` from a fresh deploy is the acceptance bar. **A 402 you see when you send a real
query yourself is NOT a smoke failure — it is positive evidence** (the indexer recovered your
signer; only escrow/whitelist is missing). Decode "No sender found for signer 0x…" from
`reference/gotchas.md`; never present it as an error to fix.

## Step 5 — Hand off

Tell the operator, plainly:
- **What is proven:** everything `gib smoke` just passed — topology, the running gateway signing
  with their signer, receipt→RAV aggregation with correct domain/value, negative-test rejection.
  Up to a *verified signed RAV*.
- **What remains — and is cooperation/money-dependent, not a gib gap:** funding escrow, and
  getting indexers to whitelist their sender. Link gib's onboarding section
  ([Getting indexers to accept your gateway](https://github.com/nuthatch-org/gib#getting-indexers-to-accept-your-gateway))
  and, for Stage 2, gib `docs/02-onchain-escrow.md`. **No payment has flowed; no paid query has
  returned data** (a 402 is expected until onboarding). Do not imply otherwise.
- **Where the keys live:** `secrets/{sender,signer}.txt` on the box, mode 600, gitignored — never
  in the transcript. The sender address is public; the private keys stay on the box. Back them up
  off-box securely.
- **The quota note:** a running gateway polls the network subgraph ~every 30s ≈ ~86k queries/month
  against the Studio 100k free tier — stop the stack when idle, or budget a paid plan for always-on.
  Rotate the Studio key when convenient.

Report honestly. If a smoke check failed, say so with the output and the diagnosis — do not hand
back a "done" that isn't.
