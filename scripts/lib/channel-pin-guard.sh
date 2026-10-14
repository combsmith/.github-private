#!/usr/bin/env bash
# channel-pin-guard.sh — a dev-lead pass must never change a caller stub's
# first-party channel pin (#2220).
#
# WHAT IS WRONG WITHOUT THIS
#   On #2157 and #1796 a pass "fixed" a red, non-required `template-drift` check
#   by re-seeding .github/workflows/dev-lead.yml from the standards template. That
#   repinned this repo's caller stub from `dev-lead/v139-ring0` to the legacy
#   `dev-lead/v1-stable` channel (a 2026-09-22 release, 70 commits behind) and
#   deleted the comment explaining the pin. The tag exists, so nothing failed at
#   startup, and `pull_request*` events take the workflow file from the PR, so the
#   PR's own dev-lead passes already ran the old release. The prompt guardrail
#   ("never SHA-pin a first-party channel ref") does not cover a repin to another
#   channel, and nothing in the harness stopped a pass editing its own stub.
#
# THE RULE
#   A channel-pinned file is a `.github/workflows/*.yml|*.yaml` file that, at the
#   pre-pass head, has a first-party `uses: combsmith/…@<ref>` or an
#   `agent_ref: <ref>` whose <ref> is a moving channel tag (cpg_is_channel_ref).
#   A pass that changes that file's pin list (cpg_pins) is:
#     clean    the pin list is unchanged (comment/body edits are fine), or equals
#              the file's pin list on <base_rev> (a rebase adopting the base
#              branch's promotion, or restoring a bad repin to main's pin);
#     drift    any other change: a repin, an agent_ref change, a SHA pin, or the
#              file's deletion. The harness refuses to push and escalates.
#   Channel moves are made by moving tags centrally (cut-release.sh), never by a
#   pass editing a caller.
#
# PURITY / TESTABILITY (ADR-0004)
#   cpg_is_channel_ref, cpg_pins and cpg_refused_body are PURE. cpg_scan_pass is
#   the impure gatherer (git only). cpg_flag_refused is the escalation (gh).
#   Sourced under `set -euo pipefail`; helpers only `return`, never `exit`.

set -euo pipefail

# apply_hold_label / post_hold_failure_note / disable_auto_merge_for_hold (#2142).
if ! declare -F apply_hold_label >/dev/null; then
  # shellcheck source=scripts/lib/hold-label.sh
  source "$(dirname "${BASH_SOURCE[0]}")/hold-label.sh"
fi

# Guarded so a script that sources this lib twice (directly and via another
# script) does not trip over the readonly declarations.
if [[ -z "${_CPG_CHANNEL_RE:-}" ]]; then
  # <agent>/v<N>-<tier> (dev-lead/v139-ring0, pr-review/v1-next) and the legacy
  # un-majored <agent>/<tier> (dev-lead/stable).
  readonly _CPG_CHANNEL_RE='^[A-Za-z0-9._-]+/(v[0-9]+-)?[A-Za-z0-9]+$'
  readonly _CPG_USES_RE='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["'"'"']?(combsmith/[^@[:space:]"'"'"']+@[^[:space:]"'"'"'#]+)'
  readonly _CPG_AGENT_REF_RE='^[[:space:]]*agent_ref:[[:space:]]*["'"'"']?([^[:space:]"'"'"'#]+)'
fi

# cpg_is_channel_ref <ref>
#   0 when <ref> is a moving channel tag. Pure.
cpg_is_channel_ref() {
  [[ "${1:-}" =~ $_CPG_CHANNEL_RE ]]
}

# cpg_pins <content>
#   Echoes `uses\t<repo/path>@<ref>` for each first-party reusable call and
#   `agent_ref\t<ref>` for each agent_ref, in file order. Comment lines never
#   match. Pure.
cpg_pins() {
  local content="${1:-}" line
  while IFS= read -r line; do
    if [[ "$line" =~ $_CPG_USES_RE ]]; then
      printf 'uses\t%s\n' "${BASH_REMATCH[2]}"
    elif [[ "$line" =~ $_CPG_AGENT_REF_RE ]]; then
      printf 'agent_ref\t%s\n' "${BASH_REMATCH[1]}"
    fi
  done <<<"$content"
}

# _cpg_has_channel_pin <pins> — 0 when any pin in a cpg_pins list is a channel ref.
_cpg_has_channel_pin() {
  local kind val
  while IFS=$'\t' read -r kind val; do
    [[ -z "${kind:-}" ]] && continue
    [[ "$kind" == "uses" ]] && val="${val##*@}"
    cpg_is_channel_ref "$val" && return 0
  done <<<"${1:-}"
  return 1
}

# _cpg_summary <pins> — one-line `kind value, kind value` form for messages.
_cpg_summary() {
  local pins="${1:-}"
  [[ -n "$pins" ]] || { printf '<none>'; return 0; }
  printf '%s\n' "$pins" | tr '\t' ' ' | paste -sd ',' - | sed 's/,/, /g'
}

# _cpg_pins_at <rev> <path> — cpg_pins of <path> at <rev>; empty when absent.
_cpg_pins_at() {
  local content
  content=$(git --literal-pathspecs show "${1}:${2}" 2>/dev/null) || return 0
  cpg_pins "$content"
}

