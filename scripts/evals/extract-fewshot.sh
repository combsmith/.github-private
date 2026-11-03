#!/usr/bin/env bash
set -euo pipefail
# extract-fewshot.sh — build de-identified few-shot examples from this repo's
# merged-PR review->merge histories and store them in a proposer-visible dev
# split (issue #1093, epic #1088, Phase 2, Task 1).
#
# The deep-review tier reads these examples (via the $FEWSHOT_FILE optional-file
# contract assembled by scripts/lib/fewshot.sh) to calibrate to what this repo's
# maintainers actually accept and flag. Each example captures ONE past outcome:
# the PR's title/summary plus the review decision (approve|escalate) and risk.
#
# Held-out discipline (AC #2). The output MUST land under a proposer-visible dev
# split, NEVER under evals/**/holdout — the set the held-out gate later scores
# against. fewshot_source_is_holdout (the same guard the assembler enforces)
# hard-refuses a holdout output path here too, so a mis-pointed --out can never
# write into the held-out set.
#
# De-identification (evals/README.md decision A3). Every text field is scrubbed
# of secrets, tokens, internal hostnames, and PII via fewshot_scrub BEFORE it is
# committed — cases are redacted reconstructions, never raw captured content.
#
# Usage:
#   extract-fewshot.sh [--repo <owner/repo>] [--limit N] [--out <path>]
#
# Defaults: --repo $GITHUB_REPOSITORY, --limit 30,
#           --out evals/deep-review/dev/fewshot.jsonl
#
# Requires: gh (authenticated), jq. Exits non-zero on a holdout --out, missing
# tooling, or a failed fetch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/fewshot.sh
source "$REPO_ROOT/scripts/lib/fewshot.sh"

die() { echo "::error::extract-fewshot: $1" >&2; exit 1; }

REPO="${GITHUB_REPOSITORY:-}"
LIMIT=30
OUT="$REPO_ROOT/evals/deep-review/dev/fewshot.jsonl"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="${2:-}"; shift 2 ;;
    --limit) LIMIT="${2:-}"; shift 2 ;;
    --out)   OUT="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"
command -v gh >/dev/null 2>&1 || die "gh is required but not installed"
[[ -n "$REPO" ]] || die "no repository: pass --repo <owner/repo> or set GITHUB_REPOSITORY"

# Hard holdout guard (AC #2): never write few-shot data into a held-out path.
if fewshot_source_is_holdout "$OUT"; then
  die "refusing to write few-shot data to held-out path '$OUT' — the dev split must be proposer-visible, never evals/**/holdout"
fi

echo "  [fewshot] extracting up to $LIMIT merged PRs from $REPO -> $OUT" >&2

raw="$(gh pr list --repo "$REPO" --state merged --limit "$LIMIT" \
  --json number,title,body,labels,reviews 2>/dev/null)" \
  || die "failed to list merged PRs for $REPO (auth/scope?)"

[[ -n "$raw" ]] || die "empty PR listing for $REPO"

# Derive one example per merged PR with a pure jq program:
#   decision: escalate if any review requested changes OR a HIGH-risk label is
#             present; else approve.
#   risk:     HIGH for security/auth/migration labels, LOW for docs/tests-only,
#             else MEDIUM.
# The title/summary are carried verbatim here and de-identified by fewshot_scrub
# below (jq cannot call the shell scrub, so scrubbing is a second pass).
examples="$(printf '%s' "$raw" | jq -c '
  def labelnames: [.labels[]?.name // empty | ascii_downcase];
  .[]
  | . as $pr
  | (labelnames) as $labels
  | (any($pr.reviews[]?; .state == "CHANGES_REQUESTED")) as $changes
  | (any($labels[]; test("security|auth|secret|migration|crypto"))) as $high
  | (any($labels[]; test("docs|documentation|test|chore|typo"))) as $low
  | {
      id: ("fs-pr-\($pr.number)"),
      title: ($pr.title // ""),
      summary: (($pr.body // "") | split("\n")[0] | .[0:200]),
      decision: (if ($changes or $high) then "escalate" else "approve" end),
      risk: (if $high then "HIGH" elif $low then "LOW" else "MEDIUM" end),
      rationale: (if $changes then "maintainer requested changes before merge"
                  elif $high then "touches a security/auth/migration surface"
                  elif $low then "low-risk docs/tests/chore change"
                  else "non-trivial logic change, merged after review" end)
    }
' 2>/dev/null)" || die "failed to derive examples from PR listing"

[[ -n "$examples" ]] || die "no examples derived from $REPO (no merged PRs?)"

# Second pass: de-identify every string field (A3) AND neutralise prompt-injection
# vectors in the attacker-controllable merged-PR text (title/summary/body). This
# runs as a single O(1)-process pipeline instead of spawning jq+sed per example:
#   1. @tsv flattens each example to one row and escapes any embedded newline/tab/
#      CR in the merged text to a literal \n/\t/\r — so a crafted PR title or body
#      cannot forge new lines or headers when the example is later rendered into
#      the deep-review prompt (structural hardening on top of credential scrubbing;
#      the deep prompt also treats FEWSHOT as informational context, never an
#      instruction).
#   2. fewshot_scrub redacts secrets/tokens/hostnames/PII across the whole stream.
#   3. the row is reconstructed into a compact JSONL object.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
jq -r '[.id, .title, .summary, .decision, .risk, .rationale] | @tsv' <<< "$examples" \
  | fewshot_scrub \
  | jq -R -c 'select(length > 0) | split("\t")
      | {id: .[0], title: .[1], summary: .[2], decision: .[3], risk: .[4], rationale: .[5]}' \
  > "$tmp"
count=$(wc -l < "$tmp")

mkdir -p "$(dirname "$OUT")"
mv "$tmp" "$OUT"
trap - EXIT
echo "  [fewshot] wrote $count de-identified example(s) to $OUT" >&2
