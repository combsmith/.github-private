#!/usr/bin/env bash
# premature-closure-detect.sh — the premature-closure DETECTION net (issue #1077).
#
# #1077: the dev-lead agent closed tracking issues as `completed` without the fix
# actually landing on `main` — the issue closed, but the problem it described was
# still present, with NO merged PR that resolved it. The mechanical families were
# genuinely fixed; the harder families were closed on task-attempt rather than on
# a merged, verifying change. The org SonarCloud open-finding count was unchanged
# even after all the tracking issues closed as `state_reason = completed`.
#
# This is a set of PURE functions: given an issue's already-gathered close
# metadata, decide whether it is a premature-closure CANDIDATE. It never mutates
# an issue — surfacing/routing (report, re-open, re-label) is the caller's job
# (scripts/premature-closure-audit.sh).
#
#   premature_closure_reasons <state_reason> <minutes_open> <has_merged_closing_pr>
#     Prints one human-readable reason line when the issue is a candidate;
#     nothing otherwise. This is the unit under test.
#   is_premature_closure <state_reason> <minutes_open> <has_merged_closing_pr>
#     Exit 0 when a candidate, 1 otherwise.
#   minutes_between <iso_from> <iso_to>
#     Whole minutes between two ISO-8601 timestamps (clamped at 0, deterministic).
#   generate_premature_closure_report <candidates_tsv_file>
#     Renders the markdown report section from a candidates TSV.
#
# A candidate is the CONJUNCTION of three conditions (recommended action #3),
# chosen so a normal human close does NOT false-positive:
#   1. state_reason == completed        (closed as "done", not "not planned")
#   2. NO merged closing PR              (nothing actually landed the fix)
#   3. closed within N minutes of open   (the fast task-attempt tell)
# The window N is a SOFT, env-overridable threshold (strict <, matching the
# "within N minutes of open" wording).

# Soft threshold — an issue must have closed within this many minutes of opening
# to count as the fast dev-lead task-attempt close. Env-overridable.
readonly _PC_THRESHOLD_DEFAULT=30
: "${PC_MAX_OPEN_MINUTES:=$_PC_THRESHOLD_DEFAULT}"   # closed < this many minutes after open

# _pc_int <value>
#   Echo the value as a non-negative integer, or 0 for empty/non-numeric input.
#   Keeps a bad metric from breaking the integer comparisons below.
_pc_int() {
  case "${1:-}" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

# _pc_threshold <value> <default>
#   Like _pc_int but falls back to <default> instead of 0 for empty/non-numeric
#   input, so a bad env override can never silently set the window to 0 and
#   suppress every flag.
_pc_threshold() {
  local val="${1:-}" default="${2:-0}"
  case "$val" in
    ''|*[!0-9]*) echo "$default" ;;
    *) echo "$val" ;;
  esac
}

