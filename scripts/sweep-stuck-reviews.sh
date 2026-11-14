#!/usr/bin/env bash
# sweep-stuck-reviews.sh — re-trigger reviews for PRs that went green after a skip.
#
# The pr-review cascade legitimately SKIPS a PR whose CI is pending or failing
# (decision: skip, reason: ci-pending | ci-failing) and relies on a later
# `check_suite:completed` event to re-evaluate it. But when CI settles green
# AFTER the last review trigger fired — common while dev-lead is actively
# pushing fixes / re-running CI — no event re-fires, and the PR sits at
# REVIEW_REQUIRED with green CI, never re-reviewed (issue #573).
#
# This sweep closes that gap. It enumerates open PRs and re-dispatches a review
# for each one that is:
#   • reviewDecision == REVIEW_REQUIRED   (GitHub still wants a review), AND
#   • CI status == passing                (own pr-review checks filtered out via
#                                          lib/ci-status.sh, same as the cascade), AND
#   • NOT already resolved at the current head by a STANDING verdict — either a
#                                          standing approval (a non-dismissed
#                                          state==APPROVED review carrying the
#                                          approval marker, #1665) or a terminal
#                                          escalated/fix-requested verdict — so
#                                          genuine no-ops aren't re-fired. A bare
#                                          `decision=approved` MARKER in a dismissed
#                                          review or an issue comment does NOT count.
# A marker present at head but WITHOUT a verdict is an orphan (issue #1548): the
# review crashed after stamping the head and before posting any decision. That PR
# is re-dispatched WITH force_review to bypass review-one-pr.sh's idempotency
# no-op on the orphan marker — otherwise it strands silently forever. The
# force_review input is the NARROW idempotency bypass (FORCE_RE_REVIEW), not the
# human @mention break-glass (FORCE_REVIEW): it clears ONLY the same-SHA marker and
# leaves the CI/advisory/maintainer gates armed, so a rescue can never bypass a
# quality gate and a CI status that went red since this sweep's snapshot is
# re-validated when review-one-pr.sh runs (issue #1590).
# Each selected PR is re-dispatched with `-f pr_url=<url>`; review-one-pr.sh
# remains the authoritative gate, so the sweep only decides WHAT to re-trigger.
#
# Fleet routing (#2530). Candidates come from the whole org (list-prs.sh). A PR in
# this repository goes through TRIGGER_WORKFLOW, as before. A PR in another repo
# goes to that repo's OWN pr-review entrypoint (an active pr-review.yml, else an
# active agent-ingress.yml — ADR-0007), so it is reviewed at the channel that repo
# pins, not at this repository's `next`. A repo with neither keeps the old path
# through TRIGGER_WORKFLOW here. ADR-0017 records the hub and its credential.
#
# Dispatch budget (#2530). MAX_DISPATCH used to be spent before consumer repos were
# reached: list-prs.sh puts .github/.github-private first, and their PRs held at the
# maintainer-comment gate were re-dispatched every tick only to skip again with no
# verdict. Now (a) candidates are taken round-robin across repos, and (b) a PR the
# comment gate would hold is not dispatched — the same check review-one-pr.sh runs
# first. dev-lead-retry's bot-comment scan still nudges dev-lead on those PRs, and
# once the gate clears the next sweep dispatches them.
#
# IMPORTANT — the re-dispatch requires a PAT, not GITHUB_TOKEN:
#   GitHub does not start new workflow runs from a workflow_dispatch fired with
#   the default GITHUB_TOKEN (loop prevention). The caller MUST provide a PAT
#   with workflow scope as GH_TOKEN. Same constraint as
#   scripts/initiative-planner/redispatch.sh.
#
# Env:
#   AGENT_REPO        owner/repo hosting the trigger workflow (default: combsmith/.github-private)
#   TRIGGER_WORKFLOW  workflow file to dispatch (default: pr-review-trigger.yml)
#   SWEEP_PRS_FILE    optional file of candidate PR URLs (one per line); when
#                     unset, candidates are enumerated via list-prs.sh
#   MAX_DISPATCH      cap on review dispatches per sweep (default: 20)
#   DRY_RUN           "true"/"1" → log selections but never dispatch
#   GITHUB_REF        passed through as --ref when it is a branch/tag (feature testing);
#                     applies to dispatches in AGENT_REPO only
#   ROUTE_TO_REPO_ENTRYPOINT  "false" → send every PR through TRIGGER_WORKFLOW (default: true)
#   SKIP_GATE_HELD    "false" → dispatch PRs the comment gate holds, as before (default: true)
#   DEFER_ADVISORY_WAIT "false" → dispatch a PR the advisory gate would hold, as before (default: true)
#   CONSUMER_MANIFEST consumer manifest naming the pr-review consumers that delayed
#                     retries may be armed for (default: lib/consumer-manifest.json)
#   GH_TOKEN          a PAT with workflow scope on AGENT_REPO and the consumer repos
#                     (required at the call site)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CI gate: compute_ci_status filters the cascade's own check runs before
# classifying, exactly as review-one-pr.sh does (issue #469).
# shellcheck source=lib/ci-status.sh
source "$SCRIPT_DIR/lib/ci-status.sh"
# Escalation gate (#946): pr_has_escalation_label / NEEDS_HUMAN_REVIEW_LABEL.
# shellcheck source=lib/pr-automation-budget.sh
source "$SCRIPT_DIR/lib/pr-automation-budget.sh"
# Standing-approval primitive (#1665): pr_standing_approval_count — the
# authoritative "does an approving review STAND at head?" check. A `decision=
# approved` marker in a DISMISSED review or an issue comment is NOT a standing
# approval, so it must never satisfy the stop condition.
# shellcheck source=lib/standing-approval.sh
source "$SCRIPT_DIR/lib/standing-approval.sh"
# Pure arming decision and consumer lookup for the delayed retry (#2533).
# shellcheck source=lib/delayed-retry-arming.sh
source "$SCRIPT_DIR/lib/delayed-retry-arming.sh"

AGENT_REPO="${AGENT_REPO:-combsmith/.github-private}"
TRIGGER_WORKFLOW="${TRIGGER_WORKFLOW:-pr-review-trigger.yml}"
MAX_DISPATCH="${MAX_DISPATCH:-20}"
ROUTE_TO_REPO_ENTRYPOINT="${ROUTE_TO_REPO_ENTRYPOINT:-true}"
SKIP_GATE_HELD="${SKIP_GATE_HELD:-true}"

# Validate MAX_DISPATCH is a positive integer; fall back to the default otherwise.
case "$MAX_DISPATCH" in
  ''|*[!0-9]*) MAX_DISPATCH=20 ;;
