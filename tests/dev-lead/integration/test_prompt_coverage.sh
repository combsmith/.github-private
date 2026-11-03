#!/usr/bin/env bash
set -euo pipefail
# Integration test: verify all dev-lead prompts have correct variable declarations.
#
# Checks:
#   1. All 7 expected prompt files exist
#   2. Each prompt has a <!-- VARIABLES: --> comment
#   3. All ${VAR} references in each prompt are declared in that comment

PROMPTS_DIR="$(dirname "$0")/../../../prompts/dev-lead"
FAILED=0

# ── 1. check all 7 prompts exist ─────────────────────────────────────────────

EXPECTED_PROMPTS=(
  "fix-ci.md"
  "fix-reviews.md"
  "fix-bot-comment.md"
  "on-mention.md"
  "review-changes.md"
  "fix-issue.md"
  "rebase.md"
)

echo "Checking prompt files exist..."
for prompt in "${EXPECTED_PROMPTS[@]}"; do
  path="$PROMPTS_DIR/$prompt"
  if [[ ! -f "$path" ]]; then
    echo "  FAIL: missing prompt file: $path"
    FAILED=1
  else
    echo "  ok: $prompt"
  fi
done

# ── 2. check VARIABLES comment + 3. check variable coverage ──────────────────

echo ""
echo "Checking variable declarations..."
for prompt in "${EXPECTED_PROMPTS[@]}"; do
  path="$PROMPTS_DIR/$prompt"
  [[ -f "$path" ]] || continue

  # Extract declared variables from <!-- VARIABLES: VAR1, VAR2, ... --> comment
  declared_line=$(grep -oP '(?<=<!-- VARIABLES: )[^>]+(?= -->)' "$path" 2>/dev/null | head -1 || true)

  if [[ -z "$declared_line" ]]; then
    echo "  FAIL: $prompt — missing <!-- VARIABLES: ... --> comment"
    FAILED=1
    continue
  fi

  # Build declared vars as a space-delimited list
  declared_vars=$(echo "$declared_line" | tr ',' '\n' | tr -d ' ' | sort -u)

  # Extract ${VAR} style references used in file
  used_vars=$(grep -oP '\$\{[A-Z_]+\}' "$path" 2>/dev/null | sed 's/[${}]//g' | sort -u || true)

  if [[ -z "$used_vars" ]]; then
    echo "  ok: $prompt (no variables used)"
    continue
  fi

  prompt_failed=0
  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    if ! echo "$declared_vars" | grep -qx "$var"; then
      echo "  FAIL: $prompt — \${$var} used but not declared in VARIABLES comment"
      FAILED=1
      prompt_failed=1
    fi
  done <<< "$used_vars"

  if [[ "$prompt_failed" -eq 0 ]]; then
    echo "  ok: $prompt (declared: $(echo "$declared_vars" | tr '\n' ',' | sed 's/,$//') )"
  fi
done

# ── 4. review prompts must reply-with-specifics; resolution is harness-only ───
# Regression for issue #452: dev-lead resolved (or silently left) review threads
# without replying what it fixed, and bot threads fixed during another
# reviewer's run stayed unresolved. Each review prompt must instruct the engine
# to post a thread reply (addPullRequestReviewThreadReply) describing the
# specific change.
#
# Updated for #1691 (epic #1621): the model must NOT resolve threads itself —
# resolution is performed only by the harness (dev-lead-fix-reviews.sh). So each
# review prompt must (a) still reply with specifics, and (b) state that the
# harness resolves and the model must not call the resolveReviewThread mutation.
# The forbidden mutation-invocation form is asserted separately in section 7.

echo ""
echo "Checking review prompts reply-with-specifics; resolution is harness-only..."
REVIEW_PROMPTS=("fix-reviews.md" "review-changes.md" "fix-bot-comment.md")
for prompt in "${REVIEW_PROMPTS[@]}"; do
  path="$PROMPTS_DIR/$prompt"
  [[ -f "$path" ]] || { echo "  FAIL: $prompt — missing"; FAILED=1; continue; }
  missing=""
  grep -q "addPullRequestReviewThreadReply" "$path" || missing="$missing reply-mutation"
  grep -qiE "specific(ally)?" "$path"               || missing="$missing specific-details"
  grep -qiE "harness resolves" "$path"              || missing="$missing harness-resolves"
  grep -qiE "must not call[^.]*resolveReviewThread" "$path" || missing="$missing forbid-resolve-mutation"
  if [[ -n "$missing" ]]; then
    echo "  FAIL: $prompt — missing:$missing"
    FAILED=1
  else
    echo "  ok: $prompt (replies with specifics; harness resolves)"
  fi
done

# ── 5. every OPEN_THREADS_JSON build must expose author.__typename ────────────
# Regression for issue #452: GraphQL omits the "[bot]" suffix from bot logins,
# so the prompts identify bots by author.__typename == "Bot". Every reviewThreads
# query that feeds OPEN_THREADS_JSON must therefore select __typename — both the
# fix-reviews build AND the review-changes build (the latter was missed). Both
# builds now share the paginated helper lib/open-review-threads.sh (#2056), so the
# query lives there; the driver is still scanned in case a build is inlined again.

