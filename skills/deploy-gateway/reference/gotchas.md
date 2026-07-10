# gib gateway deploy — gotchas & decoded errors

Hard-won lessons from taking gib from zero to a validated, verified-as-shipped gateway. Read
before deploying; consult when something looks wrong. Half of these look like errors and are
not — knowing which is the whole job.

## Canonical addresses — never hand-copy

The Horizon contract addresses (GRT, GraphTallyCollector, PaymentsEscrow, Controller,
SubgraphService, DisputeManager) are pulled from the authoritative `graphprotocol/contracts`
address book by gib's `./scripts/fetch-addresses.sh` into `config/addresses.env`. **Always run
that script; never hand-copy an address** — a wrong verifier or SubgraphService silently breaks
receipt signing (indexers reject with an attestation/verifier error, not an obvious one). For
reference, Arbitrum One GraphTallyCollector is `0x8f69F5C07477Ac46FBc491B1E6D91E2bb0111A9e` — but
verify by running the script, not by trusting this line.

## The 402 is the point, not a bug (decode it)

On a fresh deployment, a paid query to real indexers returns **HTTP 402**, and the gateway's
client-facing response is `bad indexers: {0x…: BadResponse(402), …}`. **This is positive
evidence, never an error to fix.** Decode the indexer's actual message:

```
{"message":"There was an error while accessing escrow account:
            No sender found for signer 0x299A10779ECa64fEBba19839b1AA06c3509D12a3"}
```

This means the indexer **recovered your signer address from the receipt** (so your signing,
EIP-712 domain, and receipt format are all correct) and looked it up — and found no whitelist
entry and no escrow for it. The only thing missing is the onboarding relationship: the indexer
adding your sender to `[tap.sender_aggregator_endpoints]` + you funding escrow. A `200` with data
requires both. Do not "fix" the 402 by touching code — explain it as the expected fresh-deploy
state. (A malformed signature or wrong verifier fails *differently* — a `500` or an attestation
error — so a clean 402 is confirmation, not failure.)

## API keys must be EXACTLY 32 hex chars

`GATEWAY_API_KEYS` (consumer keys) must be exactly 32 hex characters (16 bytes) — generate with
`openssl rand -hex 16`. Any other length returns `{"errors":[{"message":"auth error: malformed
API key"}]}` before routing even happens. `openssl rand -hex 24` (a natural guess) is 48 chars
and **fails**. gib's `.env.example` says `-hex 16`; hold to it.

## Topology has no keyless source — and the two configs that need it differ

- There is **no free, keyless network-subgraph source**. Post-Horizon every real indexer gates
  it behind a TAP receipt (`402 "No Tap receipt was found"`), and `trusted_indexers` needs the
  indexer-service *envelope* (`{graphQLResponse, attestation}`), not raw GraphQL. gib's default is
  the bundled **topology-adapter**: it fronts a **read-only Studio key** and re-wraps the response.
  Sovereign alternatives (self-index; a cooperating indexer's free-serve endpoint) need no key —
  see gib `docs/06-topology.md`.
- **The escrow-manager cannot use the adapter.** It speaks *raw* GraphQL and dies on the envelope
  with `Error: fetch authorized signers / Caused by: Empty response`. The gateway wants the
  envelope; the escrow-manager wants raw. They need **different** network-subgraph sources. gib
  ships the escrow-manager as `--profile escrow` (Stage-2 opt-in) precisely so a Stage-1 deploy
  doesn't crash-loop it. **If the user has Stage-2 ambitions, the adapter is not enough** — they
  need a raw source (keyed decentralised-gateway URL directly, or a self-hosted graph-node) for
  the escrow-manager. Say this during the interview, not after.

## GRAPH_TALLY_PUBLIC_KEYS — the silent-rejection trap

The tap-aggregator **always** accepts receipts signed by its own wallet (`GRAPH_TALLY_PRIVATE_KEY`,
which in gib is the same `SIGNER_KEY` the gateway signs with) — so the default self-deal loop works
with nothing extra set. **But the moment you rotate the signer, run a second gateway with a
different signer, or accept another sender's receipts, the aggregator SILENTLY REJECTS those
receipts** (`code -32002 "Recovered sender address invalid 0x…"`) unless that signer's *address* is
listed in `GRAPH_TALLY_PUBLIC_KEYS` (comma-separated addresses, not keys). It is a latent trap: the
default works, then a rotation breaks aggregation with a cryptic error. Set it proactively if
signers will ever diverge.

## Topology polling burns Studio quota (do the math)

A running gateway polls the network subgraph roughly **every 30 seconds** — that's ~2 queries/min
≈ **~86,400 queries/month**, against The Graph Studio **free tier of 100k/month**. A single
always-idle gateway nearly exhausts the free tier on topology polling alone. Tell the user: stop
the stack when not in use, or budget a paid Studio plan for an always-on gateway. This is the
main running cost of the Studio-key topology path.

## Docker publishes ports PAST UFW — loopback bind is the real lock

`ufw` filters the host's INPUT chain, but Docker inserts its own iptables rules ahead of UFW for
**published** container ports — so a container published to `0.0.0.0:PORT` is reachable from the
internet **even with UFW default-deny**. UFW does NOT protect published Docker ports. The real
lock is binding to `127.0.0.1` in compose (`127.0.0.1:PORT:PORT`). gib binds the gateway and
aggregator to loopback and fronts them with the host's Caddy; the aggregator is the one endpoint
that must be public, and it's exposed *through Caddy TLS*, not by a raw `0.0.0.0` publish. When
hardening: UFW is the backstop, the loopback bind is primary — verify both.

## The startup-ordering warning is benign and self-heals

On first boot you may see, once, in the gateway log:
`network_subgraph_query_err="BadResponse(failed to connect)"` / `trusted indexers exhausted`.
That's the gateway querying the topology-adapter a beat before the adapter is listening. gib's
compose now gates the gateway on `depends_on: {topology-adapter: service_healthy}`, so this is
rare — but if it appears, it **self-recovers within ~30s** (the gateway retries on its poll loop).
Not an error to act on. Topology is loaded once you see `subgraphs=… deployments=… indexings=…`.

## Measured footprint (measurement, not estimate)

Measured on Arbitrum One with the full network topology resident (~16k subgraphs): **gateway
~207 MB RSS**, redpanda ~330 MB, aggregator ~10 MB, adapter ~25 MB — **whole stack ~570 MB**. It
runs comfortably on a **2 GB / 1 vCPU box**. Do not repeat the old "2–4 GB for in-memory topology"
estimate; it was ~20× pessimistic. Cite these as measurements.

## Images: pull, don't build; pin the tag

Deploy from the **published GHCR image at gib's pinned release tag** (`GATEWAY_IMAGE_TAG` in
`.env.example` is pinned to an immutable `sha-<commit>` tag, not floating `latest`). A native
`docker build` on the box works but is slow and unnecessary — and it hides whether the shipped
image actually runs. `docker compose pull` is the operator path. The GHCR package is public;
unauthenticated pull works (`docker logout ghcr.io` to confirm).

## Boundary — what gib proves vs what it doesn't

gib verifies the payment path **up to a signed, verified RAV**: topology sync, the running gateway
signing with the configured signer, receipts aggregating into a RAV that recovers to that signer
with the right domain and value, and rejection of tampered/wrong-key receipts (that's what
`gib smoke` checks). It does **not** touch the chain: on-chain RAV redemption, escrow funding, and
indexer whitelisting are cooperation- and money-dependent and are **not** exercised. No payment has
ever flowed through gib. State this at handoff — never imply payments work.
