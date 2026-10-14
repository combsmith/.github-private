#!/usr/bin/env bash
#
# initiative-driver.sh — dependency-aware label dispatcher for initiative epics.
#
# Turns an epic's sub-issue dependency graph (native GitHub "blocked by"
# relationships) into dev-lead pickups: it applies the `dev-lead` label to each
# OPEN sub-issue whose blockers are ALL closed, bounded by a max-in-flight cap.
# The dev-lead agent triggers on issues:[labeled]; this script is the only thing
# that decides WHEN that label goes on, so the per-item agent stays unchanged.
#
# Event-driven chain: dev-lead merges a PR -> "Closes #N" closes the issue ->
# this driver (on issues:[closed]) re-evaluates the DAG -> labels the now-ready
# successors. The schedule cron is only a safety net for missed close events.
#
# EPIC selection — single epic or sweep:
#   - EPIC set (a number)  -> drive just that epic (targeted/dry-run/dispatch).
#   - EPIC empty/unset     -> SWEEP: discover every OPEN issue carrying
#                             GATE_LABEL and drive each. This is what the
#                             automatic triggers (schedule / issues:closed /
#                             issues:labeled) use, so the driver is no longer
#                             pinned to a single hard-coded epic — any epic a
#                             maintainer arms with `initiative:auto` is picked
#                             up automatically.
#
# IMPORTANT — the trigger requires a PAT, not GITHUB_TOKEN:
#   GitHub does not start new workflow runs from events created by the default
#   GITHUB_TOKEN (loop prevention). The `dev-lead` label MUST be applied with a
#   PAT (GH_PAT_WORKFLOWS) or the resulting issues:[labeled] event will NOT
#   trigger dev-lead.yml. (Same class of bug as pr-review #463.)
#
# Safety gates:
#   - The epic must carry GATE_LABEL (default: initiative:auto). Without it the
#     driver no-ops, so Phase 1 stays human-driven until you opt in. In sweep
#     mode this is the discovery filter; in single-epic mode it is re-checked.
#   - Issues carrying HANDS_OFF_LABEL (dev-lead:hands-off) or HOLD_LABEL
#     (initiative:hold) are never released — they need a human.
#   - MAX_IN_FLIGHT bounds how many sub-issues run at once, per epic
#     (cost / blast radius).
#
# Env:
#   REPO            owner/repo (default: combsmith/.github-private)
#   EPIC            epic issue number, or empty to sweep all gated epics
#   CLOSED_ISSUE    issue number from an issues:closed event (optional; each
#                   epic is skipped early if it is not one of its sub-issues)
#   DEV_LEAD_LABEL  label that triggers dev-lead (default: dev-lead)
#   GATE_LABEL      opt-in label on the epic (default: initiative:auto)
#   HANDS_OFF_LABEL never-release label (default: dev-lead:hands-off)
#   HOLD_LABEL      never-release label (default: initiative:hold)
#   MAX_IN_FLIGHT   cap on concurrently-released sub-issues (default: 2)
#   DRY_RUN         "true" to log decisions without labeling (default: false)
#
set -euo pipefail

REPO="${REPO:-combsmith/.github-private}"
EPIC="${EPIC:-}"
CLOSED_ISSUE="${CLOSED_ISSUE:-}"
DEV_LEAD_LABEL="${DEV_LEAD_LABEL:-dev-lead}"
GATE_LABEL="${GATE_LABEL:-initiative:auto}"
HANDS_OFF_LABEL="${HANDS_OFF_LABEL:-dev-lead:hands-off}"
HOLD_LABEL="${HOLD_LABEL:-initiative:hold}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-2}"
DRY_RUN="${DRY_RUN:-false}"

# Validate and normalize inputs before they reach arithmetic or API paths.
# EPIC may be empty (sweep mode) or a positive integer (single-epic mode).
if [[ -n "$EPIC" ]] && ! [[ "$EPIC" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::EPIC must be a positive integer or empty, got: '$EPIC'"; exit 1
fi
[[ "$MAX_IN_FLIGHT" =~ ^[0-9]+$ ]] || { echo "::error::MAX_IN_FLIGHT must be a non-negative integer, got: '$MAX_IN_FLIGHT'"; exit 1; }
if [[ -n "$CLOSED_ISSUE" ]] && ! [[ "$CLOSED_ISSUE" =~ ^[0-9]+$ ]]; then
  echo "::warning::CLOSED_ISSUE is not a valid issue number ('$CLOSED_ISSUE') — treating as unset."
  CLOSED_ISSUE=""
fi
DRY_RUN="${DRY_RUN,,}"
case "$DRY_RUN" in
  true|1|yes)  DRY_RUN=true  ;;
  false|0|no)  DRY_RUN=false ;;
  *) echo "::error::DRY_RUN must be true or false, got: '$DRY_RUN'"; exit 1 ;;
esac
readonly REPO EPIC CLOSED_ISSUE DEV_LEAD_LABEL GATE_LABEL HANDS_OFF_LABEL HOLD_LABEL MAX_IN_FLIGHT DRY_RUN

log() { printf '%s\n' "$*"; }

# has_label <newline-separated-labels> <name> — pure-bash exact-line match; no subprocesses.
has_label() { [[ $'\n'"${1}"$'\n' == *$'\n'"${2}"$'\n'* ]]; }

# labels_of <issue-number> — newline-separated label names.
labels_of() {
  gh api "repos/$REPO/issues/$1" --jq '.labels[].name'
}

