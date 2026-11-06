#!/usr/bin/env bash
# Carry-forward for conflict-free base merges (issue #1865).
#
# The problem: `strict_required_status_checks_policy: true` forces every open PR
# to be up to date with the base branch, so auto-rebase.yml merges the base into
# each open PR after every merge — minting a NEW head SHA on each. pr-review keys
# its idempotency on the head SHA (#899), so each of those PRs gets a fresh full
# tier stack even though the DIFF AGAINST THE MERGE-BASE is byte-identical and the
# prior verdict still holds. Landing one PR thus forces a full re-review of every
# other open PR.
#
# The fix: when pr-review is triggered on a PR whose last recorded verdict was for
# an EARLIER head SHA, and the only intervening commits are conflict-free merges
# from the base branch that leave the diff-vs-merge-base unchanged, carry the prior
# verdict forward to the new SHA instead of re-running any model tier.
#
# FAIL TOWARD REVIEWING. Any delta that is not provably a conflict-free base merge
# — a content commit, a conflict resolution (which IS content authorship and has
# historically corrupted files here, #1482/#1485), a merge of a foreign branch, a
# changed base, or an indeterminable comparison (API failure / unparseable) — falls
# through to a normal full review. There is no path where an unknown state skips
# review (#1865 AC #4).
#
# Architecture note: the pr-review runner checks out the AGENT repo (.github-private)
# for its scripts, NOT the PR's repo (pr-review.yml "Checkout agent repo"). There are
# therefore no local git objects for the PR under review, so every comparison here is
# done through the `gh` API against the PR's repo. Diff-vs-merge-base is GitHub's
# three-dot compare (`compare/{base}...{sha}`), which — unlike diff-vs-base-tip
# (`base..sha`) — is invariant to base movement for a clean merge and is the only
# comparison that can match after the base advances (#1865 implementer note).
#
# All the pure decision helpers take JSON / files as input so they are unit-testable
# with no network; evaluate_carry_forward is the thin gh wrapper the cascade calls.

# cf_prior_decision <marker_body>
#   Echo the recorded verdict carried by the latest pr-review marker body:
#   "approved", "escalated", or "fix-requested" — or empty when none is parseable.
#   Reuses the existing per-SHA marker vocabulary (#1865 implementer note) rather
#   than adding a parallel record. The approval/escalation form carries the decision
#   inline in the v1 marker; the fix-request form carries it in a second comment.
cf_prior_decision() {
  local body="${1:-}"
  if printf '%s' "$body" | grep -qE '<!-- pr-review-agent v1 sha=[a-f0-9]+[[:space:]]+decision=approved'; then
    echo "approved"
  elif printf '%s' "$body" | grep -qE '<!-- pr-review-agent v1 sha=[a-f0-9]+[[:space:]]+decision=escalated'; then
    echo "escalated"
  elif printf '%s' "$body" | grep -qE '<!-- decision=fix-requested'; then
    echo "fix-requested"
  else
    echo ""
  fi
}

# cf_prior_risk <marker_body>
#   Echo the risk (LOW/MEDIUM/HIGH) recorded in the marker, or "LOW" if absent.
cf_prior_risk() {
  local body="${1:-}" risk
  # Single sed (exit after first match) fed by a here-string: avoids the SIGPIPE
  # (exit 141) that piping to `head -n1` can raise under `set -o pipefail`, and the
  # extra subshell a `printf | …` pipe spawns. `|| true` keeps a no-match from
  # aborting the caller under `set -e`.
  risk=$(sed -nE '/risk=(LOW|MEDIUM|HIGH)/{s/.*risk=(LOW|MEDIUM|HIGH).*/\1/;p;q;}' <<< "$body" || true)
  echo "${risk:-LOW}"
}

# cf_all_intervening_are_base_merges <compare_commits_json>
#   <compare_commits_json> is the `.commits` array from the GitHub compare API for
#   `{prior_sha}...{head_sha}` — i.e. exactly the commits reachable from head but not
#   from the previously-reviewed SHA. Exit 0 ONLY when the set is non-empty and every
#   commit is a MERGE commit (>=2 parents). A single-parent commit is author content
#   (#1865 AC #3) and an empty set means nothing actually changed (handled elsewhere).
#   On failure, prints a machine reason token to stdout.
cf_all_intervening_are_base_merges() {
  local commits_json="${1:-[]}"
  local n
  n=$(jq 'length' <<<"$commits_json" 2>/dev/null) || { echo "unparseable-commits"; return 1; }
  if [[ -z "$n" ]] || [[ "$n" = "0" ]]; then
    echo "no-intervening-commits"
    return 1
  fi
  # Any commit with fewer than two parents is a non-merge (author content) commit.
  local content_sha
  content_sha=$(jq -r '[.[] | select((.parents // [] | length) < 2)] | (.[0].sha // "")' <<<"$commits_json" 2>/dev/null) || {
    echo "unparseable-commits"
    return 1
  }
  if [[ -n "$content_sha" ]]; then
    echo "content-commit:$content_sha"
    return 1
  fi
  return 0
}

