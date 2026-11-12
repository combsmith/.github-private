#!/usr/bin/env bash
# miss-harvest.sh — harvest accepted pr-review misses into eval regression cases (#1596).
#
# When the deterministic miss-rate metric (scripts/lib/pr-review-miss-rate.sh)
# identifies an ACCEPTED miss — a real defect a trusted advisory bot found on a PR
# pr-review had already approved — that miss is the free, perfectly-labelled source
# of truth for a regression case. This library turns one miss into a de-identified
# case line for evals/deep-review/dev/cases.jsonl.
#
# ── HARD INVARIANT: dev/ ONLY, never holdout/ ────────────────────────────────
# Harvested cases go to the dev split ONLY. holdout/ is CODEOWNER-gated and
# holdout-guard.yml hard-fails proposer-authored PRs touching evals/; the whole
# point of the split is that the proposer must never see the cases it is scored
# against (#1088). Auto-harvesting into holdout/ would silently destroy the one
# control that makes the eval's success metric meaningful. mh_assert_dev_path is
# the belt-and-braces guard: any target path under a holdout/ segment is refused,
# and mh_harvest writes NOTHING when the guard trips.
#
# ── De-identification (evals/README.md decision A3) ──────────────────────────
# Cases are world-readable within the org and the dev split is proposer-visible,
# so a case must carry no raw URLs, @mentions, secrets/tokens, or PII. mh_build_case
# scrubs those into placeholders before the case is ever written.

# Default target: the deep-review dev split.
: "${MISS_HARVEST_DEV_CASES:=evals/deep-review/dev/cases.jsonl}"

# mh_assert_dev_path <path>
#   Exit 0 if the path is a legitimate dev-split target; exit 1 if it names a
#   holdout/ path. This is the structural guard the harvester keys off.
mh_assert_dev_path() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    echo "[miss-harvest] ERROR: no target path supplied" >&2
    return 1
  fi
  # Reject any parent-directory traversal component first. A purely lexical dev/
  # match is defeated by 'evals/deep-review/dev/../../../README.md', which contains
  # a dev/ segment yet resolves outside the dev split. Refusing '..' outright keeps
  # every harvested case inside dev/ (#1596/#1088).
  case "/$path/" in
    */../*)
      echo "[miss-harvest] REFUSED: '$path' contains a '..' traversal component — harvested cases go to dev/ ONLY (#1596/#1088)." >&2
      return 1
      ;;
  esac
  case "/$path/" in
    */holdout/*)
      echo "[miss-harvest] REFUSED: '$path' is a holdout/ path — harvested cases go to dev/ ONLY (#1596/#1088)." >&2
      return 1
      ;;
  esac
  # Positive assertion: the target must live under a dev/ split. Rejecting only
  # holdout/ would let a caller write to any arbitrary location while still passing
  # this guard — the invariant is dev/ ONLY, so require an explicit dev/ segment.
  case "/$path/" in
    */dev/*) : ;;
    *)
      echo "[miss-harvest] REFUSED: '$path' is not under a dev/ split — harvested cases go to dev/ ONLY (#1596/#1088)." >&2
      return 1
      ;;
  esac
  return 0
}

# _mh_deidentify — read text on stdin, write a de-identified copy to stdout.
# Redacts URLs, @mentions, and common secret/token shapes into stable placeholders.
_mh_deidentify() {
  # POSIX ERE word boundaries only — \b is a GNU extension and fails on BSD/macOS sed.
  sed -E \
    -e 's#https?://[^[:space:]]+#<url>#g' \
    -e 's#(^|[^A-Za-z0-9_-])gh[pousr]_[A-Za-z0-9]{16,}#\1<token>#g' \
    -e 's#(^|[^A-Za-z0-9_-])github_pat_[A-Za-z0-9_]{20,}#\1<token>#g' \
    -e 's#(^|[^A-Za-z0-9_-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}($|[^A-Za-z0-9_-])#\1<email>\2#g' \
    -e 's#(^|[^A-Za-z0-9_/])@[A-Za-z0-9][A-Za-z0-9-]*#\1<mention>#g'
}

# mh_build_case <miss_json>
#   Turn one accepted-miss record into a de-identified JSONL case object.
#   Input fields used: .bot (login that found it first), .finding (the defect text).
#   The id is a stable content hash so re-harvesting the same miss is idempotent.
mh_build_case() {
  local miss="${1:-}"
  [[ -n "$miss" ]] || { echo "[miss-harvest] ERROR: no miss record supplied" >&2; return 1; }

  local bot finding clean_finding id
  bot="$(jq -r '.bot // "advisory-bot"' <<<"$miss" 2>/dev/null)" || return 1
  finding="$(jq -r '.finding // ""' <<<"$miss" 2>/dev/null)" || return 1

  clean_finding="$(printf '%s' "$finding" | _mh_deidentify)"
  # Stable id from the de-identified finding text (no raw identifiers leak into it).
  # sha256sum, not sha1sum: this is only a content-addressed idempotency key, but
  # SonarCloud flags SHA-1 as a weak hash (S4790) regardless of context.
  id="deep-miss-$(printf '%s' "$clean_finding" | sha256sum | cut -c1-12)"

  jq -cn --arg id "$id" --arg bot "$bot" --arg finding "$clean_finding" '
    {
      id: $id,
      description: "Harvested from a production pr-review miss (#1596): an accepted defect a trusted advisory bot found after pr-review approved. Proposer-visible dev case; never scored by the gate.",
      tags: ["harvested-miss", "false-negative"],
      input: ("A third-party advisory reviewer (" + $bot + ") reported this defect on a PR pr-review had already APPROVED:\n\n" + $finding + "\n\nTriage result: {\"escalate\": false, \"risk\": \"LOW\", \"summary\": \"pr-review approved; defect missed\"}"),
      expected: {
        decision: "escalate",
        risk: "MEDIUM",
        escalate_to_opus: false,
        key_findings: [$finding]
      }
    }'
}

# mh_harvest <miss_json> [<target_path>]
#   Build the de-identified case and APPEND it to the dev cases file. Refuses (and
#   writes nothing) if the target is a holdout/ path. Returns non-zero on refusal
#   or build failure.
mh_harvest() {
  local miss="${1:-}" target="${2:-$MISS_HARVEST_DEV_CASES}"

  mh_assert_dev_path "$target" || return 1

  local case_line
  case_line="$(mh_build_case "$miss")" || return 1
  [[ -n "$case_line" ]] || return 1

  # The case id is a stable content hash, so harvesting is idempotent ONLY if we
  # skip cases already present. Without this the same production miss appends a
  # duplicate on every run and the eval set grows without bound.
  local case_id
  case_id="$(jq -r '.id // ""' <<<"$case_line" 2>/dev/null)"

  mkdir -p "$(dirname "$target")"

  # The recheck-then-append must be atomic: two concurrent harvesters of the same
  # miss can both observe the id absent and both append, writing the case twice.
  # Hold an exclusive flock on a per-target lockfile across the whole critical
  # section so exactly one writer wins and the rest see the id and skip.
  local lockfile="${target}.lock"
  (
    flock 9 || { echo "[miss-harvest] ERROR: could not acquire lock on $lockfile" >&2; exit 1; }
    if [[ -n "$case_id" ]] && [[ -f "$target" ]] && grep -qF "$case_id" "$target" 2>/dev/null; then
      echo "[miss-harvest] case $case_id already present in $target — skipping (idempotent)" >&2
      exit 0
    fi
    printf '%s\n' "$case_line" >> "$target"
    echo "[miss-harvest] appended case to $target" >&2
  ) 9>"$lockfile"
}