# cpg_scan_pass <pre_pass_sha> [head] [base_rev]
#   Echoes the verdict on the first line, then `path\tbefore\tafter` for each
#   channel-pinned file whose pins the pass changed (`after` is `<deleted>` for a
#   removed file). Returns 0 for clean, 1 for drift, 2 (echoing `unknown`) when
#   <pre_pass_sha> does not resolve or the diff cannot be read (fail closed).
#   <base_rev> (e.g. origin/main) is optional; when it resolves, ending on the
#   base's own pins is clean. Impure.
cpg_scan_pass() {
  local pre="${1:-}" head="${2:-HEAD}" base="${3:-}"
  if [[ -z "$pre" ]] || ! git cat-file -e "${pre}^{commit}" 2>/dev/null; then
    echo "unknown"
    return 2
  fi
  if [[ -n "$base" ]] && ! git rev-parse -q --verify "${base}^{commit}" >/dev/null 2>&1; then
    base=""
  fi
  local files path before after drift=""
  files=$(git -c core.quotePath=false diff --no-renames --name-only "$pre" "$head" -- .github/workflows 2>/dev/null) \
    || { echo "unknown"; return 2; }
  while IFS= read -r path; do
    case "$path" in
      *.yml|*.yaml) ;;
      *) continue ;;
    esac
    before=$(_cpg_pins_at "$pre" "$path")
    if git --literal-pathspecs cat-file -e "${head}:${path}" 2>/dev/null; then
      after=$(_cpg_pins_at "$head" "$path")
      if ! _cpg_has_channel_pin "$before"; then
        # A file the base branch added, or newly pinned, arrives with the base's
        # own pins when a pass merges or rebases onto it: that is not drift.
        if _cpg_has_channel_pin "$after" \
           && ! { [[ -n "$base" ]] && [[ "$after" == "$(_cpg_pins_at "$base" "$path")" ]]; }; then
          drift+="${path}"$'\t'"$(_cpg_summary "$before")"$'\t'"$(_cpg_summary "$after")"$'\n'
        fi
        continue
      fi
      [[ "$after" == "$before" ]] && continue
      if [[ -n "$base" && -n "$after" && "$after" == "$(_cpg_pins_at "$base" "$path")" ]]; then
        continue
      fi
      drift+="${path}"$'\t'"$(_cpg_summary "$before")"$'\t'"$(_cpg_summary "$after")"$'\n'
    else
      _cpg_has_channel_pin "$before" || continue
      drift+="${path}"$'\t'"$(_cpg_summary "$before")"$'\t'"<deleted>"$'\n'
    fi
  done <<<"$files"
  if [[ -z "$drift" ]]; then
    echo "clean"
    return 0
  fi
  echo "drift"
  printf '%s' "$drift"
  return 1
}

# cpg_refused_body <intent> <rows>
#   The PR comment for a refused pass. <rows> are `path\tbefore\tafter` lines from
#   cpg_scan_pass; empty rows mean the scan could not be verified. Pure.
# shellcheck disable=SC2016  # the backticks are literal Markdown code spans
cpg_refused_body() {
  local intent="${1:-}" rows="${2:-}" path before after list=""
  while IFS=$'\t' read -r path before after; do
    [[ -z "${path:-}" ]] && continue
    list+="- \`${path}\`: \`${before}\` → \`${after}\`"$'\n'
  done <<<"$rows"
  printf '## Refused — a caller stub'"'"'s channel pin is read-only to dev-lead\n\n'
  if [[ -n "$list" ]]; then
    printf 'The `%s` pass changed the first-party channel pin of a caller stub:\n\n%s\n' "$intent" "$list"
  else
    printf 'The `%s` pass changed a workflow file, and whether it kept every first-party channel pin could not be verified (the pre-pass head could not be read).\n\n' "$intent"
  fi
  printf 'dev-lead **did not push** this pass (#2220). A caller stub'"'"'s `uses:` ref and `agent_ref` select which dev-lead/pr-review release runs; they move only when a maintainer moves the channel tag (`scripts/cut-release.sh`) or edits the stub in a reviewed PR. Never repin a stub to clear a check — a red `template-drift` concerns `combsmith/repo-template`, not this repository'"'"'s stubs.\n'
  printf '\nAuto-merge has been disabled.\n'
}

# cpg_flag_refused <intent> <rows>
#   Escalate a refused pass on PR_NUMBER in REPO: hold label, the refused body
#   (once per intent, marker-keyed), auto-merge off. Mirrors flag_sync_stub_drift.
#   Never fails the caller.
cpg_flag_refused() {
  local intent="$1" rows="${2:-}"
  _AM_NEEDS_RESTORE=0
  if [[ "${DEV_LEAD_DRY_RUN:-false}" == "true" ]]; then
    echo "[dry-run] channel-pin guard: would refuse on PR #${PR_NUMBER} (${intent}), add ${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review}, disable auto-merge"
    return 0
  fi
  if [[ -z "${PR_NUMBER:-}" || -z "${REPO:-}" ]]; then
    echo "::warning::channel-pin guard: no PR to escalate on — the push was refused, nothing else done (#2220)"
    return 0
  fi
  local marker="<!-- dev-lead-channel-pin-refused pr=${PR_NUMBER} intent=${intent} -->"
  # Label first so the flag comment can say when the PR could not be held (#2142).
  apply_hold_label "$REPO" "$PR_NUMBER" || true
  if gh api --paginate "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
       | jq -r '.[].body // ""' 2>/dev/null | grep -qF "$marker"; then
    echo "::notice::PR #${PR_NUMBER} already flagged for a channel-pin change for intent=${intent} — not reposting"
    post_hold_failure_note "$REPO" "$PR_NUMBER" || true
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "${marker}
$(cpg_refused_body "$intent" "$rows")${HOLD_LABEL_NOTE:-}" \
      || echo "::warning::could not post channel-pin flag comment on PR #${PR_NUMBER}"
  fi
  disable_auto_merge_for_hold "$REPO" "$PR_NUMBER" || true
  return 0
}