# cf_diffs_identical <file_a> <file_b>
#   Exit 0 iff the two files are byte-identical. Used to compare the raw
#   diff-vs-merge-base of the prior SHA against the current head (#1865 AC #1).
cf_diffs_identical() {
  local a="$1" b="$2"
  [[ -f "$a" ]] && [[ -f "$b" ]] || return 1
  cmp -s "$a" "$b"
}

# cf_merge_introduces_only_base <merge_files_json> <base_delta_files_json>
#   Independent conflict/content guard for a single intervening merge commit M
#   (#1865 AC #2). <merge_files_json> is M's file list from the commit API — the diff
#   of M against its FIRST parent (the PR-branch tip before the merge), each entry
#   {filename, sha} where sha is the RESULTING blob at M. <base_delta_files_json> is
#   the file list from compare({first_parent}...{base_side_parent}) — the changes the
#   base side contributed since the merge-base, each {filename, sha} where sha is the
#   base's blob.
#
#   A conflict-free merge simply applies the base's blobs onto the PR branch, so every
#   file M changed must resolve to the base's blob — i.e. M's (filename, sha) set must
#   be a SUBSET of the base delta's (filename, sha) set. If M changed any file to a
#   blob the base did not produce (a resolved conflict, an "evil merge", or content
#   authored into the merge), the subset relation breaks and we FAIL toward reviewing
#   — even if the endpoint diffs coincidentally match (AC #2 is non-negotiable). This
#   is deliberately conservative: a clean merge that combines non-overlapping edits to
#   the SAME file yields a hybrid blob that is not the base's blob, so it too falls to
#   a full review — safe, never unsafe.
#   Exit 0 iff every file changed by the merge resolves to a base-produced blob.
cf_merge_introduces_only_base() {
  local merge_files="${1:-[]}" base_delta="${2:-[]}"
  jq -e -n --argjson m "$merge_files" --argjson b "$base_delta" '
    ($m // [] | map({filename, sha})) as $mf
    | ($b // [] | map({filename: .filename, sha: .sha})) as $bf
    # Every file the merge touched must appear in the base delta with the same
    # resulting blob sha. any-missing => author content in the merge => not clean.
    | ($mf | map(. as $x | ($bf | any(.filename == $x.filename and .sha == $x.sha))) | all)
  ' >/dev/null 2>&1
}

# cf_parent_in_base <compare_status>
#   <compare_status> is the `.status` field of compare({base_side_parent}...{base_tip}).
#   The base-side parent is contained in (an ancestor of) the base branch iff the base
#   tip is "ahead" of or "identical" to it. "diverged"/"behind" means the merge pulled
#   in a branch that is NOT the base branch — foreign content — so we fail toward
#   reviewing. Enforces "merges/fast-forwards FROM THE BASE BRANCH" (#1865).
cf_parent_in_base() {
  case "${1:-}" in
    ahead|identical) return 0 ;;
    *) return 1 ;;
  esac
}

