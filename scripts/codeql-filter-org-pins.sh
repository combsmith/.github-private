#!/usr/bin/env bash
set -euo pipefail
# scripts/codeql-filter-org-pins.sh — drop CodeQL's `actions/unpinned-tag`
# results on the org's own refs from a SARIF file, and keep every other result.
#
# Why: the org pins its reusable workflows to moving channel tags on purpose,
# `uses: combsmith/<repo>/.github/workflows/<file>@<agent>/v<N>-<channel>`
# (combsmith/.github standards/ci-standards.md, "Exception: Internal Reusable
# Workflow References"). CodeQL's security-extended suite flags each one as
# `actions/unpinned-tag`, and the code_scanning rule then blocks the pull
# request. The Maintainer chose on 2026-11-24 to filter those results by owner,
# and to keep flagging third-party actions pinned by tag.
#
# Usage: codeql-filter-org-pins.sh IN.sarif OUT.sarif [SOURCE_ROOT]
#   SOURCE_ROOT  the checkout the SARIF's relative paths point into (default .)
#   ORG (env)    the owner whose refs are exempt (default combsmith)
#
# A result is dropped only when all three hold:
#   1. its rule id is `actions/unpinned-tag`;
#   2. the line it flags, read from SOURCE_ROOT, is a `uses:` whose owner is ORG;
#   3. its message ends by naming a ref under 'ORG/'.
# The line is the evidence; the message must agree, so neither a workflow name
# nor a moved region can hide a third-party action. A result that cannot be read
# this way is kept: no path, no line, a path outside SOURCE_ROOT, a missing file,
# a percent-encoded path (not decoded), or a file holding a line break that sed
# does not count but a YAML parser may (a lone CR, U+0085, U+2028, U+2029), as
# then the line numbers could disagree.
#
# Fails closed: when IN is missing or is not a SARIF log (no `runs` array, a run
# whose `results` is not an array, no run at all), it exits 2 and writes nothing,
# so the upload step that follows never runs and the CodeQL check goes red.
# codeql.yml then checks, in the workflow itself, that only org-ref
# unpinned-tag results went missing, so an edit to this script alone cannot
# hide any other result.
#
# Twin: combsmith/.github and combsmith/.github-private each carry this script
# at scripts/codeql-filter-org-pins.sh; keep the two the same apart from this
# header.

RULE_ID="actions/unpinned-tag"

