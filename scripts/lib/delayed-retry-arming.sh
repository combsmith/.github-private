#!/usr/bin/env bash
# delayed-retry-arming.sh — pure helpers for arming pr-review-delayed-retry.yml
# (issue #2533, generalising #1994).
#
# Two waits on a pr-review have a deadline that is known when the sweep defers the
# PR:
#   rate-limit     an advisory bot is out of quota; the rate-limited marker carries
#                  reset=<ISO>.
#   advisory-bots  the advisory gate is waiting for bot reviews; it proceeds once the
#                  head commit is older than ADVISORY_HEAD_AGE_TIMEOUT_SEC
#                  (scripts/lib/advisory-review-gate.sh), so the deadline is the head
#                  commit time plus that timeout.
# The sweep arms a delayed retry for either when the deadline is near, in this
# repository and in every pr-review consumer repo. The scheduled sweep stays the
# backstop for anything not armed.
#
# Everything here is pure (no gh, no network) so the decision is unit-tested in
# tests/test_delayed_retry_arming.bats. The sweep supplies the facts.
set -euo pipefail

# delayed_retry_arm_decision <wait> <deadline_epoch> <now_epoch> <horizon_sec>
#                            <armed_head> <current_head> <in_flight> <consumer>
# Print "arm" and return 0 when a retry should be armed; otherwise print
# "skip:<reason>" and return 1. Reasons, checked in this order:
#   unknown-wait    <wait> is not rate-limit or advisory-bots
#   no-deadline     the deadline is empty or not a number
#   elapsed         the deadline has passed, so the review is due now, not later
#   beyond-horizon  the deadline is more than <horizon_sec> away (left to the cron)
#   head-moved      the head the wait was seen on is not the current head (or either
#                   is empty); the newer push's own events drive its review
#   not-consumer    the PR's repo is not a pr-review consumer
#   in-flight       a retry for the same pr_url + head_sha is already queued/running
# <in_flight> and <consumer> are "true"/"false".
delayed_retry_arm_decision() {
  local _wait="${1:-}" _deadline="${2:-}" _now="${3:-}" _horizon="${4:-}"
  local _armed="${5:-}" _current="${6:-}" _in_flight="${7:-false}" _consumer="${8:-false}"
  local _reason=""
  case "$_wait" in
    rate-limit|advisory-bots) ;;
    *) _reason="unknown-wait" ;;
  esac
  if [[ -z "$_reason" ]] && [[ ! "$_deadline" =~ ^[0-9]+$ || ! "$_now" =~ ^[0-9]+$ ]]; then
    _reason="no-deadline"
  fi
  [[ "$_horizon" =~ ^[0-9]+$ ]] || _horizon=0
  if [[ -z "$_reason" ]]; then
    local _delta=$(( 10#$_deadline - 10#$_now ))
    if [[ "$_delta" -le 0 ]]; then
      _reason="elapsed"
    elif [[ "$_delta" -gt $(( 10#$_horizon )) ]]; then
      _reason="beyond-horizon"
    fi
  fi
  if [[ -z "$_reason" ]] && [[ -z "$_armed" || "$_armed" != "$_current" ]]; then
    _reason="head-moved"
  fi
  if [[ -z "$_reason" && "$_consumer" != "true" ]]; then
    _reason="not-consumer"
  fi
  if [[ -z "$_reason" && "$_in_flight" == "true" ]]; then
    _reason="in-flight"
  fi
  if [[ -n "$_reason" ]]; then
    echo "skip:$_reason"
    return 1
  fi
  echo "arm"
}

# pr_review_consumer_repo <owner/repo> <agent_repo> [manifest]
# True when <owner/repo> is reviewed by pr-review: the agent repository itself, or a
# repo whose consumer-manifest.json entry references the pr-review reusable. Any
# other repo, an empty name, or an unreadable manifest is false.
pr_review_consumer_repo() {
  local _repo="${1:-}" _agent="${2:-}" _manifest="${3:-}"
  [[ -n "$_repo" ]] || return 1
  [[ "$_repo" == "$_agent" ]] && return 0
  [[ -n "$_manifest" && -r "$_manifest" ]] || return 1
  jq -e --arg r "$_repo" \
    'any(.consumers[]?; .repo == $r and any(.refs[]?; . == ".github-private/.github/workflows/pr-review.yml"))' \
    "$_manifest" >/dev/null 2>&1
}

# advisory_head_age_deadline <committer_iso> <timeout_sec>
# Print the epoch at which the advisory gate stops waiting on the head-age timeout:
# the head commit's committer time plus <timeout_sec>. Prints nothing and returns 1
# when either value is unusable.
advisory_head_age_deadline() {
  local _iso="${1:-}" _timeout="${2:-}" _epoch
  [[ -n "$_iso" && "$_timeout" =~ ^[0-9]+$ ]] || return 1
  _epoch=$(date -u -d "$_iso" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$_iso" +%s 2>/dev/null) || return 1
  [[ "$_epoch" =~ ^[0-9]+$ ]] || return 1
  echo $(( _epoch + 10#$_timeout ))
}
