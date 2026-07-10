# gib-skill

> Sibling to [lodestone](https://github.com/lodestar-team/lodestone): lodestone *forges* Graph
> Horizon data services; this *deploys* the gateways.

A Claude Code plugin — the **concierge for standing up a Graph Horizon subgraph gateway**. It sits
on top of [gib](https://github.com/lodestar-team/gib) (which stays closed and neutral) and adds the
judgment gib's scripts can't: it interviews you, hardens the box if it's shared, deploys gib at its
pinned release, and validates the whole payment path end-to-end with `gib smoke` — then hands off
with exactly what's proven and what still needs escrow and indexer onboarding.

**It is not a generator.** gib's own `scripts/` and `docker compose` do the mechanics. This is the
interview + hardening + interpretation layer.

## The flow

1. **Interview** (~8 questions) — target box (fresh vs shared), the two vhost domains, topology
   source (Studio key vs sovereign, with the tradeoff), consumer key count, `query_fees_target`,
   Stage 1 vs Stage 2 ambitions, monitoring.
2. **Harden** (shared box, or on request) — generalized UFW default-deny with auto-derived service
   allowances, key-only SSH, fail2ban, and loopback-bind verification. `--check` before `--apply`,
   always. Teaches the Docker-bypasses-UFW fact and enforces `127.0.0.1` bindings as the real lock.
3. **Deploy** — clone gib at the pinned release tag, fill `.env` from the interview, run gib's
   `fetch-addresses` / `gen-keys` / `render`, `compose pull` the published images, bring it up.
4. **Validate** — run `gib smoke`, parse the check table, and *interpret* it: each check maps to a
   plain meaning, each failure to a diagnosis. A 402 from real indexers is explained as **positive
   evidence** (signer recovered, escrow absent), never as an error.
5. **Hand off** — what was proven, what remains (escrow funding, indexer whitelisting), where the
   keys live, and the topology-key quota note.

## Key hygiene (non-negotiable)

Sender/signer **private keys are generated on the box and never leave it** — the skill refuses to
print a private key into the transcript and says why (a signing key in a chat log is a leaked key).
The only key allowed through chat is the **read-only topology (Studio) key**, which signs nothing
and holds no funds — and even that comes with a rotation note.

## Prerequisites

- **[Claude Code](https://claude.com/claude-code)** — to run the skill.
- **A target box** with Docker + Docker Compose, reachable over SSH (a fresh Hetzner/VPS is ideal;
  a shared box triggers the hardening path).
- **A read-only Studio key** from [thegraph.com](https://thegraph.com) Studio for the default
  topology path (or a sovereign source — see gib `docs/06-topology.md`).
- Domain names for the gateway and aggregator vhosts, and a TLS reverse proxy (Caddy) on the box.

The skill never invents or displays a private key; gib generates them on the box.

## Usage

Invoke in Claude Code:

```
/deploy-gateway
```

…or just ask: *"deploy a gib gateway on my box"*. The skill interviews you, hardens if needed,
drives gib's scripts, and validates with `gib smoke`.

## Layout

```
.claude-plugin/plugin.json
skills/deploy-gateway/
  SKILL.md                  the interview → harden → deploy → validate → handoff flow
  reference/gotchas.md      decoded errors + scar tissue (the 402, the PUBLIC_KEYS trap, quota math, …)
  assets/harden.sh          generalized host hardening (--check / --apply / --verify-remote)
```

## Install

```
/plugin marketplace add lodestar-team/gib-skill
/plugin install gib-skill
```

Or point Claude Code at a local clone for development.

## Boundary

This skill takes a gateway to a **verified signed RAV** and no further. On-chain RAV redemption,
escrow funding, and indexer whitelisting are cooperation- and money-dependent and are **not**
performed. No payment flows through a gib deployment; a fresh gateway returns `402` to paid queries
by design until an operator funds escrow and indexers whitelist the sender. The skill states this at
handoff and never implies payments work.

Apache-2.0. Experimental community tooling; not affiliated with The Graph Foundation.
