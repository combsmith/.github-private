#!/usr/bin/env bats
# Offline tests for the eval-health notifier (scripts/evals/notify-eval-health.sh).
#
# This is the visibility layer for the Skill Eval Report (issue #747): on a
# held-out regression OR a scorer hard-error it opens-or-updates a single,
# de-duplicated `eval-health` tracking issue; on recovery (pass with a prior
# open issue) it comments + closes that issue; a healthy run with no open issue
# makes ZERO noise.
#
# These tests drive the script against a STUB `gh` placed first on PATH, so the
# open/update/close + de-dupe branching is exercised with NO network — mirroring
# the stub-engine discipline of tests/test_skill_evals.bats.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  NOTIFY="$ROOT/scripts/evals/notify-eval-health.sh"
  TMP="$(mktemp -d)"
  GH_LOG="$TMP/gh.log"
  : >"$GH_LOG"

  # A regression report: one pass, one fail (escalate case mis-approved).
  REPORT="$TMP/eval-report.json"
  cat >"$REPORT" <<'JSON'
{
  "skill": "triage",
  "total": 2,
  "passed": 1,
  "failed": 1,
  "score": 0.5,
  "cases": [
    {"id": "case-approve",  "pass": true,  "expected": {"escalate": false, "risk": "LOW"},  "actual": {"escalate": false, "risk": "LOW"}},
    {"id": "case-escalate", "pass": false, "expected": {"escalate": true,  "risk": "HIGH"}, "actual": {"escalate": false, "risk": "LOW"}}
  ]
}
JSON

  # The script's de-dup looks up the single open tracking issue by stable title.
  # Keep this title in lock-step with notify-eval-health.sh (per-skill TITLE).
  TITLE='Skill eval health — `triage` (holdout)'
  # The infra-error tracker is a SEPARATE issue (distinct title + label) so a
  # throttle/outage (outcome=error, #920) never opens or updates the held-out
  # regression tracker above.
  TITLE_INFRA='Skill eval infra error — `triage` (holdout)'
  # JSON the stub returns for `issue list`: empty by default; tests opt into an
  # "existing open issue" by setting GH_LIST_JSON to a matching-title array.
  EXISTING_JSON="$(jq -nc --arg t "$TITLE" '[{"number":42,"title":$t}]')"

  # Stub gh: logs every invocation + any --body-file content to GH_LOG, returns
  # the candidate list JSON from $GH_LIST_JSON for `issue list` (default []), and
  # a fixed URL for `issue create`. No network.
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat >"$BIN/gh" <<'SH'
#!/usr/bin/env bash
echo "ARGS: $*" >>"$GH_LOG"
prev=""
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then
    { echo "BODY<<"; cat "$a"; echo ">>BODY"; } >>"$GH_LOG"
  fi
  prev="$a"
done
case "$1 $2" in
  "issue list")   printf '%s' "${GH_LIST_JSON:-[]}" ;;
  "issue create") echo "https://github.com/petry-projects/.github-private/issues/123" ;;
esac
exit 0
SH
  chmod +x "$BIN/gh"
  export GH_LOG
}

teardown() { rm -rf "$TMP"; }

# Extra VAR=value pairs (OUTCOME=..., GH_LIST_JSON=..., DRY_RUN=1) are passed
# through `env` so they take effect even though they are runtime-expanded args.
run_notify() {
  run env "PATH=$BIN:$PATH" "GH_LOG=$GH_LOG" \
    "REPO=petry-projects/.github-private" "SKILL=triage" \
    "REPORT_PATH=$REPORT" "RUN_URL=https://github.com/o/r/actions/runs/999" \
    "$@" bash "$NOTIFY"
}

# A `gh issue list` JSON payload with one matching-title open issue numbered $1.
mklist() { jq -nc --arg t "$TITLE" --argjson n "$1" '[{number:$n,title:$t}]'; }
# Same, but titled as the infra-error tracker (#920).
mklist_infra() { jq -nc --arg t "$TITLE_INFRA" --argjson n "$1" '[{number:$n,title:$t}]'; }

# --- regression: open / update / de-dupe ------------------------------------

@test "regression with no existing issue creates exactly one eval-health issue" {
  run_notify OUTCOME="regression"
  [ "$status" -eq 0 ]
  grep -q "ARGS: issue create" "$GH_LOG"
  grep -q -- "--label eval-health" "$GH_LOG"
  [ "$(grep -c 'ARGS: issue create' "$GH_LOG")" -eq 1 ]
}

