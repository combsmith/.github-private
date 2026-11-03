#!/usr/bin/env bash
# run-eval.sh — frozen OFFLINE eval harness for the spec-drift detector
# (#1145, epic #1142).
#
# Why: the Story-2 detector (scripts/spec-drift.sh) must be trusted before it is
# wired into the pipeline. This harness proves it honest OFFLINE — no live PR, no
# LLM, no network — by driving the detector's PURE classifier (classify_drift)
# directly against frozen fixture cases and scoring the verdicts.
#
# The deterministic surface of the detector is classify_drift(analysis): it maps
# the cheap-tier analysis text into DRIFT / ALIGNED / INDETERMINATE. Each fixture
# case is a labeled (diff, acceptance-criteria, expected-verdict) triple and
# carries the frozen cheap-tier `analysis` the classifier consumes — the same
# "embed the upstream tier's output as a fixture" pattern evals/deep-review uses
# (its embedded `Triage result:`), so scoring needs no live model. See README.md.
#
# The gate metric is FALSE POSITIVES: a false positive is the costly detector
# error — it emits DRIFT for a PR whose expected verdict is NOT drift (it alarms
# a spec-compliant change). The harness exits non-zero if any split it scores has
# a false positive. AC5: the holdout split must score 0 false positives.
#
# Reward-hacking guard: the harness reads ONLY the split(s) named on the command
# line. `run-eval.sh dev` never opens holdout/. Tune the detector against dev;
# the holdout is the frozen, never-tuned baseline (also CI-immutable via
# holdout-guard.yml / CODEOWNERS over evals/**/holdout/).
#
# Usage:
#   run-eval.sh [--root DIR] [--quiet] [SPLIT ...]
#     SPLIT   a split name (dev|holdout) resolved to <root>/<split>/cases.jsonl,
#             or a path to a cases.jsonl file, or a directory holding one.
#             Defaults to `dev holdout` when none are given.
#     --root  eval root that split names resolve under (default: this dir).
#     --quiet suppress per-case lines; print only the SUMMARY line(s).

set -euo pipefail

SPEC_DRIFT_EVAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_DRIFT_REPO_ROOT="$(cd "$SPEC_DRIFT_EVAL_DIR/../.." && pwd)"

# Source the detector for its PURE classify_drift; spec-drift.sh only runs main()
# when executed directly, so sourcing it here is side-effect free.
# shellcheck source=scripts/spec-drift.sh
source "$SPEC_DRIFT_REPO_ROOT/scripts/spec-drift.sh"

# ---------------------------------------------------------------------------
# Pure scoring helpers (unit-tested in tests/test_spec_drift_eval.bats)
# ---------------------------------------------------------------------------

# sd_is_false_positive <actual> <expected>
# Exit 0 (true) iff the detector alarmed drift on a non-drift expectation, i.e.
# actual == DRIFT and expected != DRIFT. A missed drift (actual != DRIFT while
# expected == DRIFT) is a false NEGATIVE, not a false positive, so returns 1.
sd_is_false_positive() {
  local actual="${1:-}" expected="${2:-}"
  [[ "$actual" = "DRIFT" ]] && [[ "$expected" != "DRIFT" ]]
}