# _pc_is_truthy <value>
#   Exit 0 when <value> denotes "yes" (true/1/yes, case-insensitive), 1 otherwise.
#   Used to interpret the has_merged_closing_pr flag. Anything else (false/0/no/
#   empty/unknown) is NOT truthy — but note the caller must fail SAFE (treat an
#   undeterminable PR state as "has merged PR") so the audit never re-opens on a
#   lookup it could not resolve.
_pc_is_truthy() {
  local v="${1:-}"
  case "${v,,}" in
    true|1|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

# premature_closure_reasons <state_reason> <minutes_open> <has_merged_closing_pr>
#   Print a reason line when all three candidate conditions hold; empty otherwise.
premature_closure_reasons() {
  local state_reason minutes has_pr max_minutes
  state_reason="${1:-}"
  state_reason="${state_reason,,}"
  minutes=$(_pc_int "${2:-0}")
  has_pr="${3:-}"
  max_minutes=$(_pc_threshold "${PC_MAX_OPEN_MINUTES}" "$_PC_THRESHOLD_DEFAULT")

  # 1. Only a "completed" close is premature; "not_planned"/other are legitimate.
  [[ "$state_reason" = "completed" ]] || return 0
  # 2. A merged closing PR means the fix actually landed — not premature.
  if _pc_is_truthy "$has_pr"; then
    return 0
  fi
  # 3. Must be the fast task-attempt close (strict <, matching "within N minutes").
  [ "$minutes" -lt "$max_minutes" ] || return 0  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449

  printf 'closed as completed %sm after open with no merged closing PR (<%sm window)\n' \
    "$minutes" "$max_minutes"
  return 0
}

# is_premature_closure <state_reason> <minutes_open> <has_merged_closing_pr>
#   Exit 0 when the issue is a premature-closure candidate, 1 otherwise.
is_premature_closure() {
  local reasons
  reasons=$(premature_closure_reasons "$@")
  [[ -n "$reasons" ]]
}

# minutes_between <iso_from> <iso_to>
#   Whole minutes between two ISO-8601 timestamps. Negative intervals clamp to 0;
#   unparseable input yields 0. Deterministic — no reliance on the current time.
minutes_between() {
  local from="${1:-}" to="${2:-}" from_epoch to_epoch
  from_epoch=$(date -u -d "$from" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$from" +%s 2>/dev/null || true)
  to_epoch=$(date -u -d "$to" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$to" +%s 2>/dev/null || true)
  if [[ -z "$from_epoch" ]] || [[ -z "$to_epoch" ]]; then
    echo 0
    return 0
  fi
  local diff=$(( to_epoch - from_epoch ))
  [[ "$diff" -lt 0 ]] && diff=0
  echo $(( diff / 60 ))
}

# _pc_render_candidate_table <tsv_file>
#   Shared helper: render a markdown "| Issue | Title | Why flagged |" table
#   from a TSV file (columns: issue_number, html_url, title, reason). Called by
#   both generate_premature_closure_report and generate_unbacked_claim_report
#   after each prints its own header and all-clear handling.
_pc_render_candidate_table() {
  local f="${1:-}"
  printf '| Issue | Title | Why flagged |\n'
  printf '|---|---|---|\n'
  local num url title reason
  while IFS=$'\t' read -r num url title reason; do
    [[ -n "$num" ]] || continue
    title=${title//$'|'/'\|'}
    title=${title//$'\n'/ }
    reason=${reason//$'|'/'\|'}
    reason=${reason//$'\n'/ }
    printf '| [#%s](%s) | %s | %s |\n' "$num" "$url" "$title" "$reason"
  done < "$f"
}

# generate_premature_closure_report <candidates_tsv_file>
#   Render the "Premature-Closure Candidates" markdown section for the audit
#   report. Input TSV rows: issue_number <TAB> html_url <TAB> title <TAB> reason.
#   An empty/missing file prints an all-clear line and no table, so a clean run
#   still gets an explicit signal.
generate_premature_closure_report() {
  local f="${1:-}"
  local max_minutes
  max_minutes=$(_pc_threshold "${PC_MAX_OPEN_MINUTES}" "$_PC_THRESHOLD_DEFAULT")

  printf '## Premature-Closure Candidates\n\n'
  printf 'Issues closed as `completed` within %sm of opening with **no merged closing PR** ' "$max_minutes"
  printf '(the fix never landed on the default branch). See #1077 — dev-lead should '
  printf 'leave such issues open and labeled `dev-lead:needs-human`, not close them as done.\n\n'

  if [[ -z "$f" ]] || [[ ! -s "$f" ]]; then
    printf 'No prematurely-closed issue detected in the audited window.\n'
    return 0
  fi

  _pc_render_candidate_table "$f"
}

# ---------------------------------------------------------------------------
# Unbacked completion claim on an OPEN issue (issue #1445).
#
# #1445: dev-lead posted a highly specific "Completed" claim (checkmarked ACs,
# "726/726 pass", a per-file change table) on #1407 *before the work was durable*,
# then the run timed out and the workspace was discarded — nothing landed on
# `main`, yet the issue stays OPEN and reads as delivered. The premature-closure
# net above only inspects CLOSED issues, so this shape slips through. This is the
# machine-checkable detector (AC #5): given whether an OPEN issue carries a
# completion claim and whether a merged closing/linked PR backs it, decide whether
# it is an unbacked-claim CANDIDATE. Detection only — never mutates an issue.
#
# The marker a durable, trustworthy claim now carries (posted by
# scripts/dev-lead-fix-issue.sh only AFTER push+PR) and the machine marker a
# retracted claim carries.
readonly PC_COMPLETED_MARKER_TOKEN="status=completed"
readonly PC_CLAIM_RETRACTED_MARKER="<!-- dev-lead-claim-retracted -->"

# body_has_completion_claim <comment_body>
#   Exit 0 when the body reads as a completion claim: the durable
#   `status=completed` marker OR a legacy completion heading ("## Completed" /
#   "Implementation Complete"). Used to find the claim(s) to retract or to flag.
body_has_completion_claim() {
  case "${1:-}" in
    *"$PC_COMPLETED_MARKER_TOKEN"*)   return 0 ;;
    *"## Completed"*)                 return 0 ;;
    *"Implementation Complete"*)      return 0 ;;
    *)                                return 1 ;;
  esac
}

# claim_is_retracted <comment_body>
#   Exit 0 when the body already carries the retraction marker — so retraction is
#   idempotent (never double-strikes) and the audit never re-flags a withdrawn claim.
claim_is_retracted() {
  case "${1:-}" in
    *"$PC_CLAIM_RETRACTED_MARKER"*) return 0 ;;
    *)                              return 1 ;;
  esac
}

# supersede_claim_body <original_body> <banner>
#   Rewrite a standing completion-claim body to retract it IN PLACE: prepend
#   <banner> (which must carry PC_CLAIM_RETRACTED_MARKER + a dated note) and strike
#   through the first markdown heading, leaving the rest legible below. Reuses the
#   strike-through-plus-dated-note convention from docs/metrics-baseline.md. Pure —
#   no I/O; the caller supplies the dated banner and performs the comment edit.
supersede_claim_body() {
  local body="${1:-}" banner="${2:-}"
  printf '%s\n' "$banner"
  local line prefix text struck=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$struck" -eq 0 ]]; then
      case "$line" in
        '#'*)
          # Split the leading run of '#'/spaces from the heading text, then strike
          # only the text so the markdown heading level is preserved.
          prefix="${line%%[! #]*}"
          text="${line#"$prefix"}"
          printf '%s~~%s~~ [RETRACTED]\n' "$prefix" "$text"
          struck=1
          continue ;;
      esac
    fi
    printf '%s\n' "$line"
  done <<< "$body"
}