die() {
  echo "codeql-filter-org-pins: $*" >&2
  exit 2
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# uses_ref_on_line LINE — print the `uses:` value on a workflow or action line
# (`uses: x`, `- uses: x`, quoted or not, a trailing comment allowed), or nothing.
uses_ref_on_line() {
  local line="$1"
  local re="^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+[\"']?([^\"'[:space:]#]+)"
  if [[ "$line" =~ $re ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

# is_org_ref REF — 0 when REF is ORG/<repo>[/<path>]@<ref>, with <repo> a plain
# repository name (not . or ..); the owner is matched without case, as GitHub
# resolves it.
is_org_ref() {
  local ref="$1" owner rest repo
  [[ "$ref" == */*@?* ]] || return 1
  owner="${ref%%/*}"
  rest="${ref#*/}"
  repo="${rest%%[/@]*}"
  [[ -n "$owner" && "$repo" =~ ^[A-Za-z0-9._-]+$ && "$repo" != "." && "$repo" != ".." ]] || return 1
  [[ "$(lower "$owner")" == "$(lower "$ORG")" ]]
}

# message_names_org_ref MESSAGE — 0 when the message's closing clause names a
# <nwo> owned by ORG. The clause is "... step [Uses Step](1) uses '<nwo>' with
# ref '<ref>', not a pinned commit hash" for a step, or "... in '<name>' uses
# reusable workflow '<nwo>' with ref ..." for a job. Anchored at the end, with
# no space or quote in <nwo>, so neither a quoted workflow name nor a crafted
# action path can supply it.
message_names_org_ref() {
  local msg="$1" nwo
  local re="(\]\([0-9]+\) uses|' uses reusable workflow) '([^'[:space:]]+)' with ref '[^']*', not a pinned commit hash\$"
  [[ "$msg" =~ $re ]] || return 1
  nwo="${BASH_REMATCH[2]}"
  [[ "$nwo" == */?* ]] || return 1
  [[ "$(lower "${nwo%%/*}")" == "$(lower "$ORG")" ]]
}

# safe_relative_path PATH — 0 for a plain relative path inside the checkout.
safe_relative_path() {
  local path="$1"
  [[ -n "$path" && "$path" != /* && "$path" != *://* ]] || return 1
  [[ "/$path/" != */../* ]]
}

# drop_reason URI LINE MESSAGE ROOT — print the flagged ref when this
# unpinned-tag result is an org ref, or nothing to keep it.
drop_reason() {
  local uri="$1" line="$2" msg="$3" root="$4" text ref
  safe_relative_path "$uri" || return 0
  [[ "$line" =~ ^[1-9][0-9]*$ ]] || return 0
  [[ -f "$root/$uri" ]] || return 0
  # A lone CR (a CR not ending its line), NEL, LS or PS: keep the result.
  if LC_ALL=C grep -q -e $'\r.' -e $'\xc2\x85' -e $'\xe2\x80\xa8' -e $'\xe2\x80\xa9' "$root/$uri"; then
    return 0
  fi
  text="$(sed -n "${line}p" "$root/$uri")"
  ref="$(uses_ref_on_line "$text")"
  [[ -n "$ref" ]] || return 0
  is_org_ref "$ref" || return 0
  message_names_org_ref "$msg" || return 0
  printf '%s\n' "$ref"
}

main() {
  [[ $# -ge 2 && $# -le 3 ]] || die "usage: codeql-filter-org-pins.sh IN.sarif OUT.sarif [SOURCE_ROOT]"
  local in="$1" out="$2" root="${3:-.}"
  ORG="${ORG:-combsmith}"
  [[ "$ORG" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "ORG '$ORG' is not a GitHub owner name"
  [[ -f "$in" && -r "$in" ]] || die "no SARIF file at '$in'"
  [[ -d "$root" ]] || die "no source root at '$root'"

  jq -e 'type == "object"
         and (.runs | type == "array" and length > 0)
         and all(.runs[]; type == "object" and ((.results // []) | type == "array"))' \
    "$in" > /dev/null 2>&1 || die "'$in' is not a SARIF log (want an object with a non-empty runs array whose results are arrays)"

  # One line per unpinned-tag result: run index, result index, path, start line,
  # message, split by the unit separator (not a tab: read would merge empty
  # fields). Newlines and separators inside a field become spaces.
  local candidates
  candidates="$(jq -r --arg rule "$RULE_ID" '
    .runs | to_entries[] | .key as $r | .value as $run
    | ($run.results // []) | to_entries[]
    | select((.value.ruleId // .value.rule.id // "") == $rule)
    | (.value.locations[0].physicalLocation // {}) as $loc
    | ($loc.artifactLocation // {}) as $art
    | [ $r, .key,
        ($art.uri // (if ($art.index | type) == "number" and $art.index >= 0
                      then $run.artifacts[$art.index].location.uri else null end) // ""),
        ($loc.region.startLine // 0),
        (.value.message.text // "") ]
    | map(tostring | gsub("[\u001f\n\r]"; " ")) | join("\u001f")' "$in")" || die "could not read the results of '$in'"

  local drops="[]" kept_tags=0 r j uri line msg ref
  while IFS=$'\x1f' read -r r j uri line msg; do
    [[ -n "$r" ]] || continue
    ref="$(drop_reason "$uri" "$line" "$msg" "$root")"
    if [[ -n "$ref" ]]; then
      drops="$(jq -c --argjson r "$r" --argjson j "$j" '. + [[$r, $j]]' <<< "$drops")"
      echo "dropped: $uri:$line uses $ref (org ref, exempt from SHA pinning)" >&2
    else
      kept_tags=$((kept_tags + 1))
      echo "kept:    $uri:$line ($RULE_ID: not an org ref, or its line could not be read)" >&2
    fi
  done <<< "$candidates"

  local before after dropped tmp
  before="$(jq '[.runs[].results // [] | length] | add // 0' "$in")"
  dropped="$(jq 'length' <<< "$drops")"
  mkdir -p "$(dirname "$out")"
  tmp="$(mktemp "$(dirname "$out")/.codeql-filter.XXXXXX")"
  if ! jq --argjson drops "$drops" \
      'delpaths([$drops[] | ["runs", .[0], "results", .[1]]])' "$in" > "$tmp"; then
    rm -f "$tmp"
    die "could not write the filtered SARIF"
  fi
  after="$(jq '[.runs[].results // [] | length] | add // 0' "$tmp")"
  if [[ "$after" -ne $((before - dropped)) ]]; then
    rm -f "$tmp"
    die "result count mismatch: $before in, $dropped dropped, $after out"
  fi
  mv "$tmp" "$out"
  echo "codeql-filter-org-pins: $before results in, $dropped org-ref $RULE_ID dropped, $kept_tags other $RULE_ID kept, $after out" >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