# sd_run_split <cases_file> [label]
# Scores every case in one cases.jsonl by running classify_drift on its frozen
# `analysis` fixture and comparing to `expected.verdict`. Prints a per-case line
# (unless SD_QUIET=1) and a final machine-readable SUMMARY line. Returns 1 if any
# false positive was scored, else 0.
sd_run_split() {
  local cases_file="${1:-}" label="${2:-}"
  if [[ -z "$label" ]]; then
    if [[ "$cases_file" == */* ]]; then
      local parent="${cases_file%/*}"
      label="${parent##*/}"
    else
      label="."
    fi
  fi

  if [[ ! -f "$cases_file" ]]; then
    echo "::error::[spec-drift-eval] cases file not found: $cases_file" >&2
    return 2
  fi

  if ! jq '.' < "$cases_file" > /dev/null; then
    printf '::error::[spec-drift-eval] malformed JSONL in %s — all lines must be valid JSON\n' "$cases_file" >&2
    return 2
  fi

  local total=0 correct=0 false_positives=0 false_negatives=0 mismatches=0
  local id expected analysis actual

  while IFS= read -r -d '' id && IFS= read -r -d '' expected && IFS= read -r -d '' analysis; do
    [[ -n "$id" ]] || continue
    actual="$(classify_drift "$analysis")"
    total=$((total + 1))

    if [[ "$actual" = "$expected" ]]; then
      correct=$((correct + 1))
      [[ "${SD_QUIET:-0}" = "1" ]] || printf '  PASS  %-40s %s\n' "$id" "$actual"
    else
      mismatches=$((mismatches + 1))
      local kind="mismatch"
      if sd_is_false_positive "$actual" "$expected"; then
        false_positives=$((false_positives + 1))
        kind="FALSE POSITIVE"
      elif [[ "$expected" = "DRIFT" ]]; then
        false_negatives=$((false_negatives + 1))
        kind="false negative"
      fi
      printf '  FAIL  %-40s expected=%s actual=%s (%s)\n' \
        "$id" "$expected" "$actual" "$kind" >&2
    fi
  done < <(jq -j 'select(.id) | .id, "\u0000", (.expected?.verdict // "INDETERMINATE" | tostring), "\u0000", (.analysis // "" | tostring), "\u0000"' "$cases_file")

  printf 'SUMMARY split=%s total=%d correct=%d false_positives=%d false_negatives=%d mismatches=%d\n' \
    "$label" "$total" "$correct" "$false_positives" "$false_negatives" "$mismatches"

  [[ "$false_positives" -eq 0 ]]
}

# sd_resolve_cases <root> <arg>
# Resolve a SPLIT argument to a cases.jsonl path. Prints the path on stdout.
# Returns 0 if the resolved file exists, 1 otherwise.
sd_resolve_cases() {
  local root="${1:-}" arg="${2:-}" path
  if [[ -f "$arg" ]]; then
    path="$arg"
  elif [[ -d "$arg" ]]; then
    path="$arg/cases.jsonl"
  else
    path="$root/$arg/cases.jsonl"
  fi
  printf '%s\n' "$path"
  [[ -f "$path" ]]
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  local root="$SPEC_DRIFT_EVAL_DIR"
  local -a splits=()

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --root) root="${2:?--root needs a directory}"; shift 2 ;;
      --quiet) export SD_QUIET=1; shift ;;
      -h|--help) grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      --) shift; break ;;
      -*) echo "::error::[spec-drift-eval] unknown option: $1" >&2; return 2 ;;
      *) splits+=("$1"); shift ;;
    esac
  done
  splits+=("$@")

  if [[ "${#splits[@]}" -eq 0 ]]; then
    splits=(dev holdout)
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "::error::[spec-drift-eval] jq CLI not found — cannot read cases" >&2
    return 1
  fi

  local overall_fp=0 split path label rc
  for split in "${splits[@]}"; do
    if ! path="$(sd_resolve_cases "$root" "$split")"; then
      echo "::error::[spec-drift-eval] no cases.jsonl for split '$split' (looked at: $path)" >&2
      return 2
    fi
    label="$split"
    case "$split" in
      dev|holdout) ;;
      *)
        if [[ "$path" == */* ]]; then
          local parent="${path%/*}"
          label="${parent##*/}"
        else
          label="."
        fi
        ;;
    esac

    rc=0
    sd_run_split "$path" "$label" || rc=$?
    if [[ "$rc" -eq 2 ]]; then
      return 2
    elif [[ "$rc" -ne 0 ]]; then
      overall_fp=1
    fi
  done

  if [[ "$overall_fp" -ne 0 ]]; then
    echo "::error::[spec-drift-eval] one or more splits had a false positive — the detector alarmed a spec-compliant change" >&2
    return 1
  fi
  return 0
}

# Only run main when executed directly (not when sourced by tests).
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  main "$@"
fi