echo ""
echo "Checking OPEN_THREADS_JSON queries expose author.__typename..."
# The reviewThreads query lives in the shared paginated fetch lib (#2056); the
# driver sources it. Count author selections across both files.
DRIVER="$(dirname "$0")/../../../scripts/dev-lead-fix-reviews.sh"
THREADS_LIB="$(dirname "$0")/../../../scripts/lib/open-review-threads.sh"
author_sel_total=$(cat "$DRIVER" "$THREADS_LIB" 2>/dev/null | grep -c 'comments(first:5) { nodes { body author {' || true)
author_sel_typename=$(cat "$DRIVER" "$THREADS_LIB" 2>/dev/null | grep -c 'comments(first:5) { nodes { body author { login __typename } }' || true)
if [[ "$author_sel_total" -eq 0 ]]; then
  echo "  FAIL: no OPEN_THREADS_JSON author selection found in $(basename "$DRIVER") or $(basename "$THREADS_LIB")"
  FAILED=1
elif [[ "$author_sel_total" -ne "$author_sel_typename" ]]; then
  echo "  FAIL: $((author_sel_total - author_sel_typename)) of $author_sel_total OPEN_THREADS_JSON build(s) omit author.__typename"
  FAILED=1
else
  echo "  ok: all $author_sel_total OPEN_THREADS_JSON build(s) select author.__typename"
fi

# ── 6. review-changes must explain a failing-check fix (check vs. intent) ─────
# Regression for issue #1468: the "agent optimizes the check, not the intent"
# failure mode — a red check driven green by changing what the check measures
# rather than making the thing it protects true. When review-changes fixes a
# failing check (a Tier-1 blocker), its posted fix comment must state WHAT the
# check verifies and WHY the diff makes that true — not merely "check now passes"
# — so a reviewer (or pr-review) has a concrete claim to spot-check.

echo ""
echo "Checking review-changes explains a failing-check fix (check vs. intent, #1468)..."
rc_path="$PROMPTS_DIR/review-changes.md"
if [[ ! -f "$rc_path" ]]; then
  echo "  FAIL: review-changes.md — missing"
  FAILED=1
else
  # Scope the phrase checks to the "Reporting a failing-check fix" section so
  # unrelated prompt text cannot mask a regression in the operative instruction.
  rc_section="$(sed -n '/^#### Reporting a failing-check fix/,/^###/p' "$rc_path")"
  rc_missing=""
  [[ -n "$rc_section" ]] || rc_missing="$rc_missing reporting-section"
  printf '%s' "$rc_section" | grep -qiE "what (the|a) (failing )?check verifies" || rc_missing="$rc_missing what-check-verifies"
  printf '%s' "$rc_section" | grep -qiE "why (this|the|your) diff (makes that true|satisfies)" || rc_missing="$rc_missing why-diff-satisfies"
  printf '%s' "$rc_section" | grep -qiE "not (just|merely) .*check (now )?passes" || rc_missing="$rc_missing not-just-passes"
  # The prohibition is load-bearing, not just the reporting duty: the prompt must
  # forbid making a check green by changing what it asserts (its threshold,
  # fixture, expected output, or the assertion itself).
  grep -qiE "never make a check green by changing what it asserts" "$rc_path" || rc_missing="$rc_missing prohibition-no-assert-change"
  printf '%s' "$rc_section" | grep -qiE "change what the check asserts" || rc_missing="$rc_missing section-stop-condition"
  if [[ -n "$rc_missing" ]]; then
    echo "  FAIL: review-changes.md — missing check-vs-intent statement:$rc_missing"
    FAILED=1
  else
    echo "  ok: review-changes.md (requires what-check-verifies / why-diff-satisfies on a failing-check fix)"
  fi
fi

# ── 7. no dev-lead prompt may hand the model the resolveReviewThread mutation ─
# Regression for #1691 (epic #1621): thread resolution must be performed ONLY by
# the harness (dev-lead-fix-reviews.sh), never by the model. A prompt that hands
# the model the raw resolveReviewThread / unresolveReviewThread GraphQL mutation
# lets it bypass the deterministic resolve_* guards (review_thread_is_agent_authored,
# the addressed-marker + our-account check, and the fail-closed re-read). The prose
# may NAME the mutation in order to forbid it (e.g. "must not call resolveReviewThread"),
# so this assertion targets the mutation-INVOCATION form `resolveReviewThread(` only —
# an open paren directly following the mutation name — not a bare mention.

echo ""
echo "Checking no dev-lead prompt reintroduces the resolveReviewThread mutation (#1691)..."
for path in "$PROMPTS_DIR"/*.md; do
  [[ -f "$path" ]] || continue
  if grep -qE '(un)?resolveReviewThread[[:space:]]*\(' "$path"; then
    echo "  FAIL: $(basename "$path") — contains a resolveReviewThread mutation invocation; resolution is harness-only (#1691)"
    FAILED=1
  else
    echo "  ok: $(basename "$path") (no resolve mutation)"
  fi
done

# ── result ────────────────────────────────────────────────────────────────────

echo ""
if [[ "$FAILED" -ne 0 ]]; then
  echo "FAIL: prompt coverage check failed"
  exit 1
fi

echo "PASS: all prompts have correct variable declarations"