# unbacked_completion_claim_reasons <has_completion_claim> <has_backing_pr>
#   Print a reason line when an OPEN issue carries a completion claim with no
#   backing PR; empty otherwise. For an OPEN issue "backing" means *any* linked PR
#   (open or merged) — an in-flight dev-lead PR is a legitimate artifact, so
#   requiring a *merged* PR here would false-positive on every healthy open PR
#   (that is why the CLOSED-issue premature_closure_reasons — where a fix should
#   already have landed — requires merged, but this OPEN-issue analogue does not).
#   The caller must fail SAFE — pass has_backing_pr=true whenever the PR state
#   cannot be determined — so an undeterminable lookup never flags.
unbacked_completion_claim_reasons() {
  local has_claim has_pr
  has_claim="${1:-}"
  has_pr="${2:-}"
  # 1. No completion claim → nothing to flag.
  _pc_is_truthy "$has_claim" || return 0
  # 2. Any linked PR backs the claim → not unbacked.
  if _pc_is_truthy "$has_pr"; then
    return 0
  fi
  printf 'carries a completion claim with no backing PR (unbacked)\n'
  return 0
}

# is_unbacked_completion_claim <has_completion_claim> <has_backing_pr>
#   Exit 0 when the issue is an unbacked-claim candidate, 1 otherwise.
is_unbacked_completion_claim() {
  local reasons
  reasons=$(unbacked_completion_claim_reasons "$@")
  [[ -n "$reasons" ]]
}

# generate_unbacked_claim_report <candidates_tsv_file>
#   Render the "Unbacked Completion Claims (open)" markdown section. Input TSV
#   rows: issue_number <TAB> html_url <TAB> title <TAB> reason. An empty/missing
#   file prints an all-clear line and no table, so a clean run gets an explicit
#   signal (same shape as generate_premature_closure_report).
generate_unbacked_claim_report() {
  local f="${1:-}"

  printf '## Unbacked Completion Claims (open issues)\n\n'
  printf 'Open issues carrying a "Completed" claim with **no backing PR** '
  printf '(no linked pull request exists, so the claimed work never became durable). See '
  printf '#1445 — a completion claim must be backed by a verifiable artifact (PR/SHA) and '
  printf 'retracted on terminal failure.\n\n'

  if [[ -z "$f" ]] || [[ ! -s "$f" ]]; then
    printf 'No open issue with an unbacked completion claim detected in the audited window.\n'
    return 0
  fi

  _pc_render_candidate_table "$f"
}
