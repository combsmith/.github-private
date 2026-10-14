#!/usr/bin/env bash
# validate-caller-inputs.sh — caller-input ⊆ reusable-input contract guard.
# Part A of #1052 channel-skew prevention (issue #1253); regression guard for #1034.
#
# WHY THIS EXISTS
#   `pull_request` CI runs the *base-branch* caller stub, and GitHub validates a
#   reusable workflow's inputs only at startup against the **pinned** ref. So an
#   input-forwarding change to a channel-pinned caller stub (e.g.
#   `pr-review.yml@pr-review/next`, `dev-lead-reusable.yml@dev-lead/v1-next`) is
#   exercised by nothing in PR CI and only breaks post-merge (the #1034 defect).
#   This guard closes that gap.
#
# WHAT IT DOES
#   For every workflow `uses: <owner>/<repo>/.github/workflows/<wf>.yml@<ref>`
#   that carries a `with:` block, it resolves the reusable **at <ref>** and asserts
#     (a) every forwarded `with:` key is a declared `workflow_call` input there, and
#     (b) every `required: true` input is forwarded by the caller.
#   Same-repo channel tags (`dev-lead/*`, `pr-review/*`, `ci-failure-analyst/*`, …)
#   are resolved by `git fetch`-ing the ref and reading the reusable at that ref.
#   For an ADR-0007 `agent-ingress.yml` job that declares a job-level
#   `concurrency:`, it also resolves the reusable (even with no `with:` block) and
#   asserts (c) the caller's group stem does not reuse a group the reusable
#   declares at <ref> — ADR-0010's collision rule; nested caller and reusable
#   groups would otherwise block or cancel each other.
#   A ref that genuinely can't be resolved SOFT-PASSES with a logged `::warning::`
#   — never silently. Exception: a same-repo ref for an ingress job that declares a
#   concurrency group FAILS closed, since the collision rule could not be checked. Cross-repo refs (reusables hosted in another repo, e.g.
#   petry-projects/.github) are treated as unresolved here unless
#   VCI_RESOLVE_CROSS_REPO=1 opts in; the warning keeps the skip visible.
#
# USAGE
#   validate-caller-inputs.sh
#       Scan VCI_ROOT (default: repo containing this script) and validate every
#       caller. Fails loud on any resolved contract violation.
#   validate-caller-inputs.sh --pair <caller_file> <reusable_file> [uses_lineno]
#       Validate a single caller against an explicit local reusable file
#       (deterministic; used by the fixture tests).
#
# ENV
#   VCI_ROOT             Repo root to scan (default: the repo containing this script).
#   VCI_SELF_REPO        This repo's <owner>/<repo> slug (default petry-projects/.github-private).
#   VCI_RESOLVE_DIR      Test hook: resolve any ref to <dir>/<wf-basename> instead of via git.
#   VCI_RESOLVE_CROSS_REPO  Set to 1 to attempt anonymous git fetch of cross-repo reusables.

# NOTE: strict mode is enabled only in the execute-directly guard at the bottom,
# not here — so sourcing this file (the bats tests do) does not leak `set -euo
# pipefail` into the caller's shell.

# viif_group_stems / viif_job_concurrency (ADR-0010) live in the ingress if:
# guard; reuse them rather than parse concurrency groups a second way.
# shellcheck source=scripts/validate-ingress-if.sh
source "$(dirname "${BASH_SOURCE[0]}")/validate-ingress-if.sh"

# ── pure parsing helpers ─────────────────────────────────────────────────────

