#!/usr/bin/env bash
# ripe-from-queue.sh — brief the ideas idea-triage just ranked "Ripe".
#
# idea-triage rewrites one "🧭 Idea Promotion Queue" tracking issue per repo
# (label `idea-triage`) with a "🟢 Ripe to promote" table. That table is the
# triage verdict, but nothing acted on it: a human had to hand-copy the
# template. This sweep reads the Ripe section, and for every Discussion it
# names that has no brief yet, dispatches ONE central decision-brief run
# (`gh workflow run decision-brief.yml -f discussion=N`) — so each idea gets its
# own run, its own concurrency lane and its own PR, and the `needs-brief` label
# path and this path converge on the same workflow.
#
# Skips (idempotency, cheapest first):
#   - a Discussion already labelled `idea:approved` (past the decision)
#   - a Discussion not in the Ideas category
#   - ideas/<slug>/brief.md already on the default branch
#   - an open PR from incubate/<slug> (a brief is in flight)
# and caps the dispatches per sweep (MAX_BRIEFS, default 3) so one triage pass
# cannot spend an unbounded model budget.
#
# The dispatch needs a PAT (a workflow_dispatch fired with GITHUB_TOKEN never
# starts a run). DRY_RUN=1 logs each intended dispatch to $DRY_RUN_LOG instead.
#
# Env:
#   REPO           owner/repo whose queue to read and whose ideas to brief (required)
#   CENTRAL_REPO   owner/repo hosting decision-brief.yml (default: REPO)
#   WORKFLOW_FILE  default decision-brief.yml
#   MAX_BRIEFS     default 3
#   IDEAS_DIR      default ideas
#   BRANCH_PREFIX  default incubate
#   QUEUE_LABEL    default idea-triage
#   DRY_RUN / DRY_RUN_LOG
#   GH_TOKEN       required (reads + the dispatch)
# Helpers are sourceable (tests/test_decision_brief.bats); strict mode is set
# only when executed.

# dbq_ripe_section <text-on-stdin> — the lines of the first section whose
# header mentions "ripe", up to the next header. The queue body is
# model-written Markdown, so only the header word is relied on.
dbq_ripe_section() {
  awk '
    /^#{1,6}[[:space:]]/ {
      if (insec) exit
      if (tolower($0) ~ /ripe/) { insec=1; next }
    }
    insec { print }
  '
}

