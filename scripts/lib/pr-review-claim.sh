#!/usr/bin/env bash
# Per-PR review-claim primitive (issue #1589, slice 1 — OBSERVE-ONLY).
#
# The #1551 metadata-digest re-arm path lets a same-SHA re-review proceed when a
# metadata-only fix-request's `meta=<digest>` no longer matches the current PR
# metadata. That path takes NO atomic claim before starting the cascade, so two
# triggers (a scheduled sweep + an event dispatch, or two dispatches) can read
# the same stale marker, both observe the digest mismatch, and BOTH launch the
# full cascade — a duplicate the #1551 fix newly made reachable.
#
# Slice 1 does NOT arbitrate that race (that is slice 2). It only makes the race
# OBSERVABLE by introducing:
#   • the claim KEY  = (head SHA, current metadata digest) — a metadata edit
#     re-arms the #1551 path and also changes the digest, so it yields a distinct
#     key; two runs racing at the same head+metadata share one key.
#   • the claim MARKER format:
#       <!-- pr-review-claim v1 sha=<SHA> meta=<DIGEST> run=<TOKEN> at=<TS> -->
#     posted as a PR comment before the cascade starts, carrying a per-run TOKEN
#     so a run can tell its own claim apart from a concurrent one.
#   • concurrent_claim_present — detects a live claim on the same key posted by a
#     DIFFERENT run, the telemetry signal the observe-only slice records.
#
# Slice 2 layers compare-and-set arbitration + a TTL (`at=` is the timestamp it
# will age against) on top of this exact format; slice 1 must not change caller
# behaviour, only surface the race.

# claim_key <sha> <digest>
#   Echo the stable claim key for a (head SHA, metadata digest) pair. The key
#   changes whenever either the SHA or the digest changes, and is stable when
#   neither does. Kept identical in shape to the marker's `sha=… meta=…` fields
#   so a parsed marker key (claim_marker_key) compares equal to it directly.
claim_key() {
  printf 'sha=%s meta=%s' "${1:-}" "${2:-}"
}

# claim_marker <sha> <digest> <token> <ts>
#   Echo the claim marker HTML comment for the given key + per-run token + UTC
#   timestamp. Single-line so it round-trips as one PR-comment body.
claim_marker() {
  printf '<!-- pr-review-claim v1 sha=%s meta=%s run=%s at=%s -->' \
    "${1:-}" "${2:-}" "${3:-}" "${4:-}"
}

# _claim_marker_match <marker_body>
#   Echo the (last) well-formed pr-review-claim marker substring found in a body,
#   or nothing. Anchored to the exact writer format so unrelated HTML comments —
#   including the #1551 `pr-review-agent` markers — never match. `tail -1` drains
#   its input fully so it cannot raise SIGPIPE (exit 141) under callers' pipefail.
_claim_marker_match() {
  printf '%s' "${1:-}" \
    | grep -oE '<!--[[:space:]]*pr-review-claim v1 sha=[a-f0-9]+ meta=[a-f0-9]{16} run=[^[:space:]]+ at=[^[:space:]]+[[:space:]]*-->' \
    | tail -n 1 || true
}

# claim_marker_key <marker_body>
#   Echo the claim key parsed out of a claim marker body, or nothing when the
#   body is not a well-formed pr-review-claim marker.
claim_marker_key() {
  local match sha meta
  match="$(_claim_marker_match "${1:-}")"
  [[ -n "$match" ]] || return 0
  sha="$(printf '%s' "$match" | grep -oE 'sha=[a-f0-9]+' | tail -n 1)"
  meta="$(printf '%s' "$match" | grep -oE 'meta=[a-f0-9]{16}' | tail -n 1)"
  claim_key "${sha#sha=}" "${meta#meta=}"
}

# claim_marker_run <marker_body>
#   Echo the per-run token stamped in a claim marker body, or nothing when the
#   body is not a well-formed pr-review-claim marker.
claim_marker_run() {
  local match
  match="$(_claim_marker_match "${1:-}")"
  [[ -n "$match" ]] || return 0
  printf '%s' "$match" | grep -oE 'run=[^[:space:]]+' | tail -n 1 | sed 's/^run=//'
}

# concurrent_claim_present <own_token> <sha> <digest> <comments_json>
#   Return 0 (true) if a live pr-review-claim marker for the same key (sha+digest)
#   posted by a DIFFERENT run (run token != <own_token>) exists among the PR's
#   comments; return 1 (false) otherwise. <comments_json> is a JSON array of
#   comment objects each carrying a `.body` (the snapshot's `.comments`). Missing/
#   malformed input degrades to false, never an error — a stray input must not
#   break the caller. Slice 1 treats every claim as live (no TTL yet); slice 2
#   ages a claim against its `at=` timestamp.
concurrent_claim_present() {
  local own_token="${1:-}" sha="${2:-}" digest="${3:-}" comments_json="${4:-[]}"
  local want_key bodies line k t
  want_key="$(claim_key "$sha" "$digest")"
  # Emit one claim-bearing body per line, newlines within a body flattened so the
  # read loop below stays line-oriented.
  bodies="$(printf '%s' "$comments_json" \
    | jq -r '.[]? | (.body // "") | select(test("pr-review-claim v1")) | gsub("[\r\n]+"; " ")' 2>/dev/null || true)"
  [[ -n "$bodies" ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    k="$(claim_marker_key "$line")"
    [[ "$k" = "$want_key" ]] || continue
    t="$(claim_marker_run "$line")"
    [[ "$t" != "$own_token" ]] || continue
    return 0
  done <<< "$bodies"
  return 1
}
