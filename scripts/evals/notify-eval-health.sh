#!/usr/bin/env bash
set -euo pipefail
# notify-eval-health.sh — surface the daily Skill Eval outcome as a single,
# de-duplicated tracking issue (issue #747, epic #581).
#
# The Skill Eval Report (skill-eval-report.yml) runs the deterministic holdout
# scorer daily and is intentionally NON-BLOCKING: a regression or a scorer
# hard-error never fails the workflow. Before this script its only output was a
# step summary / artifact / annotation — effectively invisible. This notifier
# makes the outcome visible WITHOUT making it blocking:
#
#   outcome=regression -> open OR update the single `eval-health` REGRESSION
#                          tracker (idempotent: rewritten in place, never a new
#                          one per day).
#   outcome=error      -> open OR update a SEPARATE `eval-infra` INFRA-ERROR
#                          tracker. An infra error (e.g. every model throttled,
#                          #920, or bad usage / missing tooling) means the skill
#                          was never scored — it must NOT open or update the
#                          held-out regression tracker, or a transient outage
#                          reads as a skill regression. It stays visible via its
#                          own clearly-labeled issue.
#   outcome=pass       -> a green run clears either condition: comment + close
#                          whichever tracker(s) (regression and/or infra) are
#                          currently open. With none open, do NOTHING (a healthy
#                          run must create zero noise).
#
# De-dup key: the single open issue carrying the matching label whose title
# matches the stable per-skill title below. Stable title => one issue, rewritten.
#
# This script only adds visibility; it never changes the scorer's pass/fail
# decision or gates any merge.
#
# Env:
#   REPO               owner/repo (required)
#   OUTCOME            pass | regression | error (required)
#   SKILL              skill whose holdout was scored (default: triage)
#   REPORT_PATH        eval-report.json from the scorer (default: ./eval-report.json)
#   RUN_URL            link back to the workflow run (optional but recommended)
#   EVAL_HEALTH_LABEL  regression tracking-issue label (default: eval-health)
#   EVAL_INFRA_LABEL   infra-error tracking-issue label (default: eval-infra)
#   DRY_RUN            "1"/"true" => render + log intent, never mutate via gh
#
# Exit codes: 0 success (including the no-op healthy path); 1 bad usage / gh error.

REPO="${REPO:?REPO required}"
OUTCOME="${OUTCOME:?OUTCOME required (pass|regression|error)}"
SKILL="${SKILL:-triage}"
REPORT_PATH="${REPORT_PATH:-eval-report.json}"
RUN_URL="${RUN_URL:-}"
EVAL_HEALTH_LABEL="${EVAL_HEALTH_LABEL:-eval-health}"
EVAL_INFRA_LABEL="${EVAL_INFRA_LABEL:-eval-infra}"

command -v jq >/dev/null 2>&1 || { echo "::error::notify-eval-health: jq is required but not installed" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "::error::notify-eval-health: gh is required but not installed" >&2; exit 1; }

case "$OUTCOME" in
  pass|regression|error) ;;
  *) echo "::error::notify-eval-health: unknown OUTCOME '$OUTCOME' (expected pass|regression|error)" >&2; exit 1 ;;
esac

# Stable, per-skill titles so each lookup always lands on the same issue. The
# regression tracker and the infra-error tracker are SEPARATE issues with
# distinct labels (#920): a throttle/outage must not touch the regression
# tracker, so each is de-duped independently.
TITLE_REGRESSION="Skill eval health — \`${SKILL}\` (holdout)"
TITLE_INFRA="Skill eval infra error — \`${SKILL}\` (holdout)"

_is_dry_run() { [[ "${DRY_RUN:-0}" == "1" || "${DRY_RUN:-0}" == "true" ]]; }

# find_existing <title> <label> — locate the single open tracking issue (scoped
# by label) whose title matches. gh emits the candidate list as JSON; system jq
# does the title de-dup so the expression is unambiguous (no reliance on gh's
# embedded jq arg passing).
find_existing() {
  if [[ "$#" -lt 2 ]]; then
    echo "::error::find_existing requires title and label" >&2
    exit 1
  fi
  local title="$1" label="$2"
  if _is_dry_run; then
    printf '%s' "${DRY_RUN_EXISTING:-}"
    return 0
  fi
  gh issue list --repo "$REPO" --label "$label" --state open \
    --json number,title 2>/dev/null \
    | jq -r --arg t "$title" 'map(select(.title == $t)) | (.[0].number // "")' 2>/dev/null \
    || true
}