@test "regression with an existing open issue updates in place (no new issue — de-dupe)" {
  run_notify OUTCOME="regression" "GH_LIST_JSON=$(mklist 42)"
  [ "$status" -eq 0 ]
  grep -q "ARGS: issue edit 42" "$GH_LOG"
  ! grep -q "ARGS: issue create" "$GH_LOG"
}

@test "the tracking issue is looked up de-duped by label and open state" {
  run_notify OUTCOME="regression"
  [ "$status" -eq 0 ]
  grep -q "ARGS: issue list" "$GH_LOG"
  grep -q -- "--label eval-health" "$GH_LOG"
  grep -q -- "--state open" "$GH_LOG"
}

@test "regression body carries the score table, regressed case detail and run link" {
  run_notify OUTCOME="regression"
  [ "$status" -eq 0 ]
  # score table figures
  grep -q "0.5" "$GH_LOG"
  # regressed case id and the actual-vs-expected detail
  grep -q "case-escalate" "$GH_LOG"
  # link back to the workflow run
  grep -q "actions/runs/999" "$GH_LOG"
}

# --- error: separate infra tracker, never the regression tracker (#920) ------

@test "error opens a SEPARATE infra tracker (eval-infra label), not the regression tracker (#920)" {
  echo 'not json' >"$REPORT"
  run_notify OUTCOME="error"
  [ "$status" -eq 0 ]
  grep -q "ARGS: issue create" "$GH_LOG"
  # Opened under the infra label; the regression label is never used on an error.
  grep -q -- "--label eval-infra" "$GH_LOG"
  ! grep -q -- "--label eval-health" "$GH_LOG"
}

@test "error with an existing infra issue updates it in place (de-dupe, not silent)" {
  echo 'not json' >"$REPORT"
  run_notify OUTCOME="error" "GH_LIST_JSON=$(mklist_infra 7)"
  [ "$status" -eq 0 ]
  grep -q "ARGS: issue edit 7" "$GH_LOG"
  ! grep -q "ARGS: issue create" "$GH_LOG"
}

@test "error never edits or closes an open held-out REGRESSION tracker (#920)" {
  echo 'not json' >"$REPORT"
  # A regression tracker (#99) is open; an infra error must leave it untouched
  # and instead open its own infra tracker.
  run_notify OUTCOME="error" "GH_LIST_JSON=$(mklist 99)"
  [ "$status" -eq 0 ]
  ! grep -q "ARGS: issue edit 99" "$GH_LOG"
  ! grep -q "ARGS: issue close 99" "$GH_LOG"
  grep -q "ARGS: issue create" "$GH_LOG"
}

@test "error body labels the outcome as infra, not a regression (#920)" {
  echo 'not json' >"$REPORT"
  run_notify OUTCOME="error"
  [ "$status" -eq 0 ]
  grep -qi "infra" "$GH_LOG"
}

# --- pass: recovery closes; healthy makes no noise --------------------------

@test "pass with a prior open issue comments and closes it (recovery)" {
  run_notify OUTCOME="pass" "GH_LIST_JSON=$(mklist 55)"
  [ "$status" -eq 0 ]
  grep -q "ARGS: issue comment 55" "$GH_LOG"
  grep -q "ARGS: issue close 55" "$GH_LOG"
}

@test "pass with no existing issue makes zero noise (no create/comment/close)" {
  run_notify OUTCOME="pass"
  [ "$status" -eq 0 ]
  ! grep -q "ARGS: issue create" "$GH_LOG"
  ! grep -q "ARGS: issue comment" "$GH_LOG"
  ! grep -q "ARGS: issue close" "$GH_LOG"
}

@test "pass closes an open infra tracker too (outage recovery, #920)" {
  run_notify OUTCOME="pass" "GH_LIST_JSON=$(mklist_infra 88)"
  [ "$status" -eq 0 ]
  grep -q "ARGS: issue comment 88" "$GH_LOG"
  grep -q "ARGS: issue close 88" "$GH_LOG"
}

# --- guards ------------------------------------------------------------------

@test "missing REPO is a hard error" {
  run env -u REPO "PATH=$BIN:$PATH" "GH_LOG=$GH_LOG" OUTCOME="regression" \
    SKILL="triage" "REPORT_PATH=$REPORT" bash "$NOTIFY"
  [ "$status" -ne 0 ]
}

@test "an unknown OUTCOME is a hard error" {
  run_notify OUTCOME="banana"
  [ "$status" -ne 0 ]
}

@test "DRY_RUN never invokes gh mutations" {
  run_notify OUTCOME="regression" DRY_RUN=1
  [ "$status" -eq 0 ]
  ! grep -q "ARGS: issue create" "$GH_LOG"
  ! grep -q "ARGS: issue edit" "$GH_LOG"
}
