#!/usr/bin/env bash
# Shared PR-context prefetch for the review cascade (epic #1101, Story 2 / #1103).
#
# Gather the FULL PR diff + a superset metadata JSON ONCE in review-one-pr.sh and
# persist them to files bound to PR_HEAD_SHA, exposed to the agentic tiers
# (deep / audit / single / rubber-duck) as PR_CONTEXT_DIFF_FILE and
# PR_CONTEXT_METADATA_FILE. This is a single authoritative pre-populated context
# the tiers can consume instead of each re-fetching the diff/metadata themselves.
#
# Gated DEFAULT-OFF behind PREFETCH_CONTEXT_ENABLED so the change is a safe no-op
# until explicitly enabled: when off, zero files are written and zero env vars are
# exported, keeping the tier prompts and their inputs byte-identical to
# pre-feature behavior (mirrors the DOWNSTREAM_IMPACT_ENABLED default-off idiom).
#
# This is PLUMBING ONLY (Story 2): it does not change any tier prompt. Consumers
# in Story 5 verify the persisted PR_HEAD_SHA stamp for freshness before use.

# Superset of every field the deep/audit/single and rubber-duck prompts read via
# `gh pr view`. Persisting the union — with the FULL, non-simplified
# `files` array — means no tier loses a field it uses today. This is intentionally
# richer than review-one-pr.sh's triage `_meta_fields`, which simplifies `files`
# and omits headRepository/repository/reviews/comments/commits, so the triage
# metadata copy is insufficient for the agentic tiers and one full fetch is done here.
PR_CONTEXT_METADATA_FIELDS="number,title,body,author,isDraft,baseRefName,headRefName,headRefOid,url,headRepository,headRepositoryOwner,labels,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,reviewRequests,reviews,comments,commits,closingIssuesReferences,additions,deletions,changedFiles,files"

# prefetch_pr_context <pr_url> <pr_head_sha> <full_diff_file> [out_dir]
#
#   Persists, under <out_dir> (default /tmp/cascade):
#     pr-context-diff.txt      — the FULL diff, header-stamped with PR_HEAD_SHA
#     pr-context-metadata.json — the superset metadata, stamped as .pr_head_sha
#   and exports their paths as PR_CONTEXT_DIFF_FILE / PR_CONTEXT_METADATA_FILE.
#
#   Fetch discipline (AC #4): the FULL diff is REUSED from <full_diff_file> — the
#   untruncated copy review-one-pr.sh already fetched during triage (either
#   `gh pr diff` or the per-file REST assembly on the >300-file 406 fallback) —
#   so no extra diff fetch happens here. Exactly ONE additional `gh pr view` is
#   performed for the superset metadata, because triage's metadata copy is
#   insufficient (simplified `files`, missing fields).
#
#   Gating (AC #1): a no-op returning 0 unless PREFETCH_CONTEXT_ENABLED=true.
#
#   Degradation (AC #5): a gh rate-limit on the metadata fetch returns the skip
#   sentinel 100 so the caller can take the existing skip path (exit 100) rather
#   than crashing; any other metadata-fetch failure degrades to a no-op (returns
#   0, no files, no exports) so the run continues on the tiers' own fetches. The
#   >300-file 406 case is already handled upstream (the reused diff is the REST
#   assembly), so it never reaches this helper.
prefetch_pr_context() {
  [ "${PREFETCH_CONTEXT_ENABLED:-false}" = "true" ] || return 0

  local pr_url="${1:?prefetch_pr_context: pr_url required}"
  local sha="${2:?prefetch_pr_context: pr_head_sha required}"
  local full_diff_file="${3:-}"
  local out_dir="${4:-/tmp/cascade}"

  mkdir -p "$out_dir" 2>/dev/null || true
  local diff_file="$out_dir/pr-context-diff.txt"
  local meta_file="$out_dir/pr-context-metadata.json"

  # --- Superset metadata: exactly one additional `gh pr view` ---
  local meta_err meta_json meta_stamped=false
  meta_err=$(mktemp "${TMPDIR:-/tmp}/pr-context-meta.XXXXXX") || { echo "Failed to create temp file" >&2; return 1; }
  if meta_json=$(gh pr view "$pr_url" --json "$PR_CONTEXT_METADATA_FIELDS" 2>"$meta_err"); then
    rm -f "$meta_err"
    # Stamp PR_HEAD_SHA as a top-level field so Story 5 consumers can verify
    # freshness. If jq is unavailable/errors skip the metadata file entirely so
    # the exported path always points to a properly stamped file.
    if printf '%s' "$meta_json" \
       | jq --arg sha "$sha" '. + {pr_head_sha: $sha}' > "$meta_file" 2>/dev/null; then
      meta_stamped=true
    else
      rm -f "$meta_file"
    fi
  else
    local err_content
    err_content=$(cat "$meta_err" 2>/dev/null || true)
    rm -f "$meta_err"
    if declare -F is_rate_limited >/dev/null 2>&1 && is_rate_limited "$err_content"; then
      # Graceful skip: let the caller degrade via the existing exit-100 path.
      return 100
    fi
    # Non-rate-limit failure: degrade to a no-op so the run continues.
    echo "::warning::PR context prefetch failed for $pr_url: $(head -c 300 <<< "$err_content" | tr '\n' ' ')" >&2
    return 0
  fi

  # --- Full diff: reuse the already-fetched untruncated copy (no extra fetch) ---
  {
    printf '# PR_HEAD_SHA: %s\n' "$sha"
    if [ -n "$full_diff_file" ] && [ -f "$full_diff_file" ]; then
      cat "$full_diff_file"
    fi
  } > "$diff_file"

  export PR_CONTEXT_DIFF_FILE="$diff_file"
  [ "$meta_stamped" = true ] && export PR_CONTEXT_METADATA_FILE="$meta_file"
  return 0
}

