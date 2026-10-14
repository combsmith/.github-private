#!/usr/bin/env bash
# sync-stub-guard.sh — a bot-driven pass on a standards-sync PR must not edit the
# org-standard stub the PR exists to sync (#2185).
#
# WHAT IS WRONG WITHOUT THIS
#   On petry-projects/incubator#164 (a `standards-sync` PR) CodeAnt asked for a
#   `pull_request: [review_requested]` trigger on the synced persona-mention.yml
#   stub. A fix-bot-comment pass added it and deleted the NOTE explaining why the
#   template omits it. dev-lead replied "Fixed", the thread was resolved, and
#   auto-merge was on. The PR no longer matched the template it syncs, and the
#   next sweep would flag it as drift and open another sync PR. The stub's own
#   header told agents not to change it; nothing in the harness enforced that.
#
# THE RULE
#   A synced stub is a file whose header (first _SSG_HEADER_LINES lines) reads
#   `SOURCE OF TRUTH: petry-projects/.github/standards/<path>`. On a PR labeled
#   `standards-sync`, a pass that changes or deletes one is:
#     clean    the stub ends byte-identical to the content the PR's first commit
#              touching it wrote (the sync commit), i.e. a restore to the template;
#     drift    any other change. The harness refuses to push, answers the bot as
#              declined with a pointer to the template, and holds the PR.
#   A stub the PR did not touch may not change at all. A synced stub can also lack
#   the header (standards/workflows/dev-lead.yml has none), so on a labeled PR
#   every path the PR's own commits changed before the pass (<merge-base>..<pre>)
#   is synced content too, header or not, under the same restore rule. Other
#   header-less files, or a SOURCE OF TRUTH outside petry-projects/.github/standards/,
#   are out of scope, and so are PRs without the label.
#
# PURITY / TESTABILITY (ADR-0004)
#   ssg_template_path, ssg_has_sync_label and ssg_declined_body are PURE.
#   ssg_pass_touches_stubs, ssg_scan_pass and ssg_evaluate are the impure
#   gatherers (git only — the caller reads the PR from the API). Sourced under
#   `set -euo pipefail`; helpers only `return`, never `exit`.

set -euo pipefail

# ttg_resolve_merge_base (#2141/#2053) — the shared shallow-safe merge-base resolver.
if ! declare -F ttg_resolve_merge_base >/dev/null; then
  # shellcheck source=scripts/lib/test-tamper-guard.sh
  source "$(dirname "${BASH_SOURCE[0]}")/test-tamper-guard.sh"
fi

# The header sits at the top of the stub; a mention deeper in the body is not one.
readonly _SSG_HEADER_LINES=20
readonly _SSG_TEMPLATE_REPO="petry-projects/.github"
readonly _SSG_SOT_RE='SOURCE OF TRUTH:[[:space:]]*petry-projects/\.github/(standards/[^[:space:]]+)'

# The label the sync generator applies (scripts/aw-standards-sync.sh).
: "${SSG_SYNC_LABEL:=standards-sync}"

