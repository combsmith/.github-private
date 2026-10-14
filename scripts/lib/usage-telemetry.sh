# shellcheck shell=bash
# scripts/lib/usage-telemetry.sh — Private transport adapter for the Claude
# subscription OAuth usage endpoint (#1565).
#
# This library owns exactly one thing: the HTTP call to
#   GET https://api.anthropic.com/api/oauth/usage
# and the normalized TRANSPORT ENVELOPE the shipped public token-budget breaker
# (petry-projects/.github `scripts/lib/agent-rate-limit.sh`) already consumes via
# its adapter seam:
#
#   { "status": <http_status>, "retry_after": <int?>, "observed_at": <epoch?>, "body": <raw upstream> }
#
# The envelope is a TRANSPORT wrapper, not a normalization: `body` carries the
# upstream response UNMODIFIED. Field extraction (percent, resets_at, is_active,
# limits[] vs. flattened five_hour/seven_day) belongs to the public library's own
# arl_token_extract_* helpers. Re-parsing the body here would create a second,
# drifting parser — the exact failure model-pricing.tsv exists to prevent.
#
# ----------------------------------------------------------------------------
# Caller contract
# ----------------------------------------------------------------------------
# Sourced by a parent script (`# shellcheck source=scripts/lib/usage-telemetry.sh`).
# It is `set -euo pipefail`-safe, calls `set` on nothing, and runs nothing at
# source time. Reads (all optional, with defaults):
#   - $CLAUDE_CODE_OAUTH_TOKEN  — the OAuth bearer token; unset => status=0
#                                 envelope (degraded; the library fails safe to
#                                 allow, never a hard failure).
#   - $CLAUDE_CODE_VERSION      — pins the User-Agent version; else derived from
#                                 the `claude` CLI, else "unknown".
#   - $USAGE_TELEMETRY_ENDPOINT — override the usage URL (testability).
#   - $USAGE_TELEMETRY_BETA     — the anthropic-beta value (default oauth-2025-04-20).
#   - $USAGE_TELEMETRY_TIMEOUT  — curl --max-time seconds (default 10).
#   - $USAGE_TELEMETRY_CURL     — the curl binary/shim (default `curl`; tests mock it).
#   - $USAGE_TELEMETRY_NOW      — epoch override for observed_at (testability).
#
# Fail-safe direction (ADR §7): any non-200, transport error, malformed body, or
# missing token yields an envelope the public library reads as allow-with-warning.
# The one blocking signal — a fresh 429 with a positive retry-after — is expressed
# by populating `status`, `retry_after`, and `observed_at`; the library's
# arl_token_transport_decision turns that into a defer.

USAGE_TELEMETRY_ENDPOINT="${USAGE_TELEMETRY_ENDPOINT:-https://api.anthropic.com/api/oauth/usage}"
USAGE_TELEMETRY_BETA="${USAGE_TELEMETRY_BETA:-oauth-2025-04-20}"