# drive_epic <epic-number> — release the ready sub-issues of one epic.
# Returns 0 on success (including no-ops); never aborts the caller's sweep.
drive_epic() {
  local epic="$1"
  local epic_labels all_children_raw open_children_raw n n_labels labels open_blockers
  local -a all_children open_children
  local -A released
  local in_flight slots released_now in_epic

  # ── gate: the epic must opt in ──────────────────────────────────────────────
  epic_labels="$(labels_of "$epic")"
  if ! has_label "$epic_labels" "$GATE_LABEL"; then
    log "Gate '$GATE_LABEL' not on epic #$epic — no-op (Phase-1 human-driven). Add the label to activate."
    return 0
  fi

  # ── enumerate sub-issues (all states) ───────────────────────────────────────
  all_children_raw="$(gh api --paginate "repos/$REPO/issues/$epic/sub_issues" --jq '.[].number')"
  if [[ -z "$all_children_raw" ]]; then
    all_children=()
  else
    mapfile -t all_children <<< "$all_children_raw"
  fi
  if [[ "${#all_children[@]}" -eq 0 ]]; then
    log "Epic #$epic has no sub-issues — nothing to drive."
    return 0
  fi

  # ── on a close event, only act if the closed issue belongs to this epic ─────
  if [[ -n "$CLOSED_ISSUE" ]]; then
    in_epic=false
    for n in "${all_children[@]}"; do
      [[ "$n" = "$CLOSED_ISSUE" ]] && in_epic=true && break
    done
    if [[ "$in_epic" != true ]]; then
      log "Closed issue #$CLOSED_ISSUE is not a sub-issue of epic #$epic — no-op."
      return 0
    fi
  fi

  # ── count in-flight (released but not yet closed) ───────────────────────────
  in_flight=0
  open_children_raw="$(gh api --paginate "repos/$REPO/issues/$epic/sub_issues" \
      --jq '.[] | select(.state=="open") | .number')"
  if [[ -z "$open_children_raw" ]]; then
    open_children=()
  else
    mapfile -t open_children <<< "$open_children_raw"
  fi
  for n in "${open_children[@]}"; do
    n_labels="$(labels_of "$n")"
    if has_label "$n_labels" "$DEV_LEAD_LABEL"; then
      released[$n]=1
      in_flight=$((in_flight + 1))
    fi
  done
  log "Epic #$epic: ${#open_children[@]} open sub-issue(s); in-flight=$in_flight; cap=$MAX_IN_FLIGHT."

  # ── release ready sub-issues up to the cap ──────────────────────────────────
  slots=$((MAX_IN_FLIGHT - in_flight))
  [[ "$slots" -lt 0 ]] && slots=0
  released_now=0

  for n in "${open_children[@]}"; do
    [[ "$slots" -le 0 ]] && break
    [[ -n "${released[$n]:-}" ]] && continue

    labels="$(labels_of "$n")"
    if has_label "$labels" "$HANDS_OFF_LABEL"; then
      log "  #$n — skip: $HANDS_OFF_LABEL (needs a human)."
      continue
    fi
    if has_label "$labels" "$HOLD_LABEL"; then
      log "  #$n — skip: $HOLD_LABEL (held)."
      continue
    fi

    open_blockers="$(
      gh api "repos/$REPO/issues/$n/dependencies/blocked_by" \
        --jq '[.[] | select(.state=="open") | .number] | join(",")'
    )"
    if [[ -n "$open_blockers" ]]; then
      log "  #$n — blocked by open: [$open_blockers]."
      continue
    fi

    if [[ "$DRY_RUN" = "true" ]]; then
      log "  #$n — READY (dry-run, not labeling)."
    else
      gh issue edit "$n" --repo "$REPO" --add-label "$DEV_LEAD_LABEL" >/dev/null
      log "  #$n — RELEASED: applied '$DEV_LEAD_LABEL'."
    fi
    slots=$((slots - 1))
    released_now=$((released_now + 1))
  done

  log "Released this run for epic #$epic: $released_now."
}

# ── entrypoint: single epic, or sweep all gated epics ─────────────────────────
if [[ -n "$EPIC" ]]; then
  drive_epic "$EPIC"
  exit 0
fi

log "No EPIC given — sweeping all open epics carrying '$GATE_LABEL'."
epics_raw="$(gh api --paginate -X GET "repos/$REPO/issues" \
    -f state=open -f labels="$GATE_LABEL" \
    --jq '.[] | select(.pull_request|not) | .number')"
if [[ -z "$epics_raw" ]]; then
  log "No open epics carry '$GATE_LABEL' — nothing to drive."
  exit 0
fi
mapfile -t epics <<< "$epics_raw"
log "Found ${#epics[@]} gated epic(s): ${epics[*]}"

rc=0
for e in "${epics[@]}"; do
  log "──────── Driving epic #$e ────────"
  # Run each epic in a standalone subshell with errexit ON so a gh failure
  # aborts that epic instead of being silently masked, while the parent (errexit
  # OFF for the call) keeps sweeping the rest. NOTE: `drive_epic "$e" || …` would
  # NOT work — Bash disables `set -e` inside a function invoked in an OR/if/&&
  # context, letting an API failure fall through as a false "no sub-issues".
  set +e
  ( set -e; drive_epic "$e" )
  ec=$?
  set -e
  if [[ "$ec" -ne 0 ]]; then
    rc=1
    echo "::error::driver failed for epic #$e"
  fi
done
exit "$rc"