esac
[ "$MAX_DISPATCH" -gt 0 ] || MAX_DISPATCH=20

if [[ "${DRY_RUN:-}" == "1" || "${DRY_RUN:-}" == "true" ]]; then
  DRY_RUN_BOOL=true
else
  DRY_RUN_BOOL=false
fi

# Scheduled (cron) backstop mode (#1408). On the schedule event the sweep is the
# GUARANTEED backstop for genuinely UN-eventable cases only — GitHub-App /
# cross-repo checks (e.g. SonarCloud) that emit no workflow_run this repo can key
# on. A stuck-green PR whose green state is fully determined by EVENTABLE GitHub
# Actions checks is already owned by the workflow_run fast path, so the cron must
# not re-review it. The narrowing is scheduled-only: the workflow_run fast path,
# workflow_dispatch, and explicit SWEEP_PRS_FILE runs keep the original selection.
if [[ "${GITHUB_EVENT_NAME:-}" == "schedule" ]]; then
  SCHEDULED_SWEEP=true
else
  SCHEDULED_SWEEP=false
fi

# Deterministic delayed-retry arming (#1994). When the sweep DEFERS a rate-limited
# PR whose reset is still in the future but within DELAYED_RETRY_HORIZON_SEC, it
# arms pr-review-delayed-retry.yml to fire close to <reset> instead of relying on
# the best-effort schedule cron (which GitHub drops under load — observed 3-7 h
# instead of 15 min, #1952). A reset BEYOND the horizon is left to the cron
# backstop. ARM_DELAYED_RETRY=false disables arming — the mode the delayed retry
# itself uses when it delegates back to this sweep, so a retry can never re-arm.
#
# Deadline-armed retries for consumer repos (#2533). The same retry is armed for
# the advisory gate's head-age wait (waiting-for-advisory-bots): the gate proceeds
# once the head commit is older than ADVISORY_HEAD_AGE_TIMEOUT_SEC, so the sweep
# defers such a PR and arms the retry for that time. Both waits are armed for PRs
# in this repository and in every pr-review consumer (CONSUMER_MANIFEST); the retry
# re-enters this sweep, which sends a consumer PR to its own entrypoint.
# DEFER_ADVISORY_WAIT=false dispatches advisory-held PRs as before.
ARM_DELAYED_RETRY="${ARM_DELAYED_RETRY:-true}"
DELAYED_RETRY_WORKFLOW="${DELAYED_RETRY_WORKFLOW:-pr-review-delayed-retry.yml}"
DELAYED_RETRY_HORIZON_SEC="${DELAYED_RETRY_HORIZON_SEC:-3600}"
case "$DELAYED_RETRY_HORIZON_SEC" in
  ''|*[!0-9]*) DELAYED_RETRY_HORIZON_SEC=3600 ;;
esac
DEFER_ADVISORY_WAIT="${DEFER_ADVISORY_WAIT:-true}"
CONSUMER_MANIFEST="${CONSUMER_MANIFEST:-$SCRIPT_DIR/lib/consumer-manifest.json}"

# Use GITHUB_REF as --ref only when it is a branch or tag (supports testing on
# feature branches); a pull-request merge ref is not dispatchable.
REF_FLAGS=()
if [[ -n "${GITHUB_REF:-}" && ( "$GITHUB_REF" =~ ^refs/heads/ || "$GITHUB_REF" =~ ^refs/tags/ ) ]]; then
  REF_FLAGS=(--ref "$GITHUB_REF")
fi

# rate_limit_remaining — "<graphql> <core>" points left for GH_TOKEN, or empty when
# unreadable. Read before candidate discovery and again at the end, so the reported
# cost includes list-prs.sh's org-wide enumeration (#2530).
rate_limit_remaining() {
  gh api rate_limit --jq '"\(.resources.graphql.remaining) \(.resources.core.remaining)"' 2>/dev/null || true
}
rate_before=$(rate_limit_remaining)

# ---------------------------------------------------------------------------
# 1. Gather candidate PR URLs
# ---------------------------------------------------------------------------
candidates_file="$(mktemp)"
trap 'rm -f "$candidates_file"' EXIT

