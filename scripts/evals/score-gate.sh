#!/usr/bin/env bash
set -euo pipefail
# score-gate.sh — role-generic SCORED promotion gate for held-out persona/skill
# eval sets (#1630, epic #1627).
#
# Usage:
#   score-gate.sh <role> [--threshold N] [--report FILE] [--evals-dir DIR]
#
# Replaces the count-only holdout gate (#1318: for months only a placeholder
# `min_cases` was ever enforced, so nothing measured whether a persona's advice
# was any good). This gate instead SCORES the role's held-out set against a
# documented threshold and emits a machine-readable pass/fail verdict, so
# promotion past draft is earned on measured advice quality, not a case count.
#
# It is deliberately SHARED infrastructure, parameterized on the role: it reads
# evals/<role>/holdout via the shared scorer (run-eval.sh) and evals/<role>/scorer.json
# for the threshold, and hardcodes nothing about solution-architect — so the same
# gate promotes any of the eight drafted personas' eval trees. See
# scripts/evals/README.md.
#
# How the score is produced:
#   - Without --report, the gate runs the shared scorer (run-eval.sh <role>),
#     which feeds each held-out input to the role's prompt and grades the
#     candidate output against the case's fixed expected reference (llm-judge for
#     personas whose advice is prose, per evals/<role>/scorer.json), then emits an
#     aggregate report whose `.score` is the fraction of held-out cases that clear
#     the per-case judge threshold.
#   - With --report FILE, the gate reads a pre-computed scorer report instead of
#     invoking any model — so CI can score once and gate on the artifact, and the
#     gate's own logic stays testable OFFLINE (tests/test_score_gate.bats).
#
# The promotion bar is `.score >= threshold`, resolved by sg_resolve_threshold:
#   1. an explicit --threshold N, else
#   2. evals/<role>/scorer.json `.gate_threshold`, else
#   3. the documented default (0.7 — at least 70% of held-out cases must pass).
#
# Following ADR-0004 (pure-logic + bats), the threshold/verdict/score-extraction
# logic is pure and unit-tested BEFORE the gate is relied on for promotion;
# main() confines all I/O (running the scorer, reading the report, printing).
#
# Output: a single JSON verdict object on stdout, e.g.
#   {"role":"solution-architect","score":0.857,"threshold":0.7,"verdict":"pass",
#    "passed":6,"failed":1,"total":7}
#
# Exit codes:
#   0  score >= threshold (promotion allowed)
#   1  score <  threshold (held below the bar)
#   2  hard error — bad usage / scorer hard-failed / report has no numeric score

SG_DEFAULT_THRESHOLD="0.7"

# ── Pure logic (unit-tested in tests/test_score_gate.bats) ─────────────────────

# sg_in_unit_range <value>
# Return 0 iff <value> parses as a JSON number within the scorer's [0,1] range.
# The gate compares a fraction-of-cases score in [0,1] against the threshold, so a
# threshold outside that band is meaningless: a negative one passes every score
# (bypassing the bar) and one above 1 fails every score. Rejecting both keeps the
# promotion bar honest.
sg_in_unit_range() {
  local v="${1:-}"
  [[ -n "$v" ]] || return 1
  jq -n --argjson x "$v" -e '($x|type)=="number" and $x >= 0 and $x <= 1' >/dev/null 2>&1
}

# sg_resolve_threshold <cli_threshold> <scorer_json_path>
# Precedence: a non-empty CLI value wins; else the scorer.json `gate_threshold`
# (only when present AND a number in [0,1]); else the documented default. Prints
# the value. Returns 2 when an explicit --threshold is not a number in [0,1] so
# the caller rejects a bar that would bypass or nullify the gate.
sg_resolve_threshold() {
  local cli="${1:-}" cfg="${2:-}" val
  if [[ -n "$cli" ]]; then
    sg_in_unit_range "$cli" || return 2
    printf '%s\n' "$cli"
    return 0
  fi
  if [[ -n "$cfg" ]] && [[ -f "$cfg" ]]; then
    val="$(jq -r 'if (.gate_threshold | type) == "number" and .gate_threshold >= 0 and .gate_threshold <= 1 then .gate_threshold else empty end' "$cfg" 2>/dev/null || true)"
    if [[ -n "$val" ]]; then
      printf '%s\n' "$val"
      return 0
    fi
  fi
  printf '%s\n' "$SG_DEFAULT_THRESHOLD"
}

# sg_extract_score <report_json>
# Prints the aggregate `.score` from a scorer report, but only when the report is
# a single JSON object exposing a numeric score WITHIN the scorer's [0,1] range.
# A legitimate report can never exceed that band (the aggregate score is
# passed/total and each judged case is clamped to [0,1] in run-eval.sh), so a
# score outside it signals a garbage/tampered report — treat it as a hard error
# rather than accept e.g. score 2 as a pass. Anything else returns non-zero so the
# caller can treat a scoreless/out-of-range report as a hard error (not a silent 0).
sg_extract_score() {
  local report="${1:-}"
  jq -e -r 'if (type=="object" and (.score|type=="number") and (.score>=0) and (.score<=1)) then .score else error("no valid score in [0,1]") end' \
    <<<"$report" 2>/dev/null
}

