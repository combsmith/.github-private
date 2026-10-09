#!/usr/bin/env bash
# Pure downstream-impact mapping helper for the PR-review cascade (issue #750,
# epic #748).
#
# Given a PR's changed-file list and the consumer manifest (Story 1,
# scripts/lib/consumer-manifest.json), this answers a single question with NO
# network / `gh` I/O: which shared surfaces did these files touch, and which
# org repos (consumers) pin those surfaces? Keeping it pure makes the impact
# computation deterministic and unit-testable in isolation (mirrors the
# jq-program style of scripts/lib/review-cycle.sh).
#
# Matching is single-hop and EXACT-path (issue #653) — no prefix/glob/transitive
# source-graph expansion. Two and only two match kinds:
#   (a) a changed reusable-workflow path that a consumer ref pins exactly
#       (after normalising the manifest's provider prefix) -> direct surface;
#   (b) a changed scripts/lib/*.sh, scripts/lib/*.tsv, prompts/* or config/*.json path listed in a reusable's
#       surface_sources -> that reusable surface -> the reusable's consumers.
#
# A consumer ref is provider-prefixed (e.g. ".github-private/.github/workflows/
# pr-review.yml") while a surface is identified by its repo-relative path
# (".github/workflows/pr-review.yml", the surface_sources key form). Normalising
# strips the longest matching declared provider prefix so the helper is
# provider-agnostic — it never hardcodes which provider repo it runs in.
#
# Output (always a single well-formed JSON object on stdout):
#   {
#     "impacted_surfaces":  [ "<repo-relative reusable path>", ... ],   # sorted, unique
#     "impacted_consumers": [ { "repo": "...", "via": ["<surface>", ...] }, ... ],
#     "unmatched":          [ "<changed path with no shared surface>", ... ]
#   }
#
# Defensive degradation (same philosophy as compute_review_cycle returning 0 on
# bad input): a missing/unreadable/malformed manifest, an empty changed-file
# list, or any jq failure yields the empty-but-well-formed object below rather
# than a non-zero exit that would break the cascade.