# vci_parse_uses <line> — if the line is a reusable-workflow `uses:`, echo
# "<owner>/<repo>\t<wf_path>\t<ref>". Otherwise echo nothing. Strips a trailing
# ` # comment` and surrounding whitespace.
vci_parse_uses() {
  local line="$1" val
  case "$line" in
    *uses:*) : ;;
    *) return 0 ;;
  esac
  val="${line#*uses:}"
  val="${val#"${val%%[![:space:]]*}"}"   # ltrim
  val="${val%%#*}"                        # strip trailing comment
  val="${val%"${val##*[![:space:]]}"}"    # rtrim
  # strip optional surrounding quotes
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  case "$val" in
    */.github/workflows/*.yml@*|\
    */.github/workflows/*.yaml@*) : ;;
    *) return 0 ;;
  esac
  local left ref repo_slug wf_path
  left="${val%@*}"
  ref="${val##*@}"
  repo_slug="${left%%/.github/workflows/*}"
  wf_path=".github/workflows/${left##*/.github/workflows/}"
  printf '%s\t%s\t%s\n' "$repo_slug" "$wf_path" "$ref"
}

# vci_with_keys_for_job <file> <uses_lineno> — print the direct `with:` keys of
# the job whose `uses:` sits on <uses_lineno>. Prints nothing if the job has no
# `with:` block. Blank lines and `#` comments are ignored.
vci_with_keys_for_job() {
  local file="$1" uses_lineno="$2"
  local -a lines
  mapfile -t lines < "$file"
  local n=${#lines[@]}
  local idx=$((uses_lineno - 1))
  [ "$idx" -ge 0 ] && [ "$idx" -lt "$n" ] || return 0

  local uses_line="${lines[idx]}" ws job_indent
  ws="${uses_line%%[![:space:]]*}"
  job_indent=${#ws}

  local i line lws ind body with_indent=-1 child_indent=-1
  for (( i = idx + 1; i < n; i++ )); do
    line="${lines[i]}"
    [ -n "${line//[[:space:]]/}" ] || continue    # skip blank
    lws="${line%%[![:space:]]*}"
    ind=${#lws}
    body="${line#"$lws"}"
    case "$body" in '#'*) continue ;; esac         # skip full-line comment

    if [ "$with_indent" -lt 0 ]; then
      # Still looking for `with:` within this job's body.
      if [ "$ind" -lt "$job_indent" ]; then
        return 0                                    # left the job without a with:
      fi
      if [ "$ind" -eq "$job_indent" ]; then
        case "$body" in
          with:*) with_indent=$ind ;;
        esac
      fi
      continue
    fi

    # Collecting children of `with:`.
    if [ "$ind" -le "$with_indent" ]; then
      return 0                                      # end of the with: block
    fi
    if [ "$child_indent" -lt 0 ]; then
      child_indent=$ind
    fi
    if [ "$ind" -eq "$child_indent" ]; then
      printf '%s\n' "${body%%:*}"                   # a direct key: `name: value`
    fi
  done
}

# vci_declared_inputs <reusable_file> — print "<name>\t<required>" for every
# declared `on.workflow_call.inputs` entry (<required> is `true` or `false`).
vci_declared_inputs() {
  local file="$1"
  local -a lines
  mapfile -t lines < "$file"
  local n=${#lines[@]} i line lws ind body

  # Locate `workflow_call:`.
  local wc_indent=-1 wc_idx=-1
  for (( i = 0; i < n; i++ )); do
    line="${lines[i]}"
    [ -n "${line//[[:space:]]/}" ] || continue
    lws="${line%%[![:space:]]*}"
    ind=${#lws}
    body="${line#"$lws"}"
    case "$body" in
      workflow_call:*) wc_idx=$i; wc_indent=$ind; break ;;
    esac
  done
  [ "$wc_idx" -ge 0 ] || return 0

  # Locate `inputs:` nested under workflow_call.
  local in_indent=-1 in_idx=-1
  for (( i = wc_idx + 1; i < n; i++ )); do
    line="${lines[i]}"
    [ -n "${line//[[:space:]]/}" ] || continue
    lws="${line%%[![:space:]]*}"
    ind=${#lws}
    body="${line#"$lws"}"
    case "$body" in '#'*) continue ;; esac
    [ "$ind" -gt "$wc_indent" ] || break            # left workflow_call
    case "$body" in
      inputs:*) in_idx=$i; in_indent=$ind; break ;;
    esac
  done
  [ "$in_idx" -ge 0 ] || return 0

  # Iterate input-name entries and read each one's `required:` flag.
  local name_indent=-1 cur_name="" cur_required="false" rv
  for (( i = in_idx + 1; i < n; i++ )); do
    line="${lines[i]}"
    [ -n "${line//[[:space:]]/}" ] || continue
    lws="${line%%[![:space:]]*}"
    ind=${#lws}
    body="${line#"$lws"}"
    case "$body" in '#'*) continue ;; esac
    [ "$ind" -gt "$in_indent" ] || break            # end of inputs block
    if [ "$name_indent" -lt 0 ]; then
      name_indent=$ind
    fi
    if [ "$ind" -eq "$name_indent" ]; then
      [ -n "$cur_name" ] && printf '%s\t%s\n' "$cur_name" "$cur_required"
      cur_name="${body%%:*}"
      cur_required="false"
    else
      case "$body" in
        required:*)
          rv="${body#required:}"
          rv="${rv#"${rv%%[![:space:]]*}"}"         # ltrim
          rv="${rv%%#*}"                            # strip comment
          rv="${rv%"${rv##*[![:space:]]}"}"         # rtrim
          rv="${rv//\"/}"; rv="${rv//\'/}"
          cur_required="$rv"
          ;;
      esac
    fi
  done
  [ -n "$cur_name" ] && printf '%s\t%s\n' "$cur_name" "$cur_required"
  return 0
}

# vci_validate <forwarded_keys> <declared> — the pure (a)+(b) contract check.
#   forwarded_keys: newline-separated forwarded `with:` key names.
#   declared:       newline-separated "<name>\t<required>" rows.
# Prints `::error::` lines for each violation; returns 1 if any, else 0.
vci_validate() {
  local keys="$1" declared="$2" rc=0 dnames k name req
  dnames="$(printf '%s\n' "$declared" | awk -F'\t' 'NF{print $1}')"

  # (a) every forwarded key must be a declared input.
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if ! printf '%s\n' "$dnames" | grep -qxF -- "$k"; then
      echo "::error::forwarded input '$k' is not a declared workflow_call input at the pinned ref"
      rc=1
    fi
  done <<< "$keys"

  # (b) every required input must be forwarded.
  while IFS=$'\t' read -r name req; do
    [ -n "$name" ] || continue
    if [ "$req" = "true" ] && ! printf '%s\n' "$keys" | grep -qxF -- "$name"; then
      echo "::error::required input '$name' is declared at the pinned ref but not forwarded by the caller"
      rc=1
    fi
  done <<< "$declared"

  return "$rc"
}

# vci_check_pair <caller_file> <uses_lineno> <reusable_file> [label] —
# validate one caller job against a resolved reusable file.
vci_check_pair() {
  local caller="$1" uses_lineno="$2" reusable="$3" label="${4:-$1}"
  local keys declared
  keys="$(vci_with_keys_for_job "$caller" "$uses_lineno")"
  declared="$(vci_declared_inputs "$reusable")"
  if vci_validate "$keys" "$declared"; then
    echo "OK: $label — forwarded inputs ⊆ declared; required inputs forwarded"
    return 0
  fi
  echo "::error::caller-inputs contract FAILED for $label" >&2
  return 1
}

# ── concurrency collision (ADR-0010) ─────────────────────────────────────────

# vci_job_for_uses <file> <uses_lineno> — print the key of the job whose `uses:`
# sits on <uses_lineno>: the nearest preceding `<key>:` line indented less than
# the `uses:` line.
vci_job_for_uses() {
  local file="$1" uses_lineno="$2" i line lws body uses_indent
  local -a lines
  mapfile -t lines < "$file"
  line="${lines[uses_lineno - 1]}"
  lws="${line%%[![:space:]]*}"
  uses_indent=${#lws}
  for (( i = uses_lineno - 2; i >= 0; i-- )); do
    line="${lines[i]}"
    [ -n "${line//[[:space:]]/}" ] || continue
    lws="${line%%[![:space:]]*}"
    body="${line#"$lws"}"
    case "$body" in '#'*) continue ;; esac
    if [ "${#lws}" -lt "$uses_indent" ]; then
      # Strip trailing comment, then try to extract job key (with or without quotes)
      body="${body%%#*}"
      body="${body%"${body##*[![:space:]]}"}"
      if [[ "$body" =~ ^([A-Za-z0-9_-]+):[[:space:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
      elif [[ "$body" =~ ^\"([A-Za-z0-9_-]+)\":[[:space:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
      elif [[ "$body" =~ ^\'([A-Za-z0-9_-]+)\':[[:space:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
      fi
      return 0
    fi
  done
}

# vci_reusable_groups <reusable_file> — print every concurrency group the
# reusable declares (workflow-level and job-level), one per line.
vci_reusable_groups() {
  yq '(.concurrency, .jobs[]?.concurrency) | select(. != null) | ((select(tag == "!!map") | .group) // .) | select(. != null) | sub("\n"; " ")' "$1" 2>/dev/null
}

# vci_check_concurrency_collision <job> <caller_group> <reusable_file> [label] —
# fail if any stem of the caller's group equals a stem of a group the reusable
# declares (viif_group_stems: the literal text before the first placeholder).
vci_check_concurrency_collision() {
  local job="$1" group="$2" reusable="$3" label="${4:-$3}" rc=0 stem rgroup rstems
  local reusable_groups group_stems
  reusable_groups="$(vci_reusable_groups "$reusable" || true)"
  rstems="$(while IFS= read -r rgroup; do
              [ -n "$rgroup" ] && viif_group_stems "$rgroup"
            done <<< "$reusable_groups" | LC_ALL=C sort -u)"
  group_stems="$(viif_group_stems "$group")"
  while IFS= read -r stem; do
    [ -n "$stem" ] || continue
    if printf '%s\n' "$rstems" | grep -qxF -- "$stem"; then
      echo "::error::ingress job '$job' concurrency group '${stem}…' collides with a group its pinned reusable declares (${label}) — nested caller/reusable groups block or cancel each other (ADR-0010)"
      rc=1
    fi
  done <<< "$group_stems"
  [ "$rc" -eq 0 ] && echo "OK: $label — ingress job '$job' concurrency group does not collide with the reusable's"
  return "$rc"
}

# ── resolution ───────────────────────────────────────────────────────────────

# vci_resolve_reusable <repo_slug> <wf_path> <ref> <out_file> — write the
# reusable's content at <ref> to <out_file>. Returns 0 on success, 1 if the ref
# could not be resolved (caller then soft-passes with a warning).
vci_resolve_reusable() {
  local repo_slug="$1" wf_path="$2" ref="$3" out="$4"
  local self="${VCI_SELF_REPO:-petry-projects/.github-private}"

  if [ -n "${VCI_RESOLVE_DIR:-}" ]; then
    local base
    base="$(basename "$wf_path")"
    if [ -f "$VCI_RESOLVE_DIR/$base" ]; then
      cp "$VCI_RESOLVE_DIR/$base" "$out"
      return 0
    fi
    return 1
  fi

  if [ "$repo_slug" = "$self" ]; then
    # Same-repo channel tag: fetch the ref, then read the file at that ref.
    if git fetch --quiet --depth=1 origin -- "$ref" 2>/dev/null \
       && git show "FETCH_HEAD:$wf_path" > "$out" 2>/dev/null; then
      return 0
    fi
    return 1
  fi

  # Cross-repo reusable (hosted in another repo). Opt-in only — see header.
  if [ "${VCI_RESOLVE_CROSS_REPO:-0}" = "1" ]; then
    if git fetch --quiet --depth=1 "https://github.com/${repo_slug}" -- "$ref" 2>/dev/null \
       && git show "FETCH_HEAD:$wf_path" > "$out" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# ── repo scan ────────────────────────────────────────────────────────────────

vci_scan_repo() {
  local root="$1" rc=0 checked=0 warned=0
  local wf tmp parsed repo_slug wf_path ref uses_lineno keys label job group
  local -a lines
  local i n

  tmp="$(mktemp)"
  trap 'rm -f "${tmp:-}"; trap - RETURN' RETURN
  shopt -s nullglob
  for wf in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml; do
    mapfile -t lines < "$wf"
    n=${#lines[@]}
    for (( i = 0; i < n; i++ )); do
      parsed="$(vci_parse_uses "${lines[i]}")"
      [ -n "$parsed" ] || continue
      IFS=$'\t' read -r repo_slug wf_path ref <<< "$parsed"
      uses_lineno=$((i + 1))

      keys="$(vci_with_keys_for_job "$wf" "$uses_lineno")"
      job="" group=""
      if [ "$(basename "$wf")" = "agent-ingress.yml" ]; then
        if ! command -v yq >/dev/null 2>&1; then
          echo "::error::caller-inputs: yq is required to validate agent-ingress.yml concurrency groups but was not found on PATH"
          return 1
        fi
        job="$(vci_job_for_uses "$wf" "$uses_lineno")"
        [ -n "$job" ] && IFS=$'\x1f' read -r group _ < <(viif_job_concurrency "$wf" "$job")
      fi
      [ -n "$keys" ] || [ -n "$group" ] || continue  # nothing forwarded, no ingress group — nothing to check

      label="$(basename "$wf") → ${repo_slug}/${wf_path}@${ref}"
      if vci_resolve_reusable "$repo_slug" "$wf_path" "$ref" "$tmp"; then
        checked=$((checked + 1))
        if [ -n "$keys" ] && ! vci_check_pair "$wf" "$uses_lineno" "$tmp" "$label"; then
          rc=1
        fi
        if [ -n "$group" ] && ! vci_check_concurrency_collision "$job" "$group" "$tmp" "$label"; then
          rc=1
        fi
      else
        echo "::warning::caller-inputs: could not resolve ${repo_slug}/${wf_path}@${ref} (referenced by $(basename "$wf")) — skipping; verify the forwarded inputs manually"
        warned=$((warned + 1))
        # Fail closed only for a same-repo ref, which must be resolvable; cross-repo
        # reusables stay soft-pass (see header) since they are never fetched by default.
        if [ -n "$group" ] && [ "$repo_slug" = "${VCI_SELF_REPO:-petry-projects/.github-private}" ]; then
          echo "::error::caller-inputs: ingress job '${job}' declares a concurrency group but ${repo_slug}/${wf_path}@${ref} could not be resolved — the ADR-0010 collision rule cannot be checked"
          rc=1
        fi
      fi
    done
  done

  echo "caller-inputs: checked=${checked} pinned ref(s); unresolved(warned)=${warned}"
  return "$rc"
}

main() {
  local root="${VCI_ROOT:-}"
  if [ -z "$root" ]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi

  if vci_scan_repo "$root"; then
    echo "caller-inputs: OK — every resolved caller forwards a valid input set."
    return 0
  fi

  echo "" >&2
  echo "caller-inputs: FAIL — a caller stub forwards inputs that do not match the reusable at its pinned ref, or an ingress concurrency group collides with the reusable's." >&2
  echo "Fix the caller's with: block, or the reusable's workflow_call.inputs at that ref (#1052/#1034); rename a colliding ingress group (ADR-0010)." >&2
  return 1
}

# Run only when executed directly, so tests can source the helpers.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  if [ "${1:-}" = "--pair" ]; then
    caller="${2:?--pair requires <caller_file>}"
    reusable="${3:?--pair requires <reusable_file>}"
    lineno="${4:-}"
    if [ -z "$lineno" ]; then
      mapfile -t _lines < "$caller"
      for (( _i = 0; _i < ${#_lines[@]}; _i++ )); do
        if [ -n "$(vci_parse_uses "${_lines[_i]}")" ]; then
          lineno=$((_i + 1))
          break
        fi
      done
    fi
    : "${lineno:?no reusable uses: line found in $caller}"
    vci_check_pair "$caller" "$lineno" "$reusable" "$caller → $reusable"
    exit $?
  fi
  main "$@"
fi
