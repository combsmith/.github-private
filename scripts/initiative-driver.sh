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
# In-flight = "actively workable" (#1494): a sub-issue paused with
# NEEDS_HUMAN_LABEL (dev-lead:needs-human) cannot progress without a human, so it
# is EXCLUDED from the in-flight count (holding a slot buys nothing and starves
# the epic — #1402 deadlocked at slots=0 for days). It is still never re-released
# while gated. A "zombie" — an open sub-issue whose DEV_LEAD_LABEL was applied
# more than STALE_HOURS ago (default 72h) with no fresh activity — is surfaced
# (log line + one idempotent epic comment) so it cannot silently occupy a slot
# forever. Labels are never auto-removed from gated/zombie items; exclude/report
# only, so human-readable state is preserved.
#
# Env:
#   REPO            owner/repo (default: petry-projects/.github-private)
#   EPIC            epic issue number, or empty to sweep all gated epics
#   CLOSED_ISSUE    issue number from an issues:closed event (optional; each
#                   epic is skipped early if it is not one of its sub-issues)
#   DEV_LEAD_LABEL  label that triggers dev-lead (default: dev-lead)
#   GATE_LABEL      opt-in label on the epic (default: initiative:auto)
#   HANDS_OFF_LABEL never-release label (default: dev-lead:hands-off)
#   HOLD_LABEL      never-release label (default: initiative:hold)
#   NEEDS_HUMAN_LABEL  human-gated label excluded from in-flight (default:
#                   dev-lead:needs-human)
#   NEEDS_HUMAN_REVIEW_LABEL  fleet hold label applied by github-actions
#                   (default: needs-human-review) — never-release (#1595)
#   STALE_HOURS     hours a dev-lead label may sit before a slot-holder is
#                   flagged a zombie (default: 72)
#   MAX_IN_FLIGHT   cap on concurrently-released sub-issues (default: 2)
#   DRY_RUN         "true" to log decisions without labeling (default: false)
#
set -euo pipefail

REPO="${REPO:-petry-projects/.github-private}"
EPIC="${EPIC:-}"
CLOSED_ISSUE="${CLOSED_ISSUE:-}"
DEV_LEAD_LABEL="${DEV_LEAD_LABEL:-dev-lead}"
GATE_LABEL="${GATE_LABEL:-initiative:auto}"
HANDS_OFF_LABEL="${HANDS_OFF_LABEL:-dev-lead:hands-off}"
HOLD_LABEL="${HOLD_LABEL:-initiative:hold}"
NEEDS_HUMAN_LABEL="${NEEDS_HUMAN_LABEL:-dev-lead:needs-human}"
NEEDS_HUMAN_REVIEW_LABEL="${NEEDS_HUMAN_REVIEW_LABEL:-needs-human-review}"

# The never-release check is the shared hold-gate predicate (scripts/lib/hold-
# gate.sh) — one source of truth across the driver, the dev-lead intent
# classifier, and any retry/sweep path (#1595 AC #3). The driver's hold set is
# the union of its configurable hold labels plus the fleet-wide needs-human-review
# hold; export it so hold_gate_first_match consults exactly this set.
# shellcheck source=scripts/lib/hold-gate.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hold-gate.sh"
HOLD_GATE_LABELS="${HOLD_GATE_LABELS:-$HANDS_OFF_LABEL $HOLD_LABEL $NEEDS_HUMAN_LABEL $NEEDS_HUMAN_REVIEW_LABEL}"
# needs-human-review is the fleet-wide hold that MUST gate at the release point
# (#1595) — a caller that narrows HOLD_GATE_LABELS must not be able to drop it
# and re-open the #1532 silent release. Force it into the set, deduped, so an
# override extends rather than replaces the required fleet hold.
case " $HOLD_GATE_LABELS " in
  *" $NEEDS_HUMAN_REVIEW_LABEL "*) ;;
  *) HOLD_GATE_LABELS="$HOLD_GATE_LABELS $NEEDS_HUMAN_REVIEW_LABEL" ;;
esac
export HOLD_GATE_LABELS
STALE_HOURS="${STALE_HOURS:-72}"
MAX_IN_FLIGHT="${MAX_IN_FLIGHT:-2}"
DRY_RUN="${DRY_RUN:-false}"

