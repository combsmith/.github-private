#!/usr/bin/env bash
# finding-verification.sh — agentic iterative validation post-processor for the
# deep review tier (issue #1092, epic #1088).
#
# WHAT / WHY
#   The deep tier now attempts to *confirm* a suspected logic/correctness finding
#   by running the repo's relevant lint/test tool before it is reported, so
#   plausible-but-wrong findings stop reaching reviewers. The deep tier does the
#   repro itself (it already has a Bash tool) and records the outcome on each such
#   finding as a `verification` field:
#     - "confirmed"    the repro reproduced the bug              -> keep as-is
#     - "refuted"      the repro tool ran and did NOT reproduce  -> downgrade one
#                      severity (or drop when already `info`)
#     - "unverifiable" no runnable lint/test target maps to it   -> keep as-is
#   This function is the pure-shell discipline layer over those tags: it applies
#   the downgrade/drop, tags the message auditable, and emits one
#   kind:"finding_verification" record per processed finding (via
#   emit_verification_record in token-metrics.sh) so the false-positive-rate delta
#   is measurable. It uses the same record kind and downgrade discipline as other
#   finding post-processors, so token_report.sh aggregation and the FP-rate math
#   work without further changes.
#
# PRIVILEGE / TIMEOUT GUARD (AC #3)
#   This function runs NO external tools — it is jq-only. The actual repro happens
#   inside the deep tier's existing `run_agentic` invocation, which already runs
#   with `--allowed-tools Bash,Read,Grep,Glob` and is wrapped by `timeout
#   $DEEP_TIMEOUT_SEC` (engine.sh). Validation therefore adds ZERO new tool
#   permissions and ZERO new network/write access, and cannot hang the review
#   because it inherits the per-tier timeout. It must never run in the writer/action
#   tier (the only tier with Write) — it is wired only after the deep tier.
#
# REWARD-HACKING GUARD (AC #4)
#   Only `refuted` (the repro tool actively failed to reproduce) downgrades/drops a
#   finding. `unverifiable` (absence of a runnable target) NEVER downgrades — that
#   would let a validator that maps nothing silently drop real findings to game the
#   FP-rate. Non-logic-class findings are never touched.
#
# Usage: source this file, then call:
#   apply_finding_verification <deep_json_file> [workflow] [tier] [context]
#     - mutates <deep_json_file> in place (downgrades/drops findings)
#     - never fails: a missing/invalid file or absent jq is a clean no-op

set -euo pipefail

# Bring in emit_verification_record if the caller has not already sourced
# token-metrics.sh (review-one-pr.sh sources both; tests may source only this).
if ! declare -F emit_verification_record >/dev/null 2>&1; then
  # shellcheck source=token-metrics.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/token-metrics.sh"
fi

# The finding classes that warrant a repro attempt. Start with logic/correctness
# (AC #1). `category` is compared lower-cased.
_fv_is_logic_category() {
  case "${1:-}" in
    logic | correctness) return 0 ;;
    *) return 1 ;;
  esac
}

# _fv_downgrade_severity <severity>
#   Prints the next-lower deep-review severity. `info` prints empty (the caller
#   drops the finding). An unrecognized severity prints itself (no change) so an
#   unexpected value can never silently escalate or vanish.
_fv_downgrade_severity() {
  case "${1:-}" in
    critical) printf 'major' ;;
    major)    printf 'minor' ;;
    minor)    printf 'info' ;;
    info)     printf '' ;;
    *)        printf '%s' "${1:-}" ;;
  esac
}

# apply_finding_verification <deep_json_file> [workflow] [tier] [context]
apply_finding_verification() {
  local file="${1:-}"
  local workflow="${2:-pr-review}"
  local tier="${3:-deep}"
  local context="${4:-}"

  # Safe no-ops: missing/empty file, no jq, or unparseable JSON.
  [[ -n "$file" ]] && [[ -s "$file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq empty "$file" 2>/dev/null || return 0

  local count
  count="$(jq -r '(.findings // []) | length' "$file" 2>/dev/null || printf '0')"
  case "$count" in
    '' | *[!0-9]*) return 0 ;;
  esac
  [ "$count" -gt 0 ] || return 0  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449

  local tmp; tmp="$(mktemp)"
  if jq '
    def downgrade_severity(sev):
      if sev == "critical" then "major"
      elif sev == "major" then "minor"
      elif sev == "minor" then "info"
      elif sev == "info" then ""
      else sev end;
    def is_logic_category(cat):
      (cat | ascii_downcase) as $c | ($c == "logic" or $c == "correctness");
    .findings as $orig_findings
    | (reduce (range(0; $orig_findings | length)) as $i (
        {findings: [], events: []};
        . as $state
        | $orig_findings[$i] as $f
        | if ($f == null or $f == "null") then $state
          else
            ($f.category // "" | ascii_downcase) as $cat
            | ($f.verification // "" | ascii_downcase) as $ver
            | ($f.severity // "") as $sev
            | if (is_logic_category($cat) and $ver != "") then
                (if $ver == "confirmed" then
                   {outcome: "confirmed", new_sev: $sev, dropped: 0}
                 elif $ver == "refuted" then
                   downgrade_severity($sev) as $new_sev
                   | {outcome: "refuted", new_sev: $new_sev, dropped: (if $new_sev == "" then 1 else 0 end)}
                 else
                   {outcome: "unverifiable", new_sev: $sev, dropped: 0}
                 end) as $res
                | $res.new_sev as $new_sev
                | (if $res.dropped == 1 then "dropped" else $new_sev end) as $sev_after
                | $state
                  | .events += [{index: $i, outcome: $res.outcome, severity_before: $sev, severity_after: $sev_after}]
                  | if $res.dropped == 0 then
                      .findings += [$f | .severity = $new_sev | .verified = $res.outcome | .message = ((.message // "") + " [auditable: repro " + $res.outcome + "]")]
                    else
                      .
                    end
              else
                $state | .findings += [$f]
              end
          end
      )) as $proc
    | .findings = $proc.findings
    | ._events = $proc.events
  ' "$file" > "$tmp" 2>/dev/null; then
    local idx outcome sev_before sev_after
    while IFS=$'\t' read -r idx outcome sev_before sev_after; do
      [[ -n "$outcome" ]] || continue
      emit_verification_record "$workflow" "$tier" "$outcome" "$sev_before" "$sev_after" "$idx" "$context"
    done < <(jq -r '._events[]? | "\(.index)\t\(.outcome)\t\(.severity_before)\t\(.severity_after)"' "$tmp" 2>/dev/null)

    jq 'del(._events)' "$tmp" > "$file" 2>/dev/null || true
  fi
  rm -f "$tmp"
  return 0
}