# ---------------------------------------------------------------------------
# usage_telemetry_log <msg> — human-readable reasoning to stderr so a caller can
# capture the machine-readable envelope on stdout uncluttered.
# ---------------------------------------------------------------------------
usage_telemetry_log() { printf 'usage-telemetry: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# usage_telemetry_now — current epoch seconds, honoring $USAGE_TELEMETRY_NOW.
# ---------------------------------------------------------------------------
usage_telemetry_now() {
  if [ -n "${USAGE_TELEMETRY_NOW:-}" ]; then
    printf '%s' "$USAGE_TELEMETRY_NOW"
    return 0
  fi
  date +%s
}

# ---------------------------------------------------------------------------
# usage_telemetry_int <value> [default] — echo <value> when it is a non-negative
# integer, else <default> (default 0). The fail-safe integer idiom.
# ---------------------------------------------------------------------------
usage_telemetry_int() {
  local value="${1:-}" fallback="${2:-0}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

# ---------------------------------------------------------------------------
# usage_telemetry_user_agent — resolve the load-bearing `claude-code/<version>`
# User-Agent. Omitting it hits an aggressively rate-limited bucket and returns
# persistent 429s (issue Scope §1), so a version is always produced ("unknown"
# as a last resort rather than an empty UA).
# ---------------------------------------------------------------------------
usage_telemetry_user_agent() {
  local ver=""
  if [ -n "${CLAUDE_CODE_VERSION:-}" ]; then
    ver="$CLAUDE_CODE_VERSION"
  elif command -v claude >/dev/null 2>&1; then
    ver="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || printf '')"
  fi
  [ -z "$ver" ] && ver="unknown"
  printf 'claude-code/%s' "$ver"
}

# ---------------------------------------------------------------------------
# usage_telemetry_retry_after <header_file> — echo the integer Retry-After header
# value (seconds) from a curl `-D` header dump, or empty when absent/non-integer.
# ---------------------------------------------------------------------------
usage_telemetry_retry_after() {
  local hdrfile="${1:-}" now_epoch="${2:-}" value target
  [ -n "$hdrfile" ] && [ -f "$hdrfile" ] || return 0
  value="$(grep -i '^retry-after:' "$hdrfile" 2>/dev/null | head -n1 \
    | cut -d: -f2- | tr -d '[:space:]\r' || printf '')"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi
  # RFC 9110 also allows an HTTP-date; convert to delta seconds (GNU, then BSD date).
  value="$(grep -i '^retry-after:' "$hdrfile" 2>/dev/null | head -n1 \
    | cut -d: -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || printf '')"
  [ -n "$value" ] || return 0
  target="$(date -u -d "$value" +%s 2>/dev/null \
    || date -u -j -f '%a, %d %b %Y %H:%M:%S GMT' "$value" +%s 2>/dev/null || printf '')"
  [[ "$target" =~ ^[0-9]+$ ]] || return 0
  [ -n "$now_epoch" ] || now_epoch="$(usage_telemetry_now)"
  if [ "$target" -gt "$now_epoch" ]; then
    printf '%s' "$((target - now_epoch))"
  fi
}

# ---------------------------------------------------------------------------
# usage_telemetry_envelope <status> <retry_after> <observed_at> <body_raw> —
# assemble the normalized envelope JSON. `retry_after` and `body_raw` are omitted
# when empty / non-integer / not valid JSON (the library reads `.retry_after?`
# and `.body? // {}`, so an absent key is the safe default). The body is embedded
# UNMODIFIED when it parses as JSON.
# ---------------------------------------------------------------------------
usage_telemetry_envelope() {
  local status="$1" retry_after="$2" observed_at="$3" body_raw="$4"
  local -a args=(--argjson status "$(usage_telemetry_int "$status" 0)")
  local filter='{status: $status}'

  if [ -n "$observed_at" ]; then
    args+=(--argjson observed_at "$(usage_telemetry_int "$observed_at" 0)")
    filter+=' | .observed_at = $observed_at'
  fi
  if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
    args+=(--argjson retry_after "$retry_after")
    filter+=' | .retry_after = $retry_after'
  fi
  if [ -n "$body_raw" ] && jq -e . <<<"$body_raw" >/dev/null 2>&1; then
    args+=(--argjson body "$body_raw")
    filter+=' | .body = $body'
  fi

  jq -cn "${args[@]}" "$filter" 2>/dev/null || printf '{"status":0}'
}

# ---------------------------------------------------------------------------
# usage_telemetry_fetch — perform the single OAuth usage read and echo the
# envelope. Never fails hard: a missing token, transport error, or non-200 all
# yield an envelope the public library reads as allow-with-warning.
# ---------------------------------------------------------------------------
usage_telemetry_fetch() {
  local now token ua curl_bin hdrfile raw status body retry_after
  now="$(usage_telemetry_now)"
  token="${CLAUDE_CODE_OAUTH_TOKEN:-}"

  if [ -z "$token" ]; then
    usage_telemetry_log "CLAUDE_CODE_OAUTH_TOKEN unset — status=0 (degraded; library fails safe to allow)"
    usage_telemetry_envelope 0 "" "$now" ""
    return 0
  fi

  ua="$(usage_telemetry_user_agent)"
  curl_bin="${USAGE_TELEMETRY_CURL:-curl}"
  hdrfile="$(mktemp "${TMPDIR:-/tmp}/usage-telemetry-hdr.XXXXXX")" || {
    usage_telemetry_log "failed to create temporary file for headers — status=0 (degraded; fail-safe allow)"
    usage_telemetry_envelope 0 "" "$now" ""
    return 0
  }

  # Body (any internal newlines) plus a trailing status line on stdout; response
  # headers to $hdrfile. No `-o`, so the body rides stdout and `-w` appends the
  # status as the final line.
  # The bearer token is fed via a stdin curl config (`-K -`), never argv, so it
  # is not visible in process listings.
  if ! raw="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | "$curl_bin" -sS \
      -K - \
      --max-time "${USAGE_TELEMETRY_TIMEOUT:-10}" \
      -D "$hdrfile" \
      -w $'\n%{http_code}' \
      -H "anthropic-beta: ${USAGE_TELEMETRY_BETA}" \
      -H "User-Agent: ${ua}" \
      "$USAGE_TELEMETRY_ENDPOINT" 2>/dev/null)"; then
    usage_telemetry_log "curl transport error reaching usage endpoint — status=0 (degraded; fail-safe allow)"
    rm -f "$hdrfile"
    usage_telemetry_envelope 0 "" "$now" ""
    return 0
  fi

  status="$(usage_telemetry_int "${raw##*$'\n'}" 0)"
  body="${raw%$'\n'*}"
  # When the body was empty, the strip above leaves "" (raw was "\n<status>").

  retry_after=""
  if [ "$status" = "429" ]; then
    retry_after="$(usage_telemetry_retry_after "$hdrfile" "$now")"
  fi
  rm -f "$hdrfile"

  if [ "$status" != "200" ]; then
    usage_telemetry_log "usage endpoint returned HTTP ${status} (non-200; library fails safe)"
  fi

  usage_telemetry_envelope "$status" "$retry_after" "$now" "$body"
}

# ---------------------------------------------------------------------------
# usage_telemetry_publish_file <envelope> [file] — write <envelope> to <file>
# (a fresh temp file when omitted) and export AGENT_TOKEN_BUDGET_TELEMETRY_FILE —
# the existing seam the public library reads. Echoes the file path. This is the
# sanctioned wiring: no new seam is introduced.
# ---------------------------------------------------------------------------
usage_telemetry_publish_file() {
  local envelope="$1" file="${2:-${AGENT_TOKEN_BUDGET_TELEMETRY_FILE:-}}"
  if [ -z "$file" ]; then
    file="$(mktemp "${TMPDIR:-/tmp}/agent-token-telemetry.XXXXXX")" || {
      usage_telemetry_log "failed to create temporary file for telemetry"
      return 1
    }
  fi
  # Write atomically (temp + rename) so concurrent readers never see a
  # truncated, half-written file.
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")" || return 1
  if ! { printf '%s' "$envelope" > "$tmp" && mv -f "$tmp" "$file"; }; then
    rm -f "$tmp"
    return 1
  fi
  export AGENT_TOKEN_BUDGET_TELEMETRY_FILE="$file"
  printf '%s' "$file"
}