# sg_verdict <score> <threshold>
# The single pass/fail predicate: pass iff score >= threshold (inclusive bar —
# exactly meeting the documented threshold promotes). Prints pass/fail and exits
# 0/1 accordingly.
sg_verdict() {
  local score="${1:-}" threshold="${2:-}"
  if jq -n --argjson s "$score" --argjson t "$threshold" -e '$s >= $t' >/dev/null 2>&1; then
    echo "pass"
    return 0
  fi
  echo "fail"
  return 1
}

# ── I/O orchestration ─────────────────────────────────────────────────────────

die() {
  # stdout (not stderr) so the reason is visible in workflow logs and capturable
  # by tests; the ::error:: prefix still renders as a GitHub annotation.
  echo "::error::score gate: $1"
  exit 2
}

main() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "$script_dir/../.." && pwd)"

  command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

  local role="" cli_threshold="" report_file="" evals_dir="${EVALS_DIR:-$repo_root/evals}"
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      # NOTE: use an explicit arity check + die (exit 2), NOT ${2:?...}. The
      # :? expansion aborts with status 1, which collides with the documented
      # "gate failed" exit and misreports a usage error; and when the flag is
      # the final argument, `shift 2` itself fails under `set -e`.
      --threshold) [[ "$#" -ge 2 ]] || die "--threshold needs a value"
                   cli_threshold="$2"; shift 2 ;;
      --report)    [[ "$#" -ge 2 ]] || die "--report needs a file"
                   report_file="$2"; shift 2 ;;
      --evals-dir) [[ "$#" -ge 2 ]] || die "--evals-dir needs a directory"
                   evals_dir="$2"; shift 2 ;;
      -h|--help)   grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *) if [[ -z "$role" ]]; then role="$1"; else die "unexpected argument: $1"; fi; shift ;;
    esac
  done
  [[ -n "$role" ]] || die "usage: score-gate.sh <role> [--threshold N] [--report FILE]"

  local scorer_config="$evals_dir/$role/scorer.json"
  local threshold
  threshold="$(sg_resolve_threshold "$cli_threshold" "$scorer_config")" \
    || die "invalid --threshold '$cli_threshold' — must be a number in [0,1]"

  # Obtain the aggregate report: read the supplied artifact, or run the shared
  # scorer. run-eval.sh exits 1 on a genuine quality regression (a legitimate
  # score < 1) and 2 on a hard/infra error — the former still yields a scoreable
  # report, the latter does not, so only a rc>=2 is fatal here.
  local report rc=0
  if [[ -n "$report_file" ]]; then
    [[ -f "$report_file" ]] || die "report file not found: $report_file"
    report="$(cat "$report_file")"
    # A supplied report must actually be THIS role's held-out result. run-eval.sh
    # tags every report with the scored `skill`; if that tag is present it must
    # match the requested role, else a stale or unrelated artifact (a different
    # role's report) could promote this role without scoring its own held-out
    # cases. A tag-less report is rejected too — we cannot confirm what it scored.
    local report_skill
    report_skill="$(jq -r 'if type=="object" and (.skill|type=="string") then .skill else "" end' <<<"$report" 2>/dev/null || true)"
    [[ -n "$report_skill" ]] || die "report has no skill tag — cannot confirm it scored role '$role'"
    [[ "$report_skill" = "$role" ]] || die "report is for skill '$report_skill', not requested role '$role' — refusing to gate on a mismatched report"
  else
    local scorer="$script_dir/run-eval.sh"
    [[ -f "$scorer" ]] || die "scorer not found (expected $scorer)"
    report="$(EVALS_DIR="$evals_dir" bash "$scorer" "$role")" || rc=$?
    [[ "$rc" -le 1 ]] || die "scorer hard-failed for role '$role' (rc=$rc) — held-out set was not scored"
  fi

  local score
  score="$(sg_extract_score "$report")" || die "scorer produced no numeric score for role '$role'"

  # Pull through the aggregate counts when present (report from run-eval.sh has
  # them; a minimal report may not) so the verdict object is self-describing.
  local total passed failed
  total="$(jq -r '.total  // 0' <<<"$report")"
  passed="$(jq -r '.passed // 0' <<<"$report")"
  failed="$(jq -r '.failed // 0' <<<"$report")"

  local verdict gate_rc=0
  verdict="$(sg_verdict "$score" "$threshold")" || gate_rc=$?

  jq -cn \
    --arg role "$role" \
    --argjson score "$score" \
    --argjson threshold "$threshold" \
    --arg verdict "$verdict" \
    --argjson total "$total" \
    --argjson passed "$passed" \
    --argjson failed "$failed" \
    '{role:$role, score:$score, threshold:$threshold, verdict:$verdict, passed:$passed, failed:$failed, total:$total}'

  if [[ "$gate_rc" -eq 0 ]]; then
    echo "::notice::score gate: PASS — role '$role' scored $score >= threshold $threshold" >&2
    return 0
  fi
  echo "::error::score gate: FAIL — role '$role' scored $score, below the documented threshold $threshold" >&2
  return 1
}

# Only run main when executed directly (not when sourced by tests).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  main "$@"
fi