# Validate and normalize inputs before they reach arithmetic or API paths.
# EPIC may be empty (sweep mode) or a positive integer (single-epic mode).
if [[ -n "$EPIC" ]] && ! [[ "$EPIC" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::EPIC must be a positive integer or empty, got: '$EPIC'"; exit 1
fi
[[ "$MAX_IN_FLIGHT" =~ ^[0-9]+$ ]] || { echo "::error::MAX_IN_FLIGHT must be a non-negative integer, got: '$MAX_IN_FLIGHT'"; exit 1; }
[[ "$STALE_HOURS" =~ ^[0-9]+$ ]] || { echo "::error::STALE_HOURS must be a non-negative integer, got: '$STALE_HOURS'"; exit 1; }
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
readonly REPO EPIC CLOSED_ISSUE DEV_LEAD_LABEL GATE_LABEL HANDS_OFF_LABEL HOLD_LABEL NEEDS_HUMAN_LABEL NEEDS_HUMAN_REVIEW_LABEL STALE_HOURS MAX_IN_FLIGHT DRY_RUN

log() { printf '%s\n' "$*"; }

# has_label <newline-separated-labels> <name> — pure-bash exact-line match; no subprocesses.
has_label() { [[ $'\n'"${1}"$'\n' == *$'\n'"${2}"$'\n'* ]]; }

# labels_of <issue-number> — newline-separated label names.
labels_of() {
  gh api "repos/$REPO/issues/$1" --jq '.labels[].name'
}

# sub_issue_numbers <issue-number> — newline-separated native sub-issue numbers.
sub_issue_numbers() {
  if [[ $# -lt 1 ]]; then
    echo "::error::sub_issue_numbers requires an issue number" >&2
    return 1
  fi
  gh api --paginate "repos/$REPO/issues/$1/sub_issues" --jq '.[].number'
}

# last_activity_ts <issue-number> — ISO 8601 timestamp of the slot's most recent
# ACTIVITY, or "" if the issue carries no DEV_LEAD_LABEL `labeled` event (i.e. it
# is not a tracked slot). The zombie clock must reflect real progress, not just
# when the label was first applied: dev-lead records retries and progress through
# issue comments and workflow dispatches WITHOUT reapplying the label, so keying
# staleness on the `labeled` event alone would falsely flag an actively-
# progressing slot once it crossed STALE_HOURS. We therefore return the freshest
# of the last DEV_LEAD_LABEL event and the issue's `updated_at` (GitHub bumps the
# latter on comments, edits, and label changes), so any activity resets the clock.
last_activity_ts() {
  local label_ts activity_ts
  label_ts="$(gh api --paginate "repos/$REPO/issues/$1/events" \
    --jq "[.[] | select(.event==\"labeled\" and .label.name==\"$DEV_LEAD_LABEL\")] | last | .created_at // empty")"
  [[ -z "$label_ts" ]] && return 0
  activity_ts="$(gh api "repos/$REPO/issues/$1" --jq '.updated_at // empty')"
  # ISO-8601 UTC (…Z) timestamps sort chronologically as plain strings.
  if [[ -n "$activity_ts" && "$activity_ts" > "$label_ts" ]]; then
    printf '%s\n' "$activity_ts"
  else
    printf '%s\n' "$label_ts"
  fi
}

# is_stale <iso-ts> <hours> — true iff <iso-ts> is older than <hours> ago.
# An empty or unparseable timestamp is treated as NOT stale (fail safe: never
# flag a slot-holder we cannot date, to avoid false zombies).
is_stale() {
  local ts="$1" hours="$2" ts_epoch now cutoff
  [[ -z "$ts" ]] && return 1
  ts_epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || return 1
  now="$(date -u +%s)"
  cutoff=$(( now - hours * 3600 ))
  [[ "$ts_epoch" -lt "$cutoff" ]]
}

# report_zombies <epic-number> <slot-number>... — surface stale slot-holders on
# the epic with one idempotent comment (keyed on the exact zombie set), so the
# same set is not re-commented every ~25-minute run. Labels are never mutated.
report_zombies() {
  local epic="$1"; shift
  local list marker body existing
  list="$(printf '%s\n' "$@" | sort -n | tr '\n' ',' | sed 's/,$//')"
  marker="<!-- initiative-driver:zombie slots=$list -->"
  existing="$(gh api --paginate "repos/$REPO/issues/$epic/comments" --jq '.[].body' 2>/dev/null || true)"
  if grep -qF "$marker" <<< "$existing"; then
    log "Epic #$epic: zombie report already posted for slot(s) [$list] — not re-commenting."
    return 0
  fi
  if [[ "$DRY_RUN" = "true" ]]; then
    log "Epic #$epic: [dry-run] would comment zombie report for slot(s) [$list]."
    return 0
  fi
  body="$(cat <<EOF
### Initiative driver — stale in-flight slot(s) detected

The following open sub-issue(s) still carry the \`$DEV_LEAD_LABEL\` label but have
had no dev-lead activity for ≥ ${STALE_HOURS}h, so they are occupying an in-flight
slot without progressing: **#${list//,/, #}**.

No labels were changed. A human should decide whether to split-and-close, retry,
or park each one so the slot is freed for the rest of the epic.

$marker
EOF
)"
  gh issue comment "$epic" --repo "$REPO" --body "$body" >/dev/null
  log "Epic #$epic: posted zombie report for slot(s) [$list]."
}

# drive_epic <epic-number> — release the ready sub-issues of one epic.
# Returns 0 on success (including no-ops); never aborts the caller's sweep.
drive_epic() {
  local epic="$1"
  local epic_labels all_children_raw open_children_raw n n_labels labels open_blockers activity_ts hold_blocking_label gated_by
  local -a all_children open_children zombies
  local -A released
  local in_flight gated slots released_now in_epic

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
  # in-flight = "actively workable": a DEV_LEAD_LABEL carrier that is NOT gated
  # by NEEDS_HUMAN_LABEL. Gated carriers still go into released[] (never
  # re-released) but are excluded from the count so they cannot starve the epic
  # (#1494). A non-gated carrier whose label has sat past STALE_HOURS is flagged
  # a zombie: it still counts (we do not free the slot automatically), but it is
  # surfaced so a human can act.
  in_flight=0
  gated=0
  zombies=()
  open_children_raw="$(gh api --paginate "repos/$REPO/issues/$epic/sub_issues" \
      --jq '.[] | select(.state=="open") | .number')"
  if [[ -z "$open_children_raw" ]]; then
    open_children=()
  else
    mapfile -t open_children <<< "$open_children_raw"
  fi
  for n in "${open_children[@]}"; do
    n_labels="$(labels_of "$n")"
    has_label "$n_labels" "$DEV_LEAD_LABEL" || continue
    released[$n]=1
    # A carrier that is also HELD (any hold-gate label: needs-human-review,
    # dev-lead:needs-human, hands-off, initiative:hold) cannot progress without a
    # human, so — like #1494's dev-lead:needs-human case — it is excluded from the
    # in-flight count and never re-released. Counting a held carrier would let it
    # consume MAX_IN_FLIGHT and starve eligible siblings (the #1402 slots=0
    # deadlock); checking only NEEDS_HUMAN_LABEL missed the fleet-wide
    # needs-human-review hold (#1595).
    if gated_by="$(hold_gate_first_match "$n_labels")"; then
      gated=$((gated + 1))
      log "  #$n — gated: $gated_by (excluded from in-flight; needs a human)."
      continue
    fi
    in_flight=$((in_flight + 1))
    activity_ts="$(last_activity_ts "$n")"
    if is_stale "$activity_ts" "$STALE_HOURS"; then
      zombies+=("$n")
      log "  #$n — ZOMBIE: '$DEV_LEAD_LABEL' carrier, last activity ${activity_ts:-<unknown>} (≥ ${STALE_HOURS}h ago, no progress) — occupying a slot; needs a human."
    fi
  done
  log "Epic #$epic: ${#open_children[@]} open sub-issue(s); in-flight=$in_flight ($gated gated excluded); cap=$MAX_IN_FLIGHT."
  if [[ "${#zombies[@]}" -gt 0 ]]; then
    report_zombies "$epic" "${zombies[@]}"
  fi

  # ── release ready sub-issues up to the cap ──────────────────────────────────
  slots=$((MAX_IN_FLIGHT - in_flight))
  [[ "$slots" -lt 0 ]] && slots=0
  released_now=0

  for n in "${open_children[@]}"; do
    [[ "$slots" -le 0 ]] && break
    [[ -n "${released[$n]:-}" ]] && continue

    labels="$(labels_of "$n")"
    # Never release a held sub-issue. The hold set (hands-off / initiative:hold /
    # dev-lead:needs-human / needs-human-review) is the shared hold-gate predicate;
    # #1595: needs-human-review MUST block release — #1532 shipped with it attached
    # because the driver did not consult it here. Log the issue number AND the
    # blocking label so a skipped release is auditable (AC #1).
    if hold_blocking_label="$(hold_gate_first_match "$labels")"; then
      log "  #$n — skip: held by '$hold_blocking_label' (needs a human)."
      continue
    fi
    # Never release a sub-issue that is itself an epic (#882; the #934/#938
    # incident): an armed nested epic appears in the sweep and is driven on its
    # own, so the parent must skip it rather than implement it as a story.
    # Signals: it carries GATE_LABEL, or it has ≥1 native sub-issue of its own.
    # The plain `initiative` label is deliberately NOT used — initiative-planner
    # labels BOTH epics and their story sub-issues `initiative`, so it cannot
    # distinguish the two; keying on it would skip every story. GATE_LABEL is
    # checked first (no API call needed) so a transient sub-issues lookup cannot
    # block a gate-labeled nested epic from being skipped. The children fetch is
    # a direct assignment (not an `if` condition) so a transient API failure
    # trips errexit instead of being masked into a false "not an epic".
    if has_label "$labels" "$GATE_LABEL"; then
      log "  #$n — skip: is itself an epic (drive it independently)."
      continue
    fi
    n_children="$(sub_issue_numbers "$n")"
    if [[ -n "$n_children" ]]; then
      log "  #$n — skip: is itself an epic (drive it independently)."
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

  log "Epic #$epic slots: in-flight=$in_flight ($gated gated excluded), cap=$MAX_IN_FLIGHT, releasing $released_now."
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