# ssg_template_path <content>
#   Echoes the template path in petry-projects/.github (e.g.
#   `standards/workflows/persona-mention.yml`) when <content>'s header names a
#   SOURCE OF TRUTH under standards/; returns 1 otherwise. Pure.
ssg_template_path() {
  local content="${1:-}" line n=0
  while IFS= read -r line; do
    n=$((n + 1))
    (( n > _SSG_HEADER_LINES )) && break
    if [[ "$line" =~ $_SSG_SOT_RE ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<<"$content"
  return 1
}

# ssg_has_sync_label <labels_nl>
#   0 when one of the newline-separated labels is exactly SSG_SYNC_LABEL. Pure.
ssg_has_sync_label() {
  local labels="${1:-}" label
  while IFS= read -r label; do
    [[ "$label" == "$SSG_SYNC_LABEL" ]] && return 0
  done <<<"$labels"
  return 1
}

# ssg_declined_body <intent> <rows>
#   The PR comment that answers the bot as declined. <rows> are `path\ttemplate`
#   lines from ssg_scan_pass; empty rows mean the scan could not be verified.
#   Pure.
# shellcheck disable=SC2016  # the backticks are literal Markdown code spans
ssg_declined_body() {
  local intent="${1:-}" rows="${2:-}" path tpl list=""
  while IFS=$'\t' read -r path tpl; do
    [[ -z "${path:-}" ]] && continue
    if [[ -n "${tpl:-}" ]]; then
      list+="- \`${path}\` — template: [\`${_SSG_TEMPLATE_REPO}/${tpl}\`](https://github.com/${_SSG_TEMPLATE_REPO}/blob/main/${tpl})"$'\n'
    else
      list+="- \`${path}\` — no template header; see [\`standards/\`](https://github.com/${_SSG_TEMPLATE_REPO}/tree/main/standards) in \`${_SSG_TEMPLATE_REPO}\`"$'\n'
    fi
  done <<<"$rows"
  printf '## Declined — synced org-standard stub is read-only here\n\n'
  if [[ -n "$list" ]]; then
    printf 'The `%s` pass changed a stub this standards-sync PR copies verbatim from the org template:\n\n%s\n' "$intent" "$list"
    printf 'A suggestion to change a synced stub is declined in this repo: change the template in `%s` instead, and the next sync carries it here. dev-lead **did not push** this pass, so the PR was not changed by this pass (#2185).\n' "$_SSG_TEMPLATE_REPO"
  else
    printf 'The `%s` pass changed a synced org-standard stub on this standards-sync PR, and whether the change restores the template could not be verified (the pre-pass head, the merge base, or the PR could not be read). dev-lead **did not push** this pass (#2185).\n' "$intent"
  fi
  printf '\nA maintainer can still restore a stub to its template; any other change belongs in `%s`. Auto-merge has been disabled.\n' "$_SSG_TEMPLATE_REPO"
}

# _ssg_file_template <rev> <path>
#   Echoes the template path when <path> at <rev> is a synced stub. Impure.
_ssg_file_template() {
  local rev="$1" path="$2" content
  content=$(git --literal-pathspecs show "${rev}:${path}" 2>/dev/null | head -n "$_SSG_HEADER_LINES") || true
  [[ -n "$content" ]] || return 1
  ssg_template_path "$content"
}

# _ssg_changed_stubs <pre> <head>
#   Echoes `path\ttemplate` for every file changed in <pre>..<head> that is a
#   synced stub at <pre> or at <head>. Returns 2 when the diff cannot be read.
#   Impure.
_ssg_changed_stubs() {
  local pre="$1" head="$2" files path tpl
  files=$(git -c core.quotePath=false diff --no-renames --name-only "$pre" "$head" 2>/dev/null) || return 2
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    tpl=$(_ssg_file_template "$pre" "$path") || tpl=$(_ssg_file_template "$head" "$path") || continue
    printf '%s\t%s\n' "$path" "$tpl"
  done <<<"$files"
}

# ssg_pass_touches_stubs <pre_pass_sha> [head]
#   0 when the pass changed a file that may be synced content (a header stub, or
#   on a labeled PR any file the PR already carried, which needs the merge base to
#   tell, so any changed file qualifies), or when that cannot be determined (the
#   caller then reads the PR and ssg_scan_pass decides). 1 only when the pass
#   changed no file. Impure.
ssg_pass_touches_stubs() {
  local pre="${1:-}" head="${2:-HEAD}" files
  [[ -n "$pre" ]] || return 0
  git cat-file -e "${pre}^{commit}" 2>/dev/null || return 0
  files=$(git -c core.quotePath=false diff --no-renames --name-only "$pre" "$head" 2>/dev/null) || return 0
  [[ -n "$files" ]]
}

# ssg_scan_pass <pre_pass_sha> [head] <merge_base_sha>
#   Echoes the verdict on the first line, then `path\ttemplate` for each drifted
#   stub. Returns 0 for clean, 1 for drift, 2 (echoing `unknown`) when
#   <pre_pass_sha> does not resolve, or when the pass touches a stub and
#   <merge_base_sha> does not resolve (fail closed). Impure.
ssg_scan_pass() {
  local pre="${1:-}" head="${2:-HEAD}" mb="${3:-}"
  if [[ -z "$pre" ]] || ! git cat-file -e "${pre}^{commit}" 2>/dev/null; then
    echo "unknown"
    return 2
  fi
  local files path tpl pr_paths="" first ref_blob head_blob drift=""
  files=$(git -c core.quotePath=false diff --no-renames --name-only "$pre" "$head" 2>/dev/null) || { echo "unknown"; return 2; }
  if [[ -z "$files" ]]; then
    echo "clean"
    return 0
  fi
  if [[ -z "$mb" ]] || ! git cat-file -e "${mb}^{commit}" 2>/dev/null; then
    echo "unknown"
    return 2
  fi
  # Every path the PR's own commits touched before the pass: synced content.
  pr_paths=$(git -c core.quotePath=false log --no-renames --name-only --format= "${mb}..${pre}" 2>/dev/null) \
    || { echo "unknown"; return 2; }
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    tpl=$(_ssg_file_template "$pre" "$path") || tpl=$(_ssg_file_template "$head" "$path") || tpl=""
    if [[ -z "$tpl" ]] && ! grep -qxF -- "$path" <<<"$pr_paths"; then
      continue
    fi
    # The content the sync commit wrote: the first PR commit that touched the
    # file. A stub the PR never touched is pinned to its pre-pass content.
    first=$(git --literal-pathspecs log --reverse --format=%H "${mb}..${pre}" -- "$path" 2>/dev/null | awk 'NR == 1') \
      || { echo "unknown"; return 2; }
    ref_blob=$(git --literal-pathspecs rev-parse -q --verify "${first:-$pre}:${path}" 2>/dev/null) || ref_blob=""
    head_blob=$(git --literal-pathspecs rev-parse -q --verify "${head}:${path}" 2>/dev/null) || head_blob=""
    if [[ -n "$head_blob" && "$head_blob" == "$ref_blob" ]]; then
      continue
    fi
    drift+="${path}"$'\t'"${tpl}"$'\n'
  done <<<"$files"
  if [[ -z "$drift" ]]; then
    echo "clean"
    return 0
  fi
  echo "drift"
  printf '%s' "$drift"
  return 1
}

# ssg_evaluate <pre_pass_sha> <head> <pr_json> [head_ref]
#   The guard's single entry point. A pass that changes no file is clean
#   without reading <pr_json>. Otherwise <pr_json> (the GitHub pulls API object)
#   must parse (see the unreadable-PR rule below): a PR without the sync label is clean, a sync PR is scanned
#   against its merge base with origin/<base.ref>. Same output and return codes
#   as ssg_scan_pass; an unreadable PR or unresolvable merge base is `unknown`.
#   Impure.
ssg_evaluate() {
  local pre="${1:-}" head="${2:-HEAD}" pr_json="${3:-}" head_ref="${4:-}"
  local labels base mb=""
  if ! ssg_pass_touches_stubs "$pre" "$head"; then
    echo "clean"
    return 0
  fi
  # Unreadable = not a JSON object. An object without `labels` is a readable,
  # unlabeled PR. Accepted gap: a standards-sync PR whose header-less stub drifts
  # during an API outage is not caught (only header stubs fail closed).
  if ! jq -e 'type == "object"' <<<"$pr_json" >/dev/null 2>&1; then
    local stubs="" stubs_rc=0
    if git cat-file -e "${pre}^{commit}" 2>/dev/null; then
      stubs=$(_ssg_changed_stubs "$pre" "$head") || stubs_rc=$?
    else
      stubs_rc=2
    fi
    if [[ "$stubs_rc" -ne 0 || -n "$stubs" ]]; then
      echo "unknown"
      return 2
    fi
    echo "::warning::Sync-stub guard: PR could not be read, so the sync-stub check was skipped (no header stub touched) (#2185)" >&2
    echo "clean"
    return 0
  fi
  labels=$(jq -r '[.labels[]?.name // empty] | join("\n")' <<<"$pr_json" 2>/dev/null) || labels=""
  if ! ssg_has_sync_label "$labels"; then
    echo "clean"
    return 0
  fi
  base=$(jq -r '.base.ref // empty' <<<"$pr_json" 2>/dev/null) || base=""
  if [[ -n "$base" && -n "$pre" ]]; then
    mb=$(ttg_resolve_merge_base "$base" "$pre" "$head_ref" 2>/dev/null) || mb=""
  fi
  ssg_scan_pass "$pre" "$head" "$mb"
}