# prefetch_review_extras <pr_url> <pr_head_sha> [prior_review_sha] [out_dir]
#
#   Everything the agentic tiers would otherwise fetch for themselves: the linked
#   issues, and the commits and files since the prior review. Used when the tiers
#   have no `gh` of their own (scripts/lib/model-sandbox.sh). A failed fetch leaves a
#   note in the file, so the tier reports the gap instead of assuming nothing changed.
prefetch_review_extras() {
  local pr_url="${1:?prefetch_review_extras: pr_url required}"
  local sha="${2:?prefetch_review_extras: pr_head_sha required}"
  local prior_sha="${3:-}"
  local out_dir="${4:-/tmp/cascade}"
  local out="$out_dir/pr-context-extras.md"
  local owner_repo number issues

  owner_repo=$(echo "$pr_url" | sed -E 's|.*/([^/]+)/([^/]+)/pull/.*|\1/\2|')
  number=$(echo "$pr_url" | sed -E 's|.*/([0-9]+)$|\1|')

  mkdir -p "$out_dir" 2>/dev/null || true
  {
    printf '# Pre-fed review context for %s at %s\n\n## Linked issues\n\n' "$pr_url" "$sha"
    if issues=$(gh pr view "$number" -R "$owner_repo" --json closingIssuesReferences \
        --jq '.closingIssuesReferences[]? | "\(.repository.owner.login)/\(.repository.name) \(.number)"' 2>/dev/null); then
      [ -n "$issues" ] || printf 'None linked.\n'
      local repo issue
      while read -r repo issue; do
        [ -n "$issue" ] || continue
        printf '### %s#%s\n\n' "$repo" "$issue"
        gh issue view "$issue" -R "$repo" --json title,state,body \
          --jq '"**\(.title)** (\(.state))\n\n\(.body)\n"' 2>/dev/null \
          || printf 'Could not be fetched.\n\n'
      done <<< "$issues"
    else
      printf 'Could not be fetched.\n'
    fi
    if [ -n "$prior_sha" ]; then
      printf '\n## Since the prior review (%s)\n\n' "$prior_sha"
      gh api "repos/$owner_repo/compare/$prior_sha...$sha" \
        --jq '.commits[].commit.message, .files[].filename' 2>/dev/null \
        || printf 'Could not be fetched.\n'
    fi
  } > "$out"
  export PR_CONTEXT_EXTRAS_FILE="$out"
}