# Render the tracking-issue body for a regression/error outcome to stdout.
render_body() {
  if [[ "$OUTCOME" = "error" ]]; then
    echo "## ${TITLE_INFRA}"
    echo ""
    echo "**Outcome:** \`error\` — the eval could not score the skill (infrastructure failure: e.g. every model in the fallback chain throttled, or bad usage / missing tooling)."
    echo ""
    echo "_This is an **infra** signal, **not** a skill regression: the model never produced a scorable answer, so the held-out set is currently un-scored and needs a look. Report-only (Phase 1): it does not block any merge._"
  else
    echo "## ${TITLE_REGRESSION}"
    echo ""
    echo "**Outcome:** \`regression\` — at least one held-out case regressed."
    echo ""
    echo "_Report-only (Phase 1): a regression does not fail CI or block any merge._"
  fi
  echo ""

  if jq -e . "$REPORT_PATH" >/dev/null 2>&1; then
    local score passed total failed
    score=$(jq -r '.score // "N/A"' "$REPORT_PATH")
    passed=$(jq -r '.passed // "0"' "$REPORT_PATH")
    total=$(jq -r '.total // "0"' "$REPORT_PATH")
    failed=$(jq -r '.failed // "0"' "$REPORT_PATH")
    echo "| skill | score | passed | failed | total |"
    echo "|-------|-------|--------|--------|-------|"
    echo "| \`${SKILL}\` | ${score} | ${passed} | ${failed} | ${total} |"
    if [[ "${failed}" != "0" ]]; then
      echo ""
      echo "### Regressed cases"
      jq -r --arg def "unknown" '(.cases | select(type == "array") // []) | .[] | select(.pass | not) | "- `\(.id // $def)` — expected \(.expected|tojson), got \(.actual|tojson)"' "$REPORT_PATH"
    fi
  else
    echo "Scorer produced no parseable JSON report (outcome: \`${OUTCOME}\`)."
  fi

  echo ""
  if [[ -n "$RUN_URL" ]]; then
    echo "[View the workflow run](${RUN_URL})"
  fi
  echo ""
  echo "<sub>Auto-managed by \`notify-eval-health.sh\` — this issue is updated in place each run and closed automatically on recovery.</sub>"
}

# _recover <issue_number> — comment a recovery note on the issue and close it.
_recover() {
  if [[ "$#" -lt 1 ]]; then
    echo "::error::_recover requires an issue number" >&2
    exit 1
  fi
  local num="$1" comment
  comment="$(mktemp)" || { echo "::error::Failed to create temp file" >&2; exit 1; }
  {
    echo "✅ **Recovered** — the \`${SKILL}\` holdout eval passed; all held-out cases are green again."
    echo ""
    [[ -n "$RUN_URL" ]] && echo "[View the workflow run](${RUN_URL})"
  } >"$comment"
  if _is_dry_run; then
    echo "[dry-run] would comment on and close issue #${num}"
    rm -f "$comment"
    return 0
  fi
  gh issue comment "$num" --repo "$REPO" --body-file "$comment" >/dev/null
  gh issue close "$num" --repo "$REPO" >/dev/null
  rm -f "$comment"
  echo "closed tracking issue #${num} (recovered)"
}

# _open_or_update <title> <label> <label_description> <label_color> — open the
# tracker (de-duped by title+label) or rewrite it in place if already open.
_open_or_update() {
  if [[ "$#" -lt 4 ]]; then
    echo "::error::_open_or_update requires title, label, description, and color" >&2
    exit 1
  fi
  local title="$1" label="$2" desc="$3" color="$4" existing body url
  existing="$(find_existing "$title" "$label")"
  body="$(mktemp)" || { echo "::error::Failed to create temp file" >&2; exit 1; }
  render_body >"$body"
  if _is_dry_run; then
    echo "[dry-run] would $( [[ -n "$existing" ]] && echo "update #${existing}" || echo "create" ) issue '${title}' (${label})"
    rm -f "$body"
    return 0
  fi
  if [[ -n "$existing" ]]; then
    gh issue edit "$existing" --repo "$REPO" --body-file "$body" >/dev/null
    echo "updated tracking issue #${existing} (${label})"
  else
    # Ensure the label exists (ignore failure if it already does).
    gh label create "$label" --repo "$REPO" --description "$desc" --color "$color" 2>/dev/null || true
    url="$(gh issue create --repo "$REPO" --title "$title" --label "$label" --body-file "$body")"
    echo "created tracking issue ${url} (${label})"
  fi
  rm -f "$body"
}

case "$OUTCOME" in
  pass)
    # A green run clears either condition — close whichever tracker(s) are open.
    reg="$(find_existing "$TITLE_REGRESSION" "$EVAL_HEALTH_LABEL")"
    inf="$(find_existing "$TITLE_INFRA" "$EVAL_INFRA_LABEL")"
    if [[ -z "$reg" ]] && [[ -z "$inf" ]]; then
      echo "eval health pass: no open tracking issue — nothing to do."
      exit 0
    fi
    if [[ -n "$reg" ]]; then _recover "$reg"; fi
    if [[ -n "$inf" ]]; then _recover "$inf"; fi
    ;;

  regression)
    _open_or_update "$TITLE_REGRESSION" "$EVAL_HEALTH_LABEL" \
      "Skill-eval holdout health tracking" "d93f0b"
    ;;

  error)
    # Distinct infra tracker (#920): an infra error never touches the regression
    # tracker, so a transient throttle cannot read as a held-out regression.
    _open_or_update "$TITLE_INFRA" "$EVAL_INFRA_LABEL" \
      "Skill-eval holdout infra-error tracking" "fbca04"
    ;;
esac
