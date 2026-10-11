#!/usr/bin/env bash
set -euo pipefail
# ci-failure-analyst-resolve.sh — payload resolution for the CI Failure Analyst
# reusable (.github/workflows/ci-failure-analyst-reusable.yml, #2235).
#
# The reusable is called from a stub that may fire on either event:
#   check_run    — a check created by another app (SonarCloud and the like).
#                  GitHub does not deliver check_run for checks created by
#                  GitHub Actions' own token, so this never sees Actions jobs.
#   workflow_run — a GitHub Actions run completed; this is how the analyst
#                  learns about failed Actions jobs.
# The event is detected from the payload itself ($GITHUB_EVENT_PATH; a reusable
# sees its caller's payload), so a payload that carries neither ends in the
# "skipping" notice with exit 0 instead of a jq iteration error.
#
# Subcommands (results go to $GITHUB_OUTPUT):
#   resolve      skip=true|false, and when false: event, pr_number, head_sha,
#                check_name, details_url, run_id, check_run_id, failed_jobs
#   idempotency  exists=true|false — whether PR_NUMBER already has a comment
#                starting with `<!-- ci-analyst sha=HEAD_SHA -->`. That marker
#                keeps it to one analysis per commit however many workflows fail.
#
# Env: REPO (owner/repo), GITHUB_EVENT_PATH, GITHUB_OUTPUT, GH_TOKEN for gh;
#      PR_NUMBER and HEAD_SHA for `idempotency`.

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
export REPO

emit() { printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr -d '\r\n')" >> "$GITHUB_OUTPUT"; }

# payload_field <jq-filter> — read one value from the event payload; empty on a
# missing, empty or non-JSON payload.
payload_field() {
  local event_path="${GITHUB_EVENT_PATH:-}"
  [ -n "$event_path" ] && [ -s "$event_path" ] || return 0
  jq -r "$1 // empty" "$event_path" 2>/dev/null || true
}

# failed_jobs <run_id> — "job / failing step; job; ..." for the run's failed jobs.
failed_jobs() {
  [ -n "$1" ] || return 0
  gh api "repos/$REPO/actions/runs/$1/jobs" --paginate \
    --jq '.jobs[]? | select(.conclusion == "failure")
          | .name + ([(.steps // [])[] | select(.conclusion == "failure") | " / " + .name][0] // "")' \
    2>/dev/null | paste -sd';' - | sed 's/;/; /g' || true
}

resolve() {
  local event key head_sha pr_number name details_url run_id="" check_run_id=""
  event="$(payload_field 'if (.check_run | type) == "object" then "check_run"
                          elif (.workflow_run | type) == "object" then "workflow_run"
                          else null end')"
  case "$event" in
    check_run)    key=check_run ;;
    workflow_run) key=workflow_run ;;
    *)
      echo "::notice::Event payload carries neither a check_run nor a workflow_run — skipping"
      emit skip true
      return 0
      ;;
  esac

  head_sha="$(payload_field ".$key.head_sha")"
  if [ -z "$head_sha" ]; then
    echo "::notice::No head SHA in the $event payload — skipping"
    emit skip true
    return 0
  fi

  # Prefer the pull_requests array embedded in the payload, filtered to
  # non-fork PRs (head repo must equal base repo).
  pr_number="$(payload_field "[(.$key.pull_requests // [])[]
                               | select(.head.repo.id == .base.repo.id) | .number][0]")"
  if [ -z "$pr_number" ]; then
    # Fallback: the commits-to-pulls API covers a second push that arrived
    # before this event, and a workflow_run whose payload omits the PR. Only
    # an open PR counts, so a failure on the default branch is not reported
    # on the PR that was already merged into it.
    # shellcheck disable=SC2016  # $ENV.REPO is jq built-in syntax, not a shell variable
    pr_number="$(gh api "repos/$REPO/commits/$head_sha/pulls" \
      --jq '.[] | select(.state == "open" and .head.repo.full_name == $ENV.REPO) | .number' \
      2>/dev/null | head -n 1 || true)"
  fi
  if [ -z "$pr_number" ]; then
    echo "::notice::No non-fork PR for SHA $head_sha — skipping"
    emit skip true
    return 0
  fi

  name="$(payload_field ".$key.name")"
  if [ "$event" = check_run ]; then
    details_url="$(payload_field ".check_run.details_url // .check_run.html_url")"
    check_run_id="$(payload_field ".check_run.id")"
    # An Actions-hosted check links to its run; a third-party check does not.
    run_id="$(printf '%s' "$details_url" | grep -oE '/actions/runs/[0-9]+' | grep -oE '[0-9]+$' || true)"
  else
    details_url="$(payload_field ".workflow_run.html_url")"
    run_id="$(payload_field ".workflow_run.id")"
  fi

  emit skip false
  emit event "$event"
  emit pr_number "$pr_number"
  emit head_sha "$head_sha"
  emit check_name "$name"
  emit details_url "$details_url"
  emit run_id "$run_id"
  emit check_run_id "$check_run_id"
  emit failed_jobs "$(failed_jobs "$run_id")"
}

idempotency() {
  local existing
  existing="$(gh api "repos/$REPO/issues/${PR_NUMBER:?PR_NUMBER is required}/comments" \
    --paginate \
    --jq ".[] | select(.body | startswith(\"<!-- ci-analyst sha=${HEAD_SHA:?HEAD_SHA is required} -->\")) | .id" \
    2>/dev/null | head -n 1 || true)"
  if [ -n "$existing" ]; then
    echo "::notice::Diagnostic comment already posted (id=$existing) — idempotency skip"
    emit exists true
  else
    emit exists false
  fi
}

case "${1:-}" in
  resolve)     resolve ;;
  idempotency) idempotency ;;
  *)
    echo "usage: $0 resolve|idempotency" >&2
    exit 2
    ;;
esac
