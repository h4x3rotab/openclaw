#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHANNEL="${1:-}"
SESSION_KEY="${2:-}"
TTL_SEC="${TTL_SEC:-900}"
INBOUND_TIMEOUT_MS="${INBOUND_TIMEOUT_MS:-15000}"

MUX_CVM_ID="${PHALA_MUX_CVM_ID:-}"
OPENCLAW_CVM_ID="${PHALA_OPENCLAW_CVM_ID:-}"
MUX_BASE_URL="${PHALA_MUX_BASE_URL:-}"
OPENCLAW_INBOUND_URL="${PHALA_OPENCLAW_INBOUND_URL:-}"
OPENCLAW_ID="${OPENCLAW_ID:-}"

log() {
  printf '[mux-pair-token] %s\n' "$*"
}

die() {
  printf '[mux-pair-token] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") <telegram|discord|whatsapp> [sessionKey]

Environment:
  MUX_REGISTER_KEY            (required) shared key for POST /v1/instances/register
  PHALA_MUX_CVM_ID            (optional) mux CVM UUID (used to derive mux base URL)
  PHALA_OPENCLAW_CVM_ID       (optional) OpenClaw CVM UUID (used to derive inbound URL)
  PHALA_MUX_BASE_URL          (optional) mux base URL override (example: https://<app>-18891.<gateway>)
  PHALA_OPENCLAW_INBOUND_URL  (optional) OpenClaw inbound URL override (example: https://<app>-18789.<gateway>/v1/mux/inbound)
  CVM_SSH_HOST                (optional) OpenClaw container SSH host for auto-resolving OPENCLAW_ID (see phala-deploy/cvm-exec)
  OPENCLAW_ID                 (optional) OpenClaw instance id override (defaults to device identity from device.json)
  TTL_SEC                     (optional) pairing token TTL seconds (default: 900)
  INBOUND_TIMEOUT_MS          (optional) mux -> OpenClaw inbound timeout in ms (default: 15000)

Notes:
  - This is instance-centric: OpenClaw "registers itself" by calling POST /v1/instances/register.
  - We call register here only to mint a short-lived runtime JWT for calling POST /v1/pairings/token.
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

resolve_base_from_cvm() {
  local cvm_id="$1"
  local port_suffix="$2"
  local json app_id base_domain
  json="$(phala cvms get "$cvm_id" --json)"
  app_id="$(printf '%s' "$json" | jq -r '.app_id // empty')"
  base_domain="$(printf '%s' "$json" | jq -r '.gateway.base_domain // empty')"
  [[ -n "$app_id" && -n "$base_domain" ]] || die "failed to resolve app_id/base_domain for CVM ${cvm_id}"
  printf 'https://%s-%s.%s' "$app_id" "$port_suffix" "$base_domain"
}

resolve_openclaw_id_from_ssh() {
  require_cmd jq
  [[ -n "${CVM_SSH_HOST:-}" ]] || die "set OPENCLAW_ID or CVM_SSH_HOST to auto-resolve instance id"
  "${SCRIPT_DIR}/cvm-exec" 'cat /root/.openclaw/identity/device.json' \
    | jq -r '.deviceId // empty' \
    | tr -d '[:space:]'
}

if [[ -z "$CHANNEL" || "$CHANNEL" == "-h" || "$CHANNEL" == "--help" ]]; then
  usage
  exit 1
fi

[[ "$TTL_SEC" =~ ^[0-9]+$ ]] || die "TTL_SEC must be a positive integer"
[[ "$INBOUND_TIMEOUT_MS" =~ ^[0-9]+$ ]] || die "INBOUND_TIMEOUT_MS must be a positive integer"

require_cmd curl
require_cmd jq

: "${MUX_REGISTER_KEY:?set MUX_REGISTER_KEY}"

if [[ -z "$MUX_BASE_URL" ]]; then
  require_cmd phala
  [[ -n "$MUX_CVM_ID" ]] || die "set PHALA_MUX_BASE_URL or PHALA_MUX_CVM_ID"
  MUX_BASE_URL="$(resolve_base_from_cvm "$MUX_CVM_ID" "18891")"
fi

if [[ -z "$OPENCLAW_INBOUND_URL" ]]; then
  require_cmd phala
  [[ -n "$OPENCLAW_CVM_ID" ]] || die "set PHALA_OPENCLAW_INBOUND_URL or PHALA_OPENCLAW_CVM_ID"
  OPENCLAW_INBOUND_URL="$(resolve_base_from_cvm "$OPENCLAW_CVM_ID" "18789")/v1/mux/inbound"
fi

if [[ -z "$OPENCLAW_ID" ]]; then
  OPENCLAW_ID="$(resolve_openclaw_id_from_ssh)"
fi
[[ -n "$OPENCLAW_ID" ]] || die "failed to resolve OPENCLAW_ID"

log "mux base URL: $MUX_BASE_URL"
log "openclaw inbound URL: $OPENCLAW_INBOUND_URL"
log "openclaw id: $OPENCLAW_ID"

register_payload="$(jq -nc \
  --arg openclawId "$OPENCLAW_ID" \
  --arg inboundUrl "$OPENCLAW_INBOUND_URL" \
  --argjson inboundTimeoutMs "$INBOUND_TIMEOUT_MS" \
  '{openclawId:$openclawId,inboundUrl:$inboundUrl,inboundTimeoutMs:$inboundTimeoutMs}')"

register_response="$(curl -fsS -X POST "$MUX_BASE_URL/v1/instances/register" \
  -H "Authorization: Bearer $MUX_REGISTER_KEY" \
  -H "Content-Type: application/json" \
  --data "$register_payload")"

runtime_token="$(printf '%s' "$register_response" | jq -r '.runtimeToken // empty')"
if [[ -z "$runtime_token" || "$(printf '%s' "$register_response" | jq -r '.ok // false')" != "true" ]]; then
  printf '%s\n' "$register_response" | jq . >&2 || true
  die "instance register failed"
fi

pair_payload="$(jq -nc \
  --arg channel "$CHANNEL" \
  --arg sessionKey "$SESSION_KEY" \
  --argjson ttlSec "$TTL_SEC" \
  '{channel:$channel,ttlSec:$ttlSec}
   + (if $sessionKey == "" then {} else {sessionKey:$sessionKey} end)')"

pair_response="$(curl -fsS -X POST "$MUX_BASE_URL/v1/pairings/token" \
  -H "Authorization: Bearer $runtime_token" \
  -H "X-OpenClaw-Id: $OPENCLAW_ID" \
  -H "Content-Type: application/json" \
  --data "$pair_payload")"

printf '%s\n' "$pair_response" | jq .

token="$(printf '%s' "$pair_response" | jq -r '.token // empty')"
if [[ -n "$token" ]]; then
  log "token: $token"
fi