# prs_from_workflow_run_event <event_json_path>
# Event-driven fast path: when the sweep is kicked by a `workflow_run: completed`
# event (a CI workflow just finished), scope the candidate set to the PR(s)
# attached to that run instead of enumerating the whole fleet. Emits one PR
# html_url per line from `.workflow_run.pull_requests[]`. Pure (reads a JSON file,
# no network), so it is unit-testable.
#
# GitHub populates `pull_requests` only for SAME-repo head branches; fork-PR runs
# and plain pushes to a branch carry an empty array and yield nothing — those are
# covered by the scheduled (cron) sweep, and this repo never self-reviews forks.
prs_from_workflow_run_event() {
  local event_path="${1:-}"
  [ -n "$event_path" ] && [ -r "$event_path" ] || return 0
  # Single jq pass: bind the repo, drop out (empty stream) when it is absent, and
  # format the PR urls in one go — one process, one read of the payload.
  jq -r '
    (.repository.full_name // "") as $repo
    | select($repo != "")
    | (.workflow_run.pull_requests // [])
    | map(select(.number != null) | .number)
    | unique
    | .[]
    | "https://github.com/\($repo)/pull/\(.)"
  ' "$event_path" 2>/dev/null || true
}

# interleave_by_repo
# Reorder PR URLs on stdin round-robin across repos (#2530): the first PR of each
# repo, then the second of each, and so on. Repos keep the order of their first
# appearance and each repo keeps its own order, so list-prs.sh's priority and
# oldest-first ordering survive, but one repo's backlog can no longer use up
# MAX_DISPATCH before another repo is inspected. Blank lines are dropped. Pure.
interleave_by_repo() {
  awk '
    NF == 0 { next }
    {
      repo = $0
      if (match($0, /^https?:\/\/[^\/]+\/[^\/]+\/[^\/]+\//)) repo = substr($0, 1, RLENGTH)
      if (!(repo in count)) { order[++repos] = repo; count[repo] = 0 }
      queue[repo, ++count[repo]] = $0
    }
    END {
      for (round = 1; ; round++) {
        printed = 0
        for (i = 1; i <= repos; i++) {
          r = order[i]
          if (round <= count[r]) { print queue[r, round]; printed = 1 }
        }
        if (!printed) break
      }
    }'
}

if [[ -n "${SWEEP_PRS_FILE:-}" && -r "${SWEEP_PRS_FILE}" ]]; then
  grep -v '^[[:space:]]*$' "$SWEEP_PRS_FILE" > "$candidates_file" || true
elif [[ "${GITHUB_EVENT_NAME:-}" == "workflow_run" && -n "${GITHUB_EVENT_PATH:-}" ]]; then
  # CI-completion kick (#898): inspect only the completing run's PR(s). The
  # REVIEW_REQUIRED + CI-green + not-reviewed-at-head gate below still decides, so
  # a too-early fire (some checks still pending) simply skips and the next
  # completing workflow re-fires. The scheduled sweep remains the backstop, so
  # this fast path can never strand a PR if it matches nothing — but the cron is
  # best-effort (GitHub delays or drops scheduled runs under load, #1952); the
  # time-bound rate-limit case is covered by the armed delayed retry (#1994).
  prs_from_workflow_run_event "$GITHUB_EVENT_PATH" > "$candidates_file" || true
else
  bash "$SCRIPT_DIR/list-prs.sh" > "$candidates_file" || true
fi

interleaved_file="$(mktemp)"
trap 'rm -f "$candidates_file" "$interleaved_file"' EXIT
interleave_by_repo < "$candidates_file" > "$interleaved_file" && cp "$interleaved_file" "$candidates_file"

candidate_count=$(grep -c . "$candidates_file" || true)
echo "=== PR Review Sweep — re-trigger stuck-green reviews ==="
echo "  Trigger:    $TRIGGER_WORKFLOW @ $AGENT_REPO"
echo "  Candidates: $candidate_count"
echo "  Dry run:    $DRY_RUN_BOOL"
echo ""


# ---------------------------------------------------------------------------
# 2. Select stuck-green PRs and re-dispatch
# ---------------------------------------------------------------------------
inspected=0
stuck=0
dispatched=0
armed=0
held=0
declare -A DISPATCHED_BY_REPO=()
declare -A ENTRYPOINT_BY_REPO=()
declare -A ENTRYPOINT_FORCE_BY_REPO=()

# entrypoint_dispatch_inputs <workflow_yaml>
# Print the input names declared under on.workflow_dispatch.inputs, one per line.
# Only that block counts, so a `pr_url:` under a job's `with:` is not an input.
# An indentation walk, not a full YAML parse: enough for the caller stubs. Pure.
entrypoint_dispatch_inputs() {
  awk '
    /^[[:space:]]*(#.*)?$/ { next }
    {
      match($0, /^ */); ind = RLENGTH; line = substr($0, ind + 1)
      if (state == 2 && ind <= in_ind) state = (ind <= wd_ind) ? 0 : 1
      if (state == 1 && ind <= wd_ind) state = 0
    }
    state == 2 {
      if (key_ind == 0) key_ind = ind
      if (ind == key_ind && line ~ /^[A-Za-z0-9_-]+:/) { k = line; sub(/:.*/, "", k); print k }
      next
    }
    state == 1 && line ~ /^inputs:[[:space:]]*(#.*)?$/ { state = 2; in_ind = ind; key_ind = 0; next }
    state == 0 && line ~ /^workflow_dispatch:[[:space:]]*(#.*)?$/ { state = 1; wd_ind = ind; next }
  ' <<< "${1:-}"
}

# pr_review_job_block <workflow_yaml>
# Print the job block(s) under `jobs:` that call the pr-review reusable, so a check
# on what that job passes is not satisfied by another job. An indentation walk,
# like entrypoint_dispatch_inputs. Pure.
pr_review_job_block() {
  awk '
    function flush() { if (block ~ /\/\.github\/workflows\/pr-review\.yml@/) print block; block = "" }
    /^[[:space:]]*(#.*)?$/ { next }
    { match($0, /^ */); ind = RLENGTH; line = substr($0, ind + 1) }
    !injobs { if (line ~ /^jobs:[[:space:]]*(#.*)?$/) { injobs = 1; jobs_ind = ind; job_ind = 0 } ; next }
    ind <= jobs_ind { flush(); injobs = 0; next }
    job_ind == 0 { job_ind = ind }
    ind == job_ind { flush(); block = $0; next }
    { block = block "\n" $0 }
    END { flush() }
  ' <<< "${1:-}"
}

# entrypoint_dispatches_pr_review <workflow_yaml>
# True when a workflow file can take the sweep's dispatch: workflow_dispatch declares
# a pr_url input, and the file calls the pr-review reusable. The standard
# pr-review.yml stub and the markets-style agent-ingress.yml both do. The reference
# agent-ingress.yml (docs/architecture/reference/) does not, and a dispatch to it
# would fail or run no review. Pure.
entrypoint_dispatches_pr_review() {
  local _y="${1:-}"
  entrypoint_dispatch_inputs "$_y" | grep -qx 'pr_url' \
    && grep -Eq '/\.github/workflows/pr-review(-reusable)?\.yml@' <<< "$_y"
}

# resolve_dispatch_target <pr_url> [force]
# Set DISPATCH_REPO / DISPATCH_WORKFLOW for a PR (#2530). The repo's own entrypoint
# is an active .github/workflows/pr-review.yml, else an active agent-ingress.yml
# (ADR-0007), that passes entrypoint_dispatches_pr_review. AGENT_REPO's own PRs, an
# unparseable URL, ROUTE_TO_REPO_ENTRYPOINT=false, and a repo with no such file (or
# whose workflows cannot be read) all use TRIGGER_WORKFLOW in AGENT_REPO.
# The lookup is cached per repo for the run. Sets globals rather than echoing, so
# the cache survives (a command substitution would run in a subshell).
resolve_dispatch_target() {
  local _url="$1" _force="${2:-}" _repo="" _state="" _file="" _yaml=""
  DISPATCH_REPO="$AGENT_REPO"
  DISPATCH_WORKFLOW="$TRIGGER_WORKFLOW"
  [[ "$ROUTE_TO_REPO_ENTRYPOINT" = "true" ]] || return 0
  if [[ "$_url" =~ ^https?://[^/]+/([^/]+/[^/]+)/pull/[0-9]+ ]]; then
    _repo="${BASH_REMATCH[1]}"
  fi
  [[ -n "$_repo" ]] && [[ "$_repo" != "$AGENT_REPO" ]] || return 0
  if [[ -z "${ENTRYPOINT_BY_REPO[$_repo]+set}" ]]; then
    ENTRYPOINT_BY_REPO[$_repo]=""
    # Ask for each file by name, in preference order: the workflow list is paged, so
    # an entrypoint on a later page would be missed. A missing file is a 404.
    for _file in pr-review.yml agent-ingress.yml; do
      _state=$(gh api "repos/$_repo/actions/workflows/$_file" --jq '.state // ""' 2>/dev/null) || _state=""
      [[ "$_state" == "active" ]] || continue
      _yaml=$(gh api "repos/$_repo/contents/.github/workflows/$_file" \
                -H "Accept: application/vnd.github.raw" 2>/dev/null) || _yaml=""
      if entrypoint_dispatches_pr_review "$_yaml"; then
        ENTRYPOINT_BY_REPO[$_repo]="$_file"
        # The rescue needs force_review declared as an input AND forwarded by the job
        # that calls the pr-review reusable; a stub that declares it but drops it (or
        # forwards it only in another job) would run an unforced review.
        if entrypoint_dispatch_inputs "$_yaml" | grep -qx 'force_review' \
           && pr_review_job_block "$_yaml" \
                | grep -Eq '^[[:space:]]*force_review:[[:space:]]*\$\{\{[^}]*inputs\.force_review'; then
          ENTRYPOINT_FORCE_BY_REPO[$_repo]=true
        else
          ENTRYPOINT_FORCE_BY_REPO[$_repo]=false
        fi
        break
      fi
      echo "    note: $_repo $_file does not take a pr_url dispatch for pr-review; not routing to it"
    done
  fi
  [[ -n "${ENTRYPOINT_BY_REPO[$_repo]}" ]] || return 0
  # The orphan rescue needs force_review. An entrypoint without that input would
  # reject the dispatch (HTTP 422), and one that does not forward it to the reusable
  # would ignore it, so either way the rescue keeps the agent-repo trigger.
  if [[ "$_force" == "force" && "${ENTRYPOINT_FORCE_BY_REPO[$_repo]:-false}" != "true" ]]; then
    echo "    note: $_repo ${ENTRYPOINT_BY_REPO[$_repo]} does not take and forward force_review; the rescue uses $TRIGGER_WORKFLOW"
    return 0
  fi
  DISPATCH_REPO="$_repo"
  DISPATCH_WORKFLOW="${ENTRYPOINT_BY_REPO[$_repo]}"
}

# held_at_comment_gate <pr_url> <snapshot>
# True when the maintainer-comment gate would withhold approval (rc 1): the check
# review-one-pr.sh runs before it reviews (#1813), with the same edit-time and
# author-type merge (#2008). Dispatching such a PR only buys a skip with no verdict
# (#2530). Any other outcome — clear, undeterminable (rc 2), or a failed author-type
# lookup — is false, so the review itself still decides. Run in a subshell so the gate's helpers stay out of
# this shell. SKIP_GATE_HELD=false turns the check off.
held_at_comment_gate() {
  local _url="$1" _snap="$2" _rc=0
  [[ "$SKIP_GATE_HELD" = "true" ]] || return 1
  (
    # shellcheck source=lib/maintainer-comment-gate.sh
    source "$SCRIPT_DIR/lib/maintainer-comment-gate.sh"
    _merged=$(maintainer_gate_merge_edit_times "$_url" "$_snap")
    # The merge returns the snapshot unchanged when its lookup fails, and the gate
    # then cannot clear a registered bot's status comment. A comment still missing
    # its author type means the lookup failed: undeterminable, so let the review run.
    jq -e '[(.comments // [])[] | select((.author.__typename // null) == null)] | length == 0' \
      <<< "$_merged" >/dev/null 2>&1 || exit 2
    check_maintainer_comments "$_merged" "${BOT_USER:-donpetry-bot}"
  ) >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 1 ]]
}

# dispatch_review <pr_url> <snapshot> <label> [force]
# Re-dispatch a review, unless the comment gate would hold it. AGENT_REPO's PRs go
# through TRIGGER_WORKFLOW; another repo's go to its own entrypoint
# (resolve_dispatch_target). Honours DRY_RUN and updates the counters. A 4th arg of
# "force" appends `-f force_review=true`, used ONLY for the orphaned-marker rescue
# (#1548): an unforced re-dispatch would hit review-one-pr.sh's idempotency no-op
# on the orphan marker. The force_review input is the NARROW idempotency bypass
# (FORCE_RE_REVIEW in pr-review.yml, #1590), so the CI/advisory/maintainer gates
# stay armed for the rescue too — force here defeats only the same-SHA no-op,
# never a quality gate.
dispatch_review() {
  local _url="$1" _snap="$2" _label="$3" _force="${4:-}"
  if held_at_comment_gate "$_url" "$_snap"; then
    held=$((held + 1))
    echo "  skip $_url — held at the maintainer-comment gate (undispositioned PR comment); not dispatching a review that would skip (#2530)"
    return 0
  fi
  stuck=$((stuck + 1))
  echo "  $_label: $_url — needs re-review"
  resolve_dispatch_target "$_url" "$_force"
  if [ "$DRY_RUN_BOOL" = "true" ]; then
    echo "    dry-run: would dispatch $DISPATCH_WORKFLOW @ $DISPATCH_REPO for $_url"
    return 0
  fi
  local force_flags=() ref_flags=()
  if [ "$_force" = "force" ]; then
    force_flags=(-f force_review=true)
  fi
  # A feature-branch ref exists only in AGENT_REPO; another repo runs its default branch.
  if [[ "$DISPATCH_REPO" = "$AGENT_REPO" ]]; then
    ref_flags=("${REF_FLAGS[@]}")
  fi
  if gh workflow run "$DISPATCH_WORKFLOW" --repo "$DISPATCH_REPO" "${ref_flags[@]}" \
       -f pr_url="$_url" "${force_flags[@]}"; then
    dispatched=$((dispatched + 1))
    DISPATCHED_BY_REPO[$DISPATCH_REPO]=$(( ${DISPATCHED_BY_REPO[$DISPATCH_REPO]:-0} + 1 ))
    echo "    dispatched review for $_url ($DISPATCH_WORKFLOW @ $DISPATCH_REPO)"
  else
    echo "::warning::sweep: failed to dispatch review for $_url ($DISPATCH_WORKFLOW @ $DISPATCH_REPO)"
  fi
}

# arm_delayed_retry <pr_url> <head_sha> <not_before_iso> <deadline_epoch> <now_epoch> [snapshot] [wait] [current_head]
# Deterministic deadline retry (#1994, #2533). Called from a DEFER branch: the
# rate-limit branch (wait=rate-limit, deadline = the marker's reset) and the
# advisory-wait branch (wait=advisory-bots, deadline = head commit time +
# ADVISORY_HEAD_AGE_TIMEOUT_SEC). Dispatches pr-review-delayed-retry.yml, which
# sleeps until <not_before>, re-checks that the wait still applies at the same head,
# then re-dispatches the review through THIS sweep (scoped to the one PR), so the
# PR goes to its own repo's entrypoint. This bounds the retry to minutes after the
# deadline without depending on the best-effort cron.
#
# Whether to arm is delayed_retry_arm_decision (lib/delayed-retry-arming.sh): only
# for a near, un-elapsed deadline, at an unchanged head (<current_head>, default
# <head_sha>), for a pr-review consumer, with no retry already in flight for the
# same pr_url + head_sha. Deadlines beyond DELAYED_RETRY_HORIZON_SEC are left to the
# cron backstop. Honours DRY_RUN and shares the single MAX_DISPATCH budget with
# normal dispatches (dispatched + armed), so one sweep never issues more than
# MAX_DISPATCH requests total. No-op when ARM_DELAYED_RETRY=false — the mode the
# retry uses when it delegates back here, so it can never re-arm itself.
arm_delayed_retry() {
  local _url="$1" _sha="$2" _reset="$3" _reset_epoch="$4" _now_epoch="$5" _snap="${6:-}"
  local _wait="${7:-rate-limit}" _current="${8:-$2}" _repo="" _consumer=false _decision
  [ "$ARM_DELAYED_RETRY" = "true" ] || return 0
  if [[ "$_url" =~ ^https?://[^/]+/([^/]+/[^/]+)/pull/[0-9]+ ]]; then
    _repo="${BASH_REMATCH[1]}"
  fi
  if pr_review_consumer_repo "$_repo" "$AGENT_REPO" "$CONSUMER_MANIFEST"; then
    _consumer=true
  fi
  # Decide on everything but the in-flight check first: it is pure, and a far or
  # elapsed deadline must cost no gate lookup and no run-list query.
  if ! _decision=$(delayed_retry_arm_decision "$_wait" "$_reset_epoch" "$_now_epoch" \
                     "$DELAYED_RETRY_HORIZON_SEC" "$_sha" "$_current" false "$_consumer"); then
    case "$_decision" in
      skip:head-moved)
        echo "    arm skipped $_url — head moved ${_sha:0:8} -> ${_current:0:8} since the snapshot; the newer push drives its own review" ;;
      skip:not-consumer)
        echo "    arm skipped $_url — ${_repo:-<unknown repo>} is not a pr-review consumer ($CONSUMER_MANIFEST); left to the cron sweep" ;;
    esac
    return 0
  fi
  # A retry armed for a PR the comment gate holds would only re-enter this sweep and
  # be skipped there, so it is not armed and spends no MAX_DISPATCH (#2530). Checked
  # only once arming is otherwise due, so a far reset costs no gate lookup.
  if [[ -n "$_snap" ]] && held_at_comment_gate "$_url" "$_snap"; then
    held=$((held + 1))
    echo "    arm skipped $_url — held at the maintainer-comment gate (undispositioned PR comment) (#2530)"
    return 0
  fi
  if [ "$(( dispatched + armed ))" -ge "$MAX_DISPATCH" ]; then
    echo "    arm skipped $_url — reached MAX_DISPATCH=$MAX_DISPATCH (dispatches + armed retries) this sweep"
    return 0
  fi
  if [ "$DRY_RUN_BOOL" = "true" ]; then
    echo "    dry-run: would arm delayed retry for $_url (wait=$_wait, not_before=$_reset, head ${_sha:0:8})"
    armed=$((armed + 1))
    return 0
  fi
  # Dedup across sweep invocations (#1994). The retry workflow's per-(PR, head)
  # concurrency group only COLLAPSES concurrent runs — it does not stop this
  # sweep from re-dispatching on every defer tick (the 15-min cron, and the
  # workflow_run fast path that fires on each CI completion org-wide), and each
  # re-dispatch's cancel-in-progress would kill and restart the already-sleeping
  # runner. So skip arming when a queued/in-progress retry already exists for
  # this exact (PR, head): the run-name carries "<pr_url> @ <head_sha>", which
  # gh exposes as displayTitle. Fail OPEN — a query error falls through to arm so
  # a transient gh failure can never strand the retry.
  local _in_flight=false
  if delayed_retry_in_flight "$_url" "$_sha" "$_wait"; then
    _in_flight=true
  fi
  if ! delayed_retry_arm_decision "$_wait" "$_reset_epoch" "$_now_epoch" \
         "$DELAYED_RETRY_HORIZON_SEC" "$_sha" "$_current" "$_in_flight" "$_consumer" >/dev/null; then
    echo "    arm skipped $_url — a delayed retry is already in flight for head ${_sha:0:8}"
    return 0
  fi
  if gh workflow run "$DELAYED_RETRY_WORKFLOW" --repo "$AGENT_REPO" "${REF_FLAGS[@]}" \
       -f pr_url="$_url" -f head_sha="$_sha" -f not_before="$_reset" -f wait="$_wait"; then
    armed=$((armed + 1))
    echo "    armed delayed retry for $_url (wait=$_wait, not_before=$_reset, head ${_sha:0:8})"
  else
    # A failed attempt still spends a MAX_DISPATCH slot, so a transient dispatch
    # error cannot turn one sweep into a retry storm across every candidate.
    armed=$((armed + 1))
    echo "::warning::sweep: failed to arm delayed retry for $_url (attempt counted against MAX_DISPATCH)"
  fi
}

# delayed_retry_in_flight <pr_url> <head_sha> [wait]
# True when a queued or in-progress pr-review-delayed-retry run already exists for
# this exact (PR, head, wait). Matches on the run-name the retry workflow sets
# ("pr-review-delayed-retry <pr_url> @ <head_sha>", plus " (advisory-bots)" for that
# wait), surfaced by gh as displayTitle. The wait is part of the key so an earlier
# advisory-bots retry never hides a later rate-limit deadline at the same head. Fails OPEN (returns false) on any query error so a transient gh
# failure never suppresses a needed arm.
delayed_retry_in_flight() {
  local _url="$1" _sha="$2" _w="${3:-rate-limit}" _runs _title
  _title="$_url @ $_sha"
  [[ "$_w" != "advisory-bots" ]] || _title+=" (advisory-bots)"
  _runs=$(gh run list --repo "$AGENT_REPO" --workflow "$DELAYED_RETRY_WORKFLOW" \
            --event workflow_dispatch --limit 50 \
            --json status,displayTitle 2>/dev/null) || return 1
  [ -n "$_runs" ] || return 1
  jq -e --arg title "$_title" '
    any(.[]?; (.status == "queued" or .status == "in_progress")
             and ((.displayTitle // "") | endswith($title)))' \
    <<< "$_runs" >/dev/null 2>&1
}

# advisory_head_age_timeout — ADVISORY_HEAD_AGE_TIMEOUT_SEC as the advisory gate
# defines it, read once per run in a subshell so the gate's helpers stay out of this
# shell. Falls back to 1200 (the gate's value) when it cannot be read.
ADVISORY_TIMEOUT_CACHE=""
advisory_head_age_timeout() {
  if [[ -z "$ADVISORY_TIMEOUT_CACHE" ]]; then
    ADVISORY_TIMEOUT_CACHE=$(
      # shellcheck source=lib/advisory-review-gate.sh
      source "$SCRIPT_DIR/lib/advisory-review-gate.sh" >/dev/null 2>&1
      printf '%s' "${ADVISORY_HEAD_AGE_TIMEOUT_SEC:-}"
    ) || ADVISORY_TIMEOUT_CACHE=""
    [[ "$ADVISORY_TIMEOUT_CACHE" =~ ^[0-9]+$ ]] || ADVISORY_TIMEOUT_CACHE=1200
  fi
  printf '%s' "$ADVISORY_TIMEOUT_CACHE"
}

# advisory_wait_deadline <pr_url> <now_epoch>
# True when review-one-pr.sh would skip this PR as waiting-for-advisory-bots (#2533):
# the head commit is younger than ADVISORY_HEAD_AGE_TIMEOUT_SEC and the advisory
# gate (check_advisory_reviews, run in a subshell exactly as review-one-pr.sh runs
# it) says it is still waiting. Sets ADVISORY_DEADLINE_EPOCH / ADVISORY_DEADLINE_ISO
# (head commit time + timeout) and ADVISORY_CURRENT_HEAD (the latest commit's oid at
# lookup time). Anything undeterminable — an unreadable head commit, a gate that
# clears or errors — is false, so the PR is dispatched as before and the review
# itself decides. DEFER_ADVISORY_WAIT=false turns the check off.
advisory_wait_deadline() {
  local _url="$1" _now="$2" _gql _raw _oid _date _timeout _deadline _rc=0
  ADVISORY_DEADLINE_EPOCH=""; ADVISORY_DEADLINE_ISO=""; ADVISORY_CURRENT_HEAD=""
  [[ "$DEFER_ADVISORY_WAIT" = "true" ]] || return 1
  # shellcheck disable=SC2016  # $url is a GraphQL variable, not a shell variable
  _gql='query($url:URI!){resource(url:$url){...on PullRequest{commits(last:1){nodes{commit{oid committer{date}}}}}}}'
  _raw=$(gh api graphql -f query="$_gql" -f url="$_url" 2>/dev/null) || return 1
  _oid=$(jq -r '.data.resource.commits.nodes[0].commit.oid // ""' <<< "$_raw" 2>/dev/null) || _oid=""
  _date=$(jq -r '.data.resource.commits.nodes[0].commit.committer.date // ""' <<< "$_raw" 2>/dev/null) || _date=""
  [[ -n "$_oid" && -n "$_date" ]] || return 1
  advisory_head_age_timeout >/dev/null  # direct call: a $(...) would drop the cache assignment
  _timeout="$ADVISORY_TIMEOUT_CACHE"
  _deadline=$(advisory_head_age_deadline "$_date" "$_timeout") || return 1
  # Past the deadline the gate proceeds on head age, so the review is due now.
  [[ "$_now" -lt "$_deadline" ]] || return 1
  (
    # shellcheck source=lib/advisory-review-gate.sh
    source "$SCRIPT_DIR/lib/advisory-review-gate.sh"
    check_advisory_reviews "$_url"
  ) >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 1 ]] || return 1
  ADVISORY_DEADLINE_EPOCH="$_deadline"
  ADVISORY_DEADLINE_ISO=$(date -u -d "@$_deadline" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$_deadline" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ADVISORY_DEADLINE_ISO=""
  [[ -n "$ADVISORY_DEADLINE_ISO" ]] || return 1
  ADVISORY_CURRENT_HEAD="$_oid"
}

while IFS= read -r pr_url; do
  [ -z "$pr_url" ] && continue
  if [ "$(( dispatched + armed ))" -ge "$MAX_DISPATCH" ]; then
    echo "::notice::sweep: reached MAX_DISPATCH=$MAX_DISPATCH (dispatches + armed retries) — deferring remaining PRs to the next sweep"
    break
  fi
  inspected=$((inspected + 1))

  if ! snapshot=$(gh pr view "$pr_url" \
        --json headRefOid,baseRefName,statusCheckRollup,reviewDecision,reviews,comments,labels 2>/dev/null); then
    echo "  skip $pr_url — could not fetch PR (deleted, no access, or rate-limited)"
    continue
  fi

  head_sha=$(jq -r '.headRefOid // ""' <<< "$snapshot")
  if [ -z "$head_sha" ]; then
    echo "  skip $pr_url — head SHA is empty"
    continue
  fi

  # Skip PRs held for a human (#946). When the per-PR automation budget (#928) or
  # the cycle cap escalates a PR, it adds needs-human-review and the cascade
  # pauses; re-reviewing it here would re-ignite the runaway the breaker stops
  # (the #860 "amplifier" failure mode). Gate on the label — the human-controlled
  # resume signal — so removing it re-enables the sweep.
  #
  # EXCEPTION — a rate-limit-ONLY hold (#1550). The rate-limited withhold marker
  # PROMISES "pr-review-sweep will re-review this PR after <reset>", but a
  # concurrent hold label (from a budget/cycle-cap escalation OR a manual
  # escalation) would pause the very sweep that makes the promise good, stranding
  # the PR until a human removes the label. So when the ONLY hold is the
  # rate-limit marker at the current head (no genuine-escalation marker present),
  # exempt it from the pause and fall through to the rate-limit retry below — the
  # reset gate there still governs WHEN it re-dispatches. A GENUINE escalation
  # (budget exhaustion / churn-breaker cap) keeps pausing everything, even with a
  # co-present rate-limit marker (#1550 AC#3): the exemption keys on the marker
  # set, it does not weaken the hold semantics. For EVERY held PR skipped, log
  # WHICH hold was honored so a stranded PR is diagnosable from one run (#1550 AC#5).
  labels_json=$(jq -c '[.labels[]?.name]' <<< "$snapshot" 2>/dev/null || echo '[]')
  if pr_has_escalation_label "$labels_json"; then
    hold_items=$(jq -c '((.reviews? // []) + (.comments? // [])) | map({body: (.body? // "" | tostring)})' \
      <<< "$snapshot" 2>/dev/null || echo '[]')
    hold_kind=$(pr_hold_kind "$hold_items" "$head_sha")
    if [ "$hold_kind" = "rate-limit-only" ]; then
      echo "  exempt $pr_url — held by $NEEDS_HUMAN_REVIEW_LABEL but hold is rate-limit-only (no escalation marker) — recovery not disabled, continuing to rate-limit retry (#1550)"
    else
      echo "  skip $pr_url — held ($hold_kind; $NEEDS_HUMAN_REVIEW_LABEL present); not re-reviewing (#946/#1550)"
      continue
    fi
  fi

  review_decision=$(jq -r '.reviewDecision // ""' <<< "$snapshot")
  if [ "$review_decision" != "REVIEW_REQUIRED" ]; then
    echo "  skip $pr_url — reviewDecision='$review_decision' (not REVIEW_REQUIRED)"
    continue
  fi
  # Marker vs. STANDING verdict at this exact head (#1548, #1665). The cascade
  # stamps each review with `<!-- pr-review-agent v1 sha=<HEAD> -->`, but a review
  # can CRASH (Claude 429 usage-limit, or a 429 between the escalation review and
  # its follow-through) after stamping that marker and before posting any VERDICT.
  # A genuine verdict additionally carries a `decision=` token in the same body
  # (see scripts/lib/review-cycle.sh):
  #   approval:    <!-- pr-review-agent v1 sha=<SHA> decision=approved  risk=... -->
  #   escalated:   <!-- pr-review-agent v1 sha=<SHA> decision=escalated risk=... -->
  #   fix-request: <!-- pr-review-agent v1 sha=<SHA> --> <!-- decision=fix-requested risk=... -->
  # Match the sha followed by a space so one sha is never a prefix of another.
  # marker_at_head           — any v1 marker at head (crashed or complete).
  # standing_verdict_at_head — a verdict that ACTUALLY STANDS at head, i.e. one of:
  #   • a STANDING APPROVAL — a non-dismissed state==APPROVED REVIEW carrying the
  #     approval marker (pr_standing_approval_count, #1665). A `decision=approved`
  #     MARKER in a DISMISSED review or an issue COMMENT is NOT a standing approval
  #     — GitHub still wants a review — so it must never satisfy the stop
  #     condition. This is the #1665 fix: the old code counted the marker string,
  #     stranding a green auto-merge-armed PR when its approval was dismissed or
  #     the marker was posted as a comment.
  #   • a terminal escalated / fix-requested verdict — a genuine dead-end that
  #     legitimately suppresses re-review (the PR needs a human / fixes, not a
  #     re-run). These stay MARKER-based: they are not "approvals" and the marker
  #     is their canonical record. Bound to the CANONICAL marker relationship the
  #     writers emit (not a `decision=…` string anywhere in the body) so quoted/
  #     unrelated prose can't masquerade as a verdict and suppress an orphan's
  #     rescue. Two canonical shapes:
  #       escalated     — the token sits INSIDE the head marker: `sha=<SHA> decision=escalated`
  #       fix-requested — the bare head marker plus its companion `<!-- decision=fix-requested … -->`
  # An orphan (marker present, no STANDING verdict) is the silent strand this fixes.
  marker_at_head=$(jq -r --arg sha "$head_sha" '
    [ ((.reviews // []) + (.comments // []))[]
      | (.body // "")
      | select(test("<!-- pr-review-agent v1 sha=" + $sha + " ")) ]
    | length' <<< "$snapshot" 2>/dev/null || echo 0)
  standing_approval_at_head=$(pr_standing_approval_count "$snapshot" "$head_sha")
  other_verdict_at_head=$(jq -r --arg sha "$head_sha" '
    def is_terminal_verdict($sha):
      (.body // "") as $b
      | ($b | test("<!-- pr-review-agent v1 sha=" + $sha + "\\s+decision=escalated\\b"))
        or (($b | test("<!-- pr-review-agent v1 sha=" + $sha + " -->"))
            and ($b | test("<!-- decision=fix-requested\\b")));
    [ ((.reviews // []) + (.comments // []))[] | select(is_terminal_verdict($sha)) ]
    | length' <<< "$snapshot" 2>/dev/null || echo 0)
  standing_verdict_at_head=$(( ${standing_approval_at_head:-0} + ${other_verdict_at_head:-0} ))

  # Rate-limited withhold retry (issue #711). A pr-review run that withheld
  # approval because advisory bots were rate-limited stamps a distinct marker:
  #   <!-- pr-review-agent rate-limited v1 sha=<HEAD> status=rate-limited reset=<ISO> -->
  # Handle it BEFORE the CI gate so unrelated cancelled/failed sibling checks
  # cannot suppress the retry (AC3). Extract the reset for a marker at the
  # current head (sha followed by a space, never a prefix match).
  rl_reset=$(jq -r --arg sha "$head_sha" '
    [ ((.reviews // []) + (.comments // []))[]
      | (.body // "")
      | select(test("<!-- pr-review-agent rate-limited v1 sha=" + $sha + " ") and test("reset=[^ ]+"))
      | capture("reset=(?<r>[^ ]+)") | .r ]
    | last // ""' <<< "$snapshot" 2>/dev/null || echo "")
  if [ -n "$rl_reset" ]; then
    if [ "${standing_verdict_at_head:-0}" -gt 0 ]; then
      # A verdict that STANDS at head resolves the rate-limit state — a standing
      # approval (non-dismissed APPROVED review) or a terminal escalated/fix-
      # requested verdict. A bare orphan marker, a DISMISSED approval, or an
      # approval marker posted as a comment (#1665) do NOT resolve it: the retry
      # still needs to fire.
      echo "  skip $pr_url — rate-limited marker present but standing verdict at head ${head_sha:0:8}"
      continue
    fi
    reset_epoch=$(date -u -d "$rl_reset" +%s 2>/dev/null \
      || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$rl_reset" +%s 2>/dev/null \
      || echo "")
    now_epoch=$(date -u +%s)
    # Dispatch once the reset has elapsed; an unparseable reset fails open to a
    # retry so a malformed marker can never strand the PR indefinitely.
    if [ -z "$reset_epoch" ] || [ "$now_epoch" -ge "$reset_epoch" ]; then
      if [ "$SCHEDULED_SWEEP" = "true" ]; then
        eventability=$(classify_rollup_eventability "$(jq '.statusCheckRollup' <<< "$snapshot")")
        if [ "$eventability" = "eventable-only" ]; then
          echo "  skip $pr_url — rate-limited marker elapsed but all checks eventable; scheduled sweep is un-eventable-only (#1408)"
          continue
        fi
      fi
      dispatch_review "$pr_url" "$snapshot" "rate-limited (reset $rl_reset elapsed, head ${head_sha:0:8})"
    else
      echo "  defer $pr_url — rate-limited until $rl_reset (head ${head_sha:0:8})"
      arm_delayed_retry "$pr_url" "$head_sha" "$rl_reset" "$reset_epoch" "$now_epoch" "$snapshot" rate-limit
    fi
    continue
  fi

  # Gate on the branch ruleset's REQUIRED checks (#1795) — same authoritative set
  # review-one-pr.sh uses. Without it this sweep reverts to blocking on every red
  # external check, so a non-required `template-drift` failure would keep a green PR
  # stuck and never re-dispatched (the deadlock #1795 fixes, on the sweep path too).
  # Fail closed: an unreadable set leaves it empty and compute_ci_status gates on all
  # failing checks.
  base_ref=$(jq -r '.baseRefName // ""' <<< "$snapshot")
  owner_repo=""
  if [[ "$pr_url" =~ ^https?://[^/]+/([^/]+/[^/]+)/pull/[0-9]+ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
  fi
  required_checks=$(ruleset_required_checks "$owner_repo" "$base_ref" || true)
  ci_status=$(compute_ci_status "$(jq '.statusCheckRollup' <<< "$snapshot")" "$required_checks")
  if [ "$ci_status" != "passing" ]; then
    echo "  skip $pr_url — CI '$ci_status' (not green yet)"
    continue
  fi

  if [ "${standing_verdict_at_head:-0}" -gt 0 ]; then
    echo "  skip $pr_url — already reviewed at head ${head_sha:0:8} (standing approval or terminal verdict)"
    continue
  fi

  # Orphaned marker (#1548): the head was stamped but the review crashed before
  # posting a verdict. Re-dispatch WITH force_review — an unforced re-dispatch
  # would hit review-one-pr.sh's idempotency no-op on this very marker. This runs
  # BEFORE the scheduled-narrowing gate below so a genuine strand is rescued even
  # in the cron's un-eventable-only mode; the strand is not the redundant re-review
  # the narrowing removes. force_review here is the NARROW idempotency bypass
  # (FORCE_RE_REVIEW, #1590): it clears ONLY the same-SHA marker no-op. The CI,
  # advisory, and maintainer gates stay armed (so a CI status that went red since
  # this sweep's snapshot re-blocks at execution time), as do the per-PR automation
  # budget (#926) and the needs-human-review escalation gate (handled above) — so
  # the rescue can neither bypass a quality gate nor re-ignite a runaway.
  if [ "${marker_at_head:-0}" -gt 0 ]; then
    dispatch_review "$pr_url" "$snapshot" "orphaned-marker (head ${head_sha:0:8}, no verdict)" force
    continue
  fi

  # Advisory-bot wait (#2533). A review dispatched now would only skip as
  # waiting-for-advisory-bots, and no event re-fires if the bots never report. Defer
  # it instead, and arm a retry for the gate's head-age deadline; past that deadline
  # the gate proceeds, so the retry's review runs. When no retry is armed (far
  # deadline, not a consumer, budget spent), a bot's review event or the cron still
  # re-enters the PR.
  # Evaluate this before the scheduled narrowing so advisory-held PRs are not
  # skipped as eventable-only (#2533 issue).
  now_epoch=$(date -u +%s)
  advisory_held_deadline_epoch=""
  advisory_held_deadline_iso=""
  advisory_held_current_head=""
  if advisory_wait_deadline "$pr_url" "$now_epoch"; then
    advisory_held_deadline_epoch="$ADVISORY_DEADLINE_EPOCH"
    advisory_held_deadline_iso="$ADVISORY_DEADLINE_ISO"
    advisory_held_current_head="$ADVISORY_CURRENT_HEAD"
  fi

  # Scheduled-backstop narrowing (#1408): on the cron event, only re-review the
  # un-eventable residue. A PR whose external checks are all eventable GitHub
  # Actions runs is owned by the workflow_run fast path, so re-dispatching it here
  # would be the redundant re-review this story removes. However, exclude PRs that
  # are waiting for advisory bots, since advisory checks are non-eventable and are
  # not covered by the workflow_run fast path.
  if [ "$SCHEDULED_SWEEP" = "true" ]; then
    eventability=$(classify_rollup_eventability "$(jq '.statusCheckRollup? // []' <<< "$snapshot" 2>/dev/null || echo '[]')")
    if [[ "$eventability" = "eventable-only" && -z "$advisory_held_deadline_iso" ]]; then
      echo "  skip $pr_url — all checks eventable (workflow_run fast path owns it); scheduled sweep is un-eventable-only (#1408)"
      continue
    fi
  fi

  # Handle the advisory-wait deferral if one was found
  if [[ -n "$advisory_held_deadline_iso" ]]; then
    echo "  defer $pr_url — waiting for advisory bots until $advisory_held_deadline_iso (head ${head_sha:0:8})"
    arm_delayed_retry "$pr_url" "$head_sha" "$advisory_held_deadline_iso" "$advisory_held_deadline_epoch" "$now_epoch" \
      "$snapshot" advisory-bots "$advisory_held_current_head"
    continue
  fi

  dispatch_review "$pr_url" "$snapshot" "stuck-green (head ${head_sha:0:8})"
done < "$candidates_file"

# sweep_cost_line <before> <after> — "GraphQL G, REST R" points spent, from two
# rate_limit_remaining readings; "unknown" when either is unreadable or the window
# reset during the run (a negative spend). Pure.
sweep_cost_line() {
  local _b="${1:-}" _a="${2:-}" _bg _bc _ag _ac
  read -r _bg _bc <<< "$_b"
  read -r _ag _ac <<< "$_a"
  if [[ "$_bg$_bc$_ag$_ac" =~ ^[0-9]+$ && -n "$_bg" && -n "$_bc" && -n "$_ag" && -n "$_ac" ]] \
     && [[ "$_bg" -ge "$_ag" ]] && [[ "$_bc" -ge "$_ac" ]]; then
    echo "GraphQL $(( _bg - _ag )), REST $(( _bc - _ac ))"
  else
    echo "unknown"
  fi
}

cost=$(sweep_cost_line "$rate_before" "$(rate_limit_remaining)")
by_repo=""
for _r in "${!DISPATCHED_BY_REPO[@]}"; do
  by_repo+="${by_repo:+, }$_r=${DISPATCHED_BY_REPO[$_r]}"
done

echo ""
echo "Sweep summary: inspected $inspected candidate(s), $stuck stuck-green, $dispatched review(s) dispatched, $armed delayed retr$([[ "$armed" -eq 1 ]] && echo y || echo ies) armed, $held held at the comment gate."
echo "  Dispatches by repo: ${by_repo:-none}"
echo "  API points spent (shared GH_TOKEN quota): $cost"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### PR review sweep"
    echo ""
    echo "| Inspected | Dispatched | Retries armed | Held at comment gate | API points spent |"
    echo "|---:|---:|---:|---:|---|"
    echo "| $inspected | $dispatched | $armed | $held | $cost |"
    echo ""
    echo "Dispatches by repo: ${by_repo:-none}"
  } >> "$GITHUB_STEP_SUMMARY" || true
fi
