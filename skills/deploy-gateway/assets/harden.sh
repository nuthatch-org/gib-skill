#!/usr/bin/env bash
# harden.sh — generalized host hardening for a gib gateway box (from the
# harden-helsinki.sh pattern). Idempotent. ALWAYS --check before --apply.
#
#   ./harden.sh --check                 report drift, change NOTHING
#   ./harden.sh --apply                 UFW -> sshd(key-only) -> fail2ban
#   ./harden.sh --verify-remote <ip>    from ANOTHER host, prove the shield
#
# The primary lock is that gib binds its containers to 127.0.0.1 (see
# --check's loopback section). UFW is the BACKSTOP: Docker publishes container
# ports by inserting iptables rules AHEAD of UFW, so a container published to
# 0.0.0.0 is reachable even under default-deny. Never rely on UFW to fence a
# published Docker port — bind it to loopback.
#
# Allowances: 22/80/443 always (SSH + Caddy). coturn ports are auto-derived if
# /etc/turnserver.conf exists. Other host services already listening on 0.0.0.0
# are LISTED (not auto-allowed) so you decide — pass EXTRA_ALLOW="9000/tcp,..."
# to open them.

set -euo pipefail

MODE="${1:---check}"
PUBIP="${PUBIP:-$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')}"
EXTRA_ALLOW="${EXTRA_ALLOW:-}"
# gib services that MUST be loopback-bound (host publish), not 0.0.0.0.
GIB_LOOPBACK_PORTS="${GIB_LOOPBACK_PORTS:-7700 7610 7301 9090}"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-gib-hardening.conf"
F2B_JAIL="/etc/fail2ban/jail.d/sshd.local"