# dbq_discussion_numbers <text-on-stdin> — every distinct #N (and
# /discussions/N) reference, in first-seen order, one per line. When the text
# holds a Markdown table, ONLY the first (Idea) cell of each data row is read:
# an issue or prerequisite mentioned in a "Why now" / promotion-note cell is
# not a Ripe idea and must not get a paid brief. Prose (no table) is read whole.
dbq_discussion_numbers() {
  awk '
    /^\|[[:space:]]*-+/ { sep = 1; next }
    /^\|/ { if (!sep) next; n = split($0, c, "|"); if (n > 2) print c[2]; table = 1; next }
    { other[++o] = $0 }
    END { if (!table) for (i = 1; i <= o; i++) print other[i] }
  ' | grep -oE '(#|/discussions/)[0-9]+' | grep -oE '[0-9]+' | awk '!seen[$0]++'
}

dbq_main() {
  REPO="${REPO:?REPO required}"
  CENTRAL_REPO="${CENTRAL_REPO:-$REPO}"
  WORKFLOW_FILE="${WORKFLOW_FILE:-decision-brief.yml}"
  MAX_BRIEFS="${MAX_BRIEFS:-3}"
  IDEAS_DIR="${IDEAS_DIR:-ideas}"
  BRANCH_PREFIX="${BRANCH_PREFIX:-incubate}"
  QUEUE_LABEL="${QUEUE_LABEL:-idea-triage}"
  [[ "$MAX_BRIEFS" =~ ^[0-9]+$ ]] || { echo "::error::MAX_BRIEFS must be an integer" >&2; return 1; }

  # shellcheck source=scripts/decision-brief/lib/slug.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib/slug.sh"
  local is_dry=0; [[ "${DRY_RUN:-0}" == "1" ]] && is_dry=1
  local owner="${REPO%/*}" name="${REPO#*/}"

  local queue_body
  queue_body="$(gh issue list --repo "$REPO" --label "$QUEUE_LABEL" --state open \
    --json number,title,body --jq 'map(select(.title | test("Idea Promotion Queue"))) | .[0].body // empty')"
  if [[ -z "$queue_body" ]]; then
    echo "::notice::${REPO} has no open Idea Promotion Queue issue (label ${QUEUE_LABEL}) — nothing ripe to brief. Adopt idea-triage first, or label a Discussion needs-brief."
    return 0
  fi

  local numbers
  numbers="$(printf '%s\n' "$queue_body" | dbq_ripe_section | dbq_discussion_numbers)"
  if [[ -z "$numbers" ]]; then
    echo "queue has no Ripe ideas this week — nothing to brief."
    return 0
  fi

  local n dispatched=0 skipped=0 disc title labels category slug
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    if [[ "$dispatched" -ge "$MAX_BRIEFS" ]]; then
      echo "::notice::cap reached (MAX_BRIEFS=${MAX_BRIEFS}); #${n} and later wait for the next sweep"
      break
    fi
    # An API/auth/rate-limit failure here is NOT "no such idea": fail the sweep
    # loudly rather than silently leaving a Ripe idea unbriefed (AGENTS.md,
    # "a failure read as nothing to do").
    if ! disc="$(gh api graphql -f query='
      query($owner:String!,$name:String!,$num:Int!){
        repository(owner:$owner,name:$name){
          discussion(number:$num){ title category{ name } labels(first:20){ nodes{ name } } }
        }
      }' -F owner="$owner" -F name="$name" -F num="$n")"; then
      echo "::error::could not read discussion #${n} in ${REPO} (API error, not a missing idea) — sweep aborted" >&2
      return 1
    fi
    title="$(printf '%s' "$disc" | jq -r '.data.repository.discussion.title // empty')"
    if [[ -z "$title" ]]; then echo "skip #${n}: not a Discussion (an issue/PR number in the Ripe table)"; skipped=$((skipped+1)); continue; fi
    category="$(printf '%s' "$disc" | jq -r '.data.repository.discussion.category.name // ""')"
    labels="$(printf '%s' "$disc" | jq -r '[.data.repository.discussion.labels.nodes[].name] | join(",")')"
    if [[ "$category" != "Ideas" ]]; then echo "skip #${n}: category '${category}'"; skipped=$((skipped+1)); continue; fi
    if [[ ",${labels}," == *",idea:approved,"* ]]; then echo "skip #${n}: already idea:approved"; skipped=$((skipped+1)); continue; fi
    slug="$(db_slug_from_title "$title")"
    if ! db_slug_is_valid "$slug"; then echo "skip #${n}: no valid slug from '${title}'"; skipped=$((skipped+1)); continue; fi
    if gh api "repos/${REPO}/contents/${IDEAS_DIR}/${slug}/brief.md" --jq '.sha' >/dev/null 2>&1; then
      echo "skip #${n}: ${IDEAS_DIR}/${slug}/brief.md already exists"; skipped=$((skipped+1)); continue
    fi
    if [[ -n "$(gh pr list --repo "$REPO" --head "${BRANCH_PREFIX}/${slug}" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)" ]]; then
      echo "skip #${n}: a brief PR from ${BRANCH_PREFIX}/${slug} is already open"; skipped=$((skipped+1)); continue
    fi
    if [[ "$is_dry" == "1" ]]; then
      printf '%s\n' "$(jq -nc --arg op dispatch_brief --arg central "$CENTRAL_REPO" --arg target "$REPO" \
        --argjson n "$n" --arg slug "$slug" '{op:$op, central_repo:$central, target_repo:$target, discussion:$n, slug:$slug}')" \
        >>"${DRY_RUN_LOG:-./dry-run.jsonl}"
      echo "[dry-run] would dispatch ${WORKFLOW_FILE} in ${CENTRAL_REPO} for #${n} (${slug})"
    else
      gh workflow run "$WORKFLOW_FILE" --repo "$CENTRAL_REPO" \
        -f discussion="$n" -f target_repo="$REPO" -f dry_run=false
      echo "dispatched ${WORKFLOW_FILE} for #${n} (${slug})"
    fi
    dispatched=$((dispatched+1))
  done <<<"$numbers"
  echo "ripe-from-queue: dispatched=${dispatched} skipped=${skipped} (cap ${MAX_BRIEFS})"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  set -euo pipefail
  dbq_main "$@"
fi