# assert_prefetch_context_fresh <pr_url> [out_dir]
#
#   HEAD-SHA freshness safeguard (epic #1101, Story 5 / #1106). Run ONCE just
#   before the agentic tiers (deep / audit / single) consume the pre-fed
#   context, this cheaply re-checks the PR's CURRENT head SHA against the SHA
#   prefetch_pr_context stamped on the pre-fed files — closing the window where a
#   force-push / new push mid-run could otherwise let a tier review stale code.
#
#   Fetch discipline (AC #4): bounded to a SINGLE lightweight
#   `gh pr view --json headRefOid` — never a full metadata/diff re-fetch.
#
#   Gating (AC #4): a no-op returning 0 (doing NO gh call) unless
#   PREFETCH_CONTEXT_ENABLED=true. Also a no-op when no pre-fed context was
#   exported (no stamp to validate).
#
#   Returns:
#     0   — flag off, nothing pre-fed, OR current head SHA still matches the
#           stamp (AC #2: pre-fed context is fresh — used as-is, no extra fetch).
#     100 — HEAD moved (AC #3): the stale pre-fed context is INVALIDATED (files
#           removed, PR_CONTEXT_* exports unset) so no tier can consume it; the
#           caller takes the exit-100 skip sentinel to retry at the new SHA (the
#           idempotency marker prevents a duplicate review).
#
#   A gh failure on the check degrades to 0 (proceed on the existing stamped
#   context) rather than crashing: the context is already SHA-bound and this is a
#   belt-and-suspenders safeguard, so a transient gh blip must not force a
#   skip/retry storm.
assert_prefetch_context_fresh() {
  [ "${PREFETCH_CONTEXT_ENABLED:-false}" = "true" ] || return 0

  local pr_url="${1:?assert_prefetch_context_fresh: pr_url required}"
  local out_dir="${2:-/tmp/cascade}"

  local meta_file="${PR_CONTEXT_METADATA_FILE:-$out_dir/pr-context-metadata.json}"
  local diff_file="${PR_CONTEXT_DIFF_FILE:-$out_dir/pr-context-diff.txt}"

  # Resolve the SHA stamped on the pre-fed context: prefer the metadata file's
  # top-level .pr_head_sha, fall back to the diff header. Neither present => no
  # pre-fed context to validate, so no-op (no gh call).
  local stamped_sha=""
  if [ -f "$meta_file" ]; then
    stamped_sha=$(jq -r '.pr_head_sha // empty' "$meta_file" 2>/dev/null || true)
  fi
  if [ -z "$stamped_sha" ] && [ -f "$diff_file" ]; then
    stamped_sha=$(sed -n '/^# PR_HEAD_SHA: /{s/^# PR_HEAD_SHA: //p;q;}' "$diff_file" 2>/dev/null || true)
  fi
  [ -n "$stamped_sha" ] || return 0

  # The single bounded freshness call (AC #4). An inconclusive fetch degrades to
  # proceed on the existing stamp rather than crashing.
  local snapshot current_sha
  snapshot=$(gh pr view "$pr_url" --json headRefOid 2>/dev/null) || return 0
  current_sha=$(printf '%s' "$snapshot" | jq -r '.headRefOid // empty' 2>/dev/null || true)
  [ -n "$current_sha" ] || return 0

  # Matched (AC #2): pre-fed context is fresh — use as-is.
  [ "$current_sha" = "$stamped_sha" ] && return 0

  # Moved (AC #3): discard the stale pre-fed context so no tier can consume it,
  # and signal the caller to take the exit-100 skip path.
  rm -f "$diff_file" "$meta_file" 2>/dev/null || true
  unset PR_CONTEXT_DIFF_FILE PR_CONTEXT_METADATA_FILE
  return 100
}