# jq program shared by the one public function. Inputs:
#   $changed : JSON array of changed paths (de-duplicated, blanks removed)
#   $m       : slurpfile array; $m[0] is the manifest object
_DOWNSTREAM_IMPACT_JQ='
  ($m[0] // {}) as $man
  | ($man.providers // []) as $providers
  | ($man.consumers // []) as $consumers
  | ($man.surface_sources // {}) as $sources
  | ($changed // []) as $changed

  # Normalise a consumer ref to its repo-relative surface key by stripping the
  # longest matching declared provider prefix. Null if no provider matches.
  | def strip_provider($ref):
      ( [ $providers[] as $p | select($ref | startswith($p + "/")) | $p ]
        | sort_by(length) | reverse | .[0] ) as $p
      | if $p == null then null else ($ref | ltrimstr($p + "/")) end;

  # The full set of repo-relative surfaces any consumer pins.
  ( [ $consumers[].refs[]? | strip_provider(.) | select(. != null) ] | unique ) as $pinned_surfaces

  # (a) Direct: a changed workflow path that is itself a pinned surface.
  | ( [ $changed[] | select(. as $c | $pinned_surfaces | index($c) != null) ] ) as $direct_surfaces

  # (b) Indirect: surface_sources keys whose value list contains a changed path.
  | ( [ $sources | to_entries[]
        | select(.value as $v | any($changed[]; . as $c | $v | index($c) != null))
        | .key ] ) as $indirect_surfaces

  | (($direct_surfaces + $indirect_surfaces) | unique) as $impacted_surfaces

  # Changed paths that matched neither kind.
  | ( [ $changed[]
        | . as $c
        | select(($pinned_surfaces | index($c) != null) | not)
        | select(($sources | to_entries | any(.value as $v | $v | index($c) != null)) | not) ]
      | unique ) as $unmatched

  # Consumers carrying at least one impacted surface, with the surfaces (via).
  | ( [ $consumers[]
        | .repo as $repo
        | ( [ .refs[]? | strip_provider(.) | select(. != null) ] ) as $repo_surfaces
        | ( [ $impacted_surfaces[] | select(. as $s | $repo_surfaces | index($s) != null) ] ) as $via
        | select($via | length > 0)
        | { repo: $repo, via: $via } ]
      | sort_by(.repo) ) as $impacted_consumers

  | { impacted_surfaces: $impacted_surfaces,
      impacted_consumers: $impacted_consumers,
      unmatched: $unmatched }
'

# compute_downstream_impact <changed_files> <manifest>
#   <changed_files> : newline-delimited list of changed repo-relative paths.
#   <manifest>      : path to the consumer manifest JSON.
#   Prints the impact object (see header) to stdout; always exits 0.
compute_downstream_impact() {
  local changed_raw="${1:-}"
  local manifest="${2:-}"
  local empty='{"impacted_surfaces":[],"impacted_consumers":[],"unmatched":[]}'

  # Manifest must exist and be valid JSON, else degrade.
  if [ -z "$manifest" ] || [ ! -f "$manifest" ] || ! jq empty "$manifest" 2>/dev/null; then
    printf '%s\n' "$empty"
    return 0
  fi

  # Build the changed-file JSON array: split on newlines, drop blank lines,
  # de-duplicate. printf '%s' (no trailing newline) avoids a spurious empty tail.
  local changed_json
  changed_json=$(printf '%s' "$changed_raw" \
    | jq -R -s 'split("\n") | map(select(length > 0)) | unique' 2>/dev/null) || changed_json='[]'
  [ -n "$changed_json" ] || changed_json='[]'

  local out
  out=$(jq -n \
    --argjson changed "$changed_json" \
    --slurpfile m "$manifest" \
    "$_DOWNSTREAM_IMPACT_JQ" 2>/dev/null) || out="$empty"
  [ -n "$out" ] || out="$empty"
  printf '%s\n' "$out"
}

# Run `gh` for consumer-repo reads. Cross-org reads need the bot PAT surfaced as
# GH_PAT in pr-review.yml; prefer it, falling back to whatever auth gh already
# has (GH_TOKEN). No new secret is introduced (issue #751 dev note).
_downstream_gh() {
  if [ -n "${GH_PAT:-}" ]; then
    GH_TOKEN="$GH_PAT" gh "$@"
  else
    gh "$@"
  fi
}

# _downstream_referencing_files <repo> <surfaces_newline>
#   Lists <repo>'s .github/workflows/*, fetches each, and prints the paths of the
#   workflow files whose body references any of the given repo-relative surface
#   paths (the consumer's `uses:` line embeds the surface path as a substring).
#   Output: one matching workflow path per line.
#   Exit status: 0 on a readable repo (even with zero matches); 2 if the repo's
#   workflow directory could not be read (private/unreadable/missing scope) so
#   the caller can emit an explicit "unreadable" note and keep the cascade alive.
_downstream_referencing_files() {
  local repo="$1" surfaces="$2"
  local listing rc=0
  listing=$(_downstream_gh api "repos/$repo/contents/.github/workflows" \
    --jq '.[].path' 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 2
  fi

  local wf content_b64 content surface
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    case "$wf" in *.yml|*.yaml) : ;; *) continue ;; esac
    content_b64=$(_downstream_gh api "repos/$repo/contents/$wf" \
      --jq '.content' 2>/dev/null) || continue
    if [ -z "$content_b64" ] || [ "$content_b64" = "null" ]; then
      continue
    fi
    content=$(printf '%s' "$content_b64" | tr -d '\r\n' | jq -Rr '@base64d' 2>/dev/null) || continue
    [ -n "$content" ] || continue
    while IFS= read -r surface; do
      [ -n "$surface" ] || continue
      if [[ "$content" == *"$surface"* ]]; then
        printf '%s\n' "$wf"
        break
      fi
    done <<< "$surfaces"
  done <<< "$listing"
  return 0
}

# assemble_downstream_impact <changed_files> <manifest> [out_file]
#   <changed_files> : newline-delimited list of changed repo-relative paths.
#   <manifest>      : path to the consumer manifest JSON.
#   <out_file>      : where to write the block (default: $DOWNSTREAM_IMPACT_FILE
#                     or /tmp/cascade/downstream-impact.txt).
#
#   Calls the pure mapper, then fetches each impacted consumer's referencing
#   workflow file(s) via `gh`, and writes a human-readable DOWNSTREAM_IMPACT
#   block to <out_file>, whose path is exported as DOWNSTREAM_IMPACT_FILE for the
#   triage/deep tiers (mirroring ADVISORY_BOT_FEEDBACK_FILE in review-one-pr.sh).
#
#   Bounded fetch volume (issue #751 AC#4):
#     - only the exact-matched consumers are fetched,
#     - capped at DOWNSTREAM_IMPACT_MAX_REPOS repos per PR (default 10),
#     - the assembled block is truncated to DOWNSTREAM_IMPACT_MAX_BYTES bytes
#       (default 8000, mirroring the 8 KB ADVISORY_BOT_FEEDBACK cap).
#
#   Graceful degradation (AC#2/#3): no impacted surfaces -> literal "(none)" with
#   zero fetches; a private/unreadable consumer or missing token scope -> an
#   explicit "unreadable" note for that entry. Always exits 0 — a fetch failure
#   must never break the cascade.
assemble_downstream_impact() {
  local changed_raw="${1:-}"
  local manifest="${2:-}"
  local max_repos="${DOWNSTREAM_IMPACT_MAX_REPOS:-10}"
  local max_bytes="${DOWNSTREAM_IMPACT_MAX_BYTES:-8000}"
  local out_file="${3:-${DOWNSTREAM_IMPACT_FILE:-/tmp/cascade/downstream-impact.txt}}"

  mkdir -p "$(dirname "$out_file")" 2>/dev/null || true
  rm -f "$out_file"

  local impact
  impact=$(compute_downstream_impact "$changed_raw" "$manifest")

  # No impacted surfaces -> literal "(none)", no fetches performed (AC#2).
  local surfaces
  surfaces=$(printf '%s' "$impact" | jq -r '.impacted_surfaces[]?' 2>/dev/null) || surfaces=''
  if [ -z "$surfaces" ]; then
    printf '%s' "(none)" > "$out_file"
    export DOWNSTREAM_IMPACT_FILE="$out_file"
    return 0
  fi

  local total
  total=$(printf '%s' "$impact" | jq -r '.impacted_consumers | length' 2>/dev/null) || total=0
  [ -n "$total" ] || total=0

  local block
  block="Impacted shared surfaces:"$'\n'
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    block+="  - $s"$'\n'
  done <<< "$surfaces"
  block+=$'\n'"Impacted consumers ($total, fetching up to $max_repos):"$'\n'

  # Iterate the exact-matched consumers, capped at max_repos (AC#4). The mapper
  # sorts consumers by repo, so the cap is deterministic.
  local consumers
  consumers=$(printf '%s' "$impact" \
    | jq -c --argjson n "$max_repos" '.impacted_consumers[0:$n][]?' 2>/dev/null) || consumers=''

  local entry repo via_surfaces files rc via_inline
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    repo=$(printf '%s' "$entry" | jq -r '.repo' 2>/dev/null) || continue
    via_surfaces=$(printf '%s' "$entry" | jq -r '.via[]?' 2>/dev/null)
    via_inline="${via_surfaces//$'\n'/,}"
    block+="  - $repo (pins $via_inline)"$'\n'

    rc=0
    files=$(_downstream_referencing_files "$repo" "$via_surfaces") || rc=$?
    if [ "$rc" -ne 0 ]; then
      block+="      unreadable"$'\n'
      echo "::warning::downstream-impact: $repo unreadable (private repo or missing token scope) — degrading to 'unreadable'" >&2
    elif [ -z "$files" ]; then
      block+="      (none)"$'\n'
    else
      local f
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        block+="      $f"$'\n'
      done <<< "$files"
    fi
  done <<< "$consumers"

  if [ "$total" -gt "$max_repos" ]; then
    block+=$'\n'"($((total - max_repos)) more consumer(s) not fetched; repo cap=$max_repos)"$'\n'
  fi

  # Cap total size so a huge consumer set cannot blow up the prompt (AC#4),
  # mirroring the 8 KB ADVISORY_BOT_FEEDBACK cap in review-one-pr.sh.
  block="${block:0:max_bytes}"
  printf '%s' "$block" > "$out_file"
  export DOWNSTREAM_IMPACT_FILE="$out_file"
  return 0
}

# downstream_impact_triage_section [impact_file]
#   Emits the DOWNSTREAM_IMPACT section that review-one-pr.sh inlines into the
#   triage prompt (issue #752). Triage has NO tools, so — like ADVISORY_BOT_FEEDBACK
#   — the block must be inlined as text rather than read from a file path.
#
#   <impact_file> : the assembled block written by assemble_downstream_impact
#                   (default: $DOWNSTREAM_IMPACT_FILE).
#
#   Gating (Story 5 cost cap): prints NOTHING unless DOWNSTREAM_IMPACT_ENABLED is
#   "true", so with the flag off the triage prompt is byte-identical to
#   pre-feature behavior. With the flag on:
#     - a non-empty block (not the literal "(none)") is inlined under a header
#       that frames downstream impact as an informational signal to annotate —
#       explicitly NOT an auto-escalation trigger (mirrors how ADVISORY findings
#       are weighed, not auto-escalated);
#     - a missing/empty/"(none)" block emits a "DOWNSTREAM_IMPACT: (none)" marker
#       with no consumer list, so triage sees "no downstream impact" and the
#       verdict carries no downstream note.
downstream_impact_triage_section() {
  [ "${DOWNSTREAM_IMPACT_ENABLED:-false}" = "true" ] || return 0
  local impact_file="${1:-${DOWNSTREAM_IMPACT_FILE:-}}"
  local block=''
  if [ -n "$impact_file" ] && [ -f "$impact_file" ]; then
    block=$(cat "$impact_file")
  fi
  if [ -n "${block//[[:space:]]/}" ] && [ "$block" != "(none)" ]; then
    printf '\nDOWNSTREAM_IMPACT (this change touches a reusable workflow / lib / prompt that downstream repos pin — annotate the impacted consumers below; this is informational, NOT an auto-escalation trigger):\n%s\n' "$block"
  else
    printf '\nDOWNSTREAM_IMPACT: (none)\n'
  fi
}