# evaluate_carry_forward <owner_repo> <base_ref> <prior_sha> <head_sha>
#   The gh wrapper the cascade calls. Echoes exactly one line:
#     carry          — the prior verdict is safe to carry forward to <head_sha>
#     full:<reason>  — fall through to a full review; <reason> is a machine token
#   NEVER errors out and NEVER echoes anything else: every indeterminate condition
#   (API failure, empty/unparseable response) maps to full:<reason> (#1865 AC #4).
evaluate_carry_forward() {
  local repo="$1" base_ref="$2" prior_sha="$3" head_sha="$4"
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cf-XXXXXX")" || { echo "full:tmp-failure"; return 0; }

  # Resolve the base tip to a SHA once, so both endpoint diffs compare against the
  # SAME merge-base input and branch names with slashes never corrupt the compare
  # URL path.
  local base_tip
  base_tip=$(gh api "repos/$repo/commits/$base_ref" --jq '.sha' 2>/dev/null) || base_tip=""
  if [[ -z "$base_tip" ]]; then
    rm -rf "$tmp"
    echo "full:base-tip-unresolved"
    return 0
  fi

  # 1. Intervening commits: every one must be a merge commit (no author content).
  #    --paginate follows the compare endpoint's Link headers so a long base-merge
  #    treadmill is not silently truncated into a false carry; each page is a JSON
  #    object, slurped into an array and flattened to the full commit list.
  local compare_json commits_json reason total_commits collected
  compare_json=$(gh api --paginate "repos/$repo/compare/$prior_sha...$head_sha?per_page=100" 2>/dev/null) || compare_json=""
  if [[ -z "$compare_json" ]]; then
    rm -rf "$tmp"
    echo "full:compare-api-error"
    return 0
  fi
  commits_json=$(jq -sc '[.[].commits[]?]' <<<"$compare_json" 2>/dev/null) || commits_json=""
  if [[ -z "$commits_json" ]]; then
    rm -rf "$tmp"
    echo "full:compare-unparseable"
    return 0
  fi
  # The compare API caps at 250 commits even under pagination (`total_commits` reports
  # the true count). If it exceeds what we actually collected, commits were omitted —
  # fail toward reviewing rather than carry an approval over an unverified commit.
  total_commits=$(jq -s '.[0].total_commits // 0' <<<"$compare_json" 2>/dev/null) || total_commits=0
  collected=$(jq 'length' <<<"$commits_json" 2>/dev/null) || collected=0
  if [ "${total_commits:-0}" -gt "${collected:-0}" ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
    rm -rf "$tmp"
    echo "full:compare-truncated"
    return 0
  fi
  if ! reason=$(cf_all_intervening_are_base_merges "$commits_json"); then
    rm -rf "$tmp"
    echo "full:${reason:-not-all-merges}"
    return 0
  fi

  # 2. Diff-vs-merge-base must be byte-identical between the prior SHA and head.
  local diff_prior="$tmp/prior.diff" diff_head="$tmp/head.diff"
  if ! gh api "repos/$repo/compare/$base_tip...$prior_sha" \
        -H "Accept: application/vnd.github.v3.diff" >"$diff_prior" 2>/dev/null; then
    rm -rf "$tmp"; echo "full:diff-api-error"; return 0
  fi
  if ! gh api "repos/$repo/compare/$base_tip...$head_sha" \
        -H "Accept: application/vnd.github.v3.diff" >"$diff_head" 2>/dev/null; then
    rm -rf "$tmp"; echo "full:diff-api-error"; return 0
  fi
  if ! cf_diffs_identical "$diff_prior" "$diff_head"; then
    rm -rf "$tmp"
    echo "full:diff-changed"
    return 0
  fi

  # 3. Per-merge independent conflict/content guard: each merge must pull in only the
  #    base branch's blobs, and its base-side parent must be contained in the base
  #    branch. This is what makes AC #2 hold even when the endpoint diffs match.
  local count i m_sha parents p1 p2 merge_files base_delta cmp_status
  count=$(jq 'length' <<<"$commits_json" 2>/dev/null) || count=0
  i=0
  while [ "$i" -lt "$count" ]; do  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
    # Guard every jq substitution with `|| var=""`: under `set -e` an unguarded jq
    # failure (unparseable/unexpected JSON) would abort mid-loop and leak $tmp. An
    # empty result is caught by the emptiness check below and fails toward reviewing.
    m_sha=$(jq -r ".[$i].sha // \"\"" <<<"$commits_json" 2>/dev/null) || m_sha=""
    parents=$(jq -c ".[$i].parents // []" <<<"$commits_json" 2>/dev/null) || parents=""
    p1=$(jq -r '.[0].sha // ""' <<<"$parents" 2>/dev/null) || p1=""
    p2=$(jq -r '.[1].sha // ""' <<<"$parents" 2>/dev/null) || p2=""
    if [[ -z "$m_sha" ]] || [[ -z "$p1" ]] || [[ -z "$p2" ]]; then
      rm -rf "$tmp"; echo "full:merge-parents-unresolved"; return 0
    fi
    # More than two parents (octopus merge) is unusual for a base merge — fail safe.
    if [[ "$(jq 'length' <<<"$parents" 2>/dev/null)" != "2" ]]; then
      rm -rf "$tmp"; echo "full:octopus-merge"; return 0
    fi

    # The base-side parent (p2) must be an ancestor of the base tip.
    cmp_status=$(gh api "repos/$repo/compare/$p2...$base_tip" --jq '.status' 2>/dev/null) || cmp_status=""
    if [[ -z "$cmp_status" ]]; then
      rm -rf "$tmp"; echo "full:parent-compare-error"; return 0
    fi
    if ! cf_parent_in_base "$cmp_status"; then
      rm -rf "$tmp"; echo "full:foreign-merge"; return 0
    fi

    # The merge must introduce ONLY the base's blobs (no resolved-conflict content).
    # --paginate follows the Link headers so a merge/compare with >300 changed files
    # is fully enumerated; each page emits a `[{filename,sha}]` array which `jq -s add`
    # concatenates, so a truncated page can't hide a non-base blob and mint a false carry.
    merge_files=$(gh api --paginate "repos/$repo/commits/$m_sha?per_page=100" --jq '[.files[]? | {filename, sha}]' 2>/dev/null | jq -sc 'add // []' 2>/dev/null) || merge_files=""
    base_delta=$(gh api --paginate "repos/$repo/compare/$p1...$p2?per_page=100" --jq '[.files[]? | {filename, sha}]' 2>/dev/null | jq -sc 'add // []' 2>/dev/null) || base_delta=""
    if [[ -z "$merge_files" ]] || [[ -z "$base_delta" ]]; then
      rm -rf "$tmp"; echo "full:merge-files-error"; return 0
    fi
    if ! cf_merge_introduces_only_base "$merge_files" "$base_delta"; then
      rm -rf "$tmp"
      echo "full:conflict-or-content:$m_sha"
      return 0
    fi
    i=$((i + 1))
  done

  rm -rf "$tmp"
  echo "carry"
  return 0
}