c_red(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
hdr(){ printf '\n=== %s ===\n' "$*"; }

coturn_facts() {
  CT=""
  local conf=/etc/turnserver.conf
  [ -f "$conf" ] || return 0
  CT_SIG="$(awk -F= '/^listening-port=/{print $2}' "$conf" 2>/dev/null || true)"
  CT_MIN="$(awk -F= '/^min-port=/{print $2}' "$conf" 2>/dev/null || true)"
  CT_MAX="$(awk -F= '/^max-port=/{print $2}' "$conf" 2>/dev/null || true)"
  CT_TLS="$(awk -F= '/^tls-listening-port=/{print $2}' "$conf" 2>/dev/null || true)"
  CT_NOTLS="$(grep -qxE '\s*no-tls\s*' "$conf" 2>/dev/null && echo yes || echo no)"
  CT="present"
}

# Host processes (not docker-proxy) listening on 0.0.0.0/*, excluding 22/80/443.
world_services() {
  ss -tlnp 2>/dev/null | awk '$4 ~ /0\.0\.0\.0|\*|\[::\]/ {print $4"  "$6}' \
    | grep -viE '127\.0\.0\.1|:22 |:80 |:443 ' || true
}

do_check() {
  coturn_facts
  hdr "coturn (auto-derived UFW allowances)"
  if [ -n "$CT" ]; then
    echo "  signalling: ${CT_SIG:-?} (tcp+udp); relay: ${CT_MIN:-?}-${CT_MAX:-?} (udp)"
    if [ -n "${CT_TLS:-}" ] && [ "${CT_NOTLS}" != "yes" ]; then
      c_red "  TLS on ${CT_TLS} set and no-tls absent -> MUST also allow ${CT_TLS}/tcp+udp"
    fi
  else
    echo "  (no /etc/turnserver.conf — no coturn allowances needed)"
  fi

  hdr "UFW"
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    c_grn "  active"; ufw status verbose | sed 's/^/    /'
  else
    c_red "  INACTIVE — INPUT is open. Nothing is fenced at the host level."
  fi

  hdr "sshd"
  sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' && c_grn "  password auth disabled" || c_red "  PASSWORD AUTH ENABLED — key-only not enforced"

  hdr "fail2ban"
  systemctl is-active --quiet fail2ban 2>/dev/null && c_grn "  active" || c_red "  absent/inactive"

  hdr "Host services on 0.0.0.0 (UFW default-deny will block these unless allowed)"
  local ws; ws="$(world_services)"
  [ -n "$ws" ] && echo "$ws" | sed 's/^/    /' || echo "    (none beyond 22/80/443)"

  hdr "gib loopback-bind check (PRIMARY lock — must read 127.0.0.1, NOT 0.0.0.0)"
  local bad=0
  for p in $GIB_LOOPBACK_PORTS; do
    local line; line="$(ss -tlnp 2>/dev/null | awk -v p=":$p\$" '$4 ~ p {print $4}')"
    if [ -z "$line" ]; then echo "    :$p not bound (stack down?)"
    elif echo "$line" | grep -q '0.0.0.0\|\*:'; then c_red "    :$p on $line — EXPOSED past UFW (Docker bypass). Bind 127.0.0.1."; bad=1
    else c_grn "    :$p on $line"; fi
  done
  [ $bad -eq 1 ] && c_red "  ^ fix these in .env (127.0.0.1:PORT) — UFW will NOT protect them."
  printf '\n'; c_ylw "CHECK ONLY — nothing changed. Re-run with --apply to enforce."
}

apply_ufw() {
  coturn_facts
  hdr "UFW"
  if [ -n "${CT_TLS:-}" ] && [ "${CT_NOTLS:-no}" != "yes" ]; then
    c_red "REFUSING: coturn TLS on ${CT_TLS} would be blocked. Add its allow first."; return 1
  fi
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp  comment 'ssh'
  ufw allow 80/tcp  comment 'caddy http (ACME)'
  ufw allow 443/tcp comment 'caddy https'
  if [ -n "$CT" ]; then
    ufw allow "${CT_SIG}/tcp" comment 'coturn'
    ufw allow "${CT_SIG}/udp" comment 'coturn'
    ufw allow "${CT_MIN}:${CT_MAX}/udp" comment 'coturn relay'
  fi
  local IFS=,; for a in $EXTRA_ALLOW; do [ -n "$a" ] && ufw allow "$a" comment 'operator EXTRA_ALLOW'; done
  # NOT opened: gib gateway/aggregator/metrics — they are (and must stay) 127.0.0.1-bound.
  ufw --force enable
  c_grn "UFW enabled. Verify from OUTSIDE: ./harden.sh --verify-remote ${PUBIP:-<ip>}"
}

apply_sshd() {
  hdr "sshd — key-only"
  printf '%s\n' 'PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password' > "$SSHD_DROPIN"
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    c_ylw "  reloaded. KEEP THIS SESSION OPEN and confirm a fresh key login before closing it."
  else
    c_red "  sshd -t FAILED — not reloading. Fix $SSHD_DROPIN."; return 1
  fi
}

apply_fail2ban() {
  hdr "fail2ban"
  command -v fail2ban-client >/dev/null || { apt-get update -qq && apt-get install -y fail2ban; }
  printf '%s\n' '[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h' > "$F2B_JAIL"
  systemctl enable --now fail2ban
  fail2ban-client status sshd 2>/dev/null | sed 's/^/    /' || true
}

do_apply() { apply_ufw; apply_sshd; apply_fail2ban; hdr Done
  c_grn "Applied. Verify from an outside host, then confirm gib ports stayed 127.0.0.1-bound."; }

do_verify_remote() {
  local ip="${2:-$PUBIP}"
  hdr "Shield check against ${ip} (run from OUTSIDE the box)"
  for p in $GIB_LOOPBACK_PORTS; do
    curl -m 3 -s -o /dev/null -w "  tcp $p -> %{http_code} (expect 000/timeout)\n" "http://${ip}:${p}" || echo "  tcp $p -> timed out (good)"
  done
  echo "  [expect OPEN] 443:"; curl -m 5 -s -o /dev/null -w "    https 443 -> %{http_code}\n" "https://${ip}" || echo "    443 -> no answer"
}

case "$MODE" in
  --check)         do_check ;;
  --apply)         do_apply ;;
  --verify-remote) do_verify_remote "$@" ;;
  *) echo "usage: $0 [--check|--apply|--verify-remote <ip>]"; exit 2 ;;
esac
