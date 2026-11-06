#!/usr/bin/env bash
# issue-comments.sh — render a work-issue's comments for the dev-lead
# implementation prompt (#1566).
#
# Before #1566, dev-lead-fix-issue.sh exported only the issue TITLE and BODY into
# the rendered prompt; comments never reached the engine, so any clarification,
# correction, or answer posted after filing was silently discarded (see #1566 for
# the observed #637 failure). These PURE functions take the (possibly paginated)
# `issues/<n>/comments` JSON on stdin and emit a filtered, chronological,
# size-bounded markdown block the caller exports as ISSUE_COMMENTS. Fetching the
# comments is the caller's job (dev-lead-fix-issue.sh).
#
# It is a set of PURE functions with NO network I/O and NO top-level side effects
# beyond default-value assignment, so it can be sourced by both the driver and its
# unit tests (tests/dev-lead/unit/test_issue_comments.bats). It does NOT call
# `set -euo pipefail` — sourced-library exception: adding it would change the
# caller's shell options (mirroring the approved convention in comment-noise.sh /
# persona-runner.sh; see AGENTS.md Bash guideline note).

# Size bounds (overridable via env for tuning/tests). A long thread must never
# blow the context window (#1566 AC #4), and whatever is dropped is STATED in the
# rendered block rather than silently discarded.
: "${ISSUE_COMMENTS_MAX:=20}"            # keep at most the most-recent N human comments
: "${ISSUE_COMMENTS_CHAR_BUDGET:=16000}" # total character budget across kept comment bodies

# ic_noise_pattern — ERE identifying a comment that is dev-lead's own automation
# chatter rather than human steering (#1566 AC #3). Two shapes, anchored to the
# start of the body so a human quoting them mid-comment is not misclassified:
#   ^\s*<!-- *dev-lead   — every dev-lead HTML marker family (issue status,
#                          dedup, defer, lint-failed, retraction, completion).
#   ^\s*## *Dev-Lead     — the plan / progress / completion headings dev-lead
#                          posts (these carry no HTML marker but always lead with
#                          this heading), so they never crowd out human comments.
ic_noise_pattern() {
  printf '%s' '^[[:space:]]*(<!-- *dev-lead|## *Dev-Lead)'
}

# _ic_filter_human: read the paginated comments JSON on stdin; emit one
# base64-encoded {login,created_at,body} object per SURVIVING comment, in
# chronological (API) order. Drops Bot-type authors, comments from users WITHOUT
# repository write access (#1800: only author_association OWNER/MEMBER/COLLABORATOR
# is trusted — a drive-by CONTRIBUTOR/NONE commenter must not redirect the
# implementation), dev-lead automation comments (ic_noise_pattern), and empty
# bodies. The trust filter FAILS CLOSED (#1872): a missing, null, or empty
# author_association is untrusted and the comment is dropped — absence of
# evidence of trust is not evidence of trust. Real GitHub API comments always
# carry the field; any caller that synthesizes comment objects must set it
# explicitly at the construction site. Every trust drop is logged to STDERR
# (login + reason, never the body), distinguishing "no author_association" from
# an untrusted association, so an ingestion path that stops populating the field
# surfaces as dropped comments rather than silently-trusted ones. jq's `-s`
# slurps every page into one array; `[.[] | .[]?]` flattens both the
# single-array and paginated (array-per-page) shapes, mirroring
# count_prior_attempts in the driver.
_ic_filter_human() {
  jq -s -r --arg noise "$(ic_noise_pattern)" '
    [ .[] | .[]? ]
    | map(select(type == "object"))
    | map(select((.body // "") != ""))
    | map(select(((.user.type?) // "") != "Bot"))
    | .[]
    | (.user.login? // "unknown") as $login
    | ((.author_association? // "") | tostring | ascii_upcase) as $aa
    # Drop records are tab/newline-delimited text, so control characters in the
    # logged fields are neutralised — they must never be able to forge a K line.
    | ($login | tostring | gsub("[[:cntrl:]]"; "?")) as $safe_login
    | if $aa == "" then
        "D\t\($safe_login)\tno author_association (treated as untrusted)"
      elif ($aa == "OWNER" or $aa == "MEMBER" or $aa == "COLLABORATOR") | not then
        "D\t\($safe_login)\tauthor_association=\($aa | gsub("[[:cntrl:]]"; "?")) (no write access)"
      elif (.body // "") | test($noise) then
        empty
      else
        "K\t" + ({ login: $login,
                   created_at: (.created_at // ""),
                   body: (.body // "") } | @base64)
      end
  ' 2>/dev/null | while IFS=$'\t' read -r tag a b || [[ -n "$tag" ]]; do
    case "$tag" in
      K) printf '%s\n' "$a" ;;
      D) printf 'issue-comments: dropped comment by @%s: %s\n' "$a" "$b" >&2 ;;
    esac
  done || true
}

# render_issue_comments: read the paginated comments JSON on stdin; print the
# rendered markdown block (or an explicit "no human comments" note — never
# nothing). Honors ISSUE_COMMENTS_MAX (most-recent-N) then ISSUE_COMMENTS_CHAR_BUDGET
# (applied newest-first so the freshest steering always survives). Any comment
# dropped by either bound is COUNTED and the omission is stated (#1566 AC #4).
render_issue_comments() {
  local -a rows=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && rows+=( "$line" )
  done < <(_ic_filter_human)

  local total=${#rows[@]}
  if [[ "$total" -eq 0 ]]; then
    printf '_No human comments on this issue — only the title and body above are available. (Bot and dev-lead status comments are excluded.)_\n'
    return 0
  fi

  # 1) Most-recent-N window. Comments are chronological, so keep the tail.
  local start=0
  if [ "$total" -gt "$ISSUE_COMMENTS_MAX" ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
    start=$(( total - ISSUE_COMMENTS_MAX ))
  fi

  # 2) Character budget over that window, applied newest→oldest so the latest
  #    (highest-priority) steering is never the comment that gets dropped. The
  #    budget is a HARD bound (#1800): if the single newest comment alone exceeds
  #    it, that comment's body is TRUNCATED to the budget (and the truncation is
  #    stated) rather than emitted in full, so the rendered block can never blow
  #    the documented prompt-size limit.
  local -a keep_idx=()
  local used=0 i obj body blen
  local newest_trunc=0   # chars the newest comment's body was truncated to (0 = untruncated)
  for (( i = total - 1; i >= start; i-- )); do
    obj=$(printf '%s' "${rows[$i]}" | base64 -d 2>/dev/null) || continue
    body=$(printf '%s' "$obj" | jq -r '.body' 2>/dev/null) || continue
    blen=${#body}
    if [[ "${#keep_idx[@]}" -eq 0 ]]; then
      # Newest comment always survives, but is truncated to the budget if it
      # alone is oversized — otherwise the budget would not be a hard bound.
      if [ "$blen" -gt "$ISSUE_COMMENTS_CHAR_BUDGET" ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
        newest_trunc=$ISSUE_COMMENTS_CHAR_BUDGET
        used=$ISSUE_COMMENTS_CHAR_BUDGET
      else
        used=$blen
      fi
      keep_idx+=( "$i" )
      continue
    fi
    if [ $(( used + blen )) -gt "$ISSUE_COMMENTS_CHAR_BUDGET" ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
      break
    fi
    used=$(( used + blen ))
    keep_idx+=( "$i" )
  done

  local kept=${#keep_idx[@]}
  local omitted=$(( total - kept ))
  local newest_idx=${keep_idx[0]}

  # Header +, when anything was dropped or truncated, an explicit note.
  printf '### Issue comments (%d shown, chronological — later human comments take precedence)\n\n' "$kept"
  if [[ "$omitted" -gt 0 ]]; then
    printf '> _Note: this issue has %d human comment(s); showing only the most recent %d to fit the prompt budget. %d earlier human comment(s) were omitted — read them on the issue if needed. Bot and dev-lead status comments are excluded from this list._\n\n' \
      "$total" "$kept" "$omitted"
  fi
  if [ "$newest_trunc" -gt 0 ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
    printf '> _Note: the most recent comment exceeded the %d-character budget and was truncated to fit — read the full comment on the issue._\n\n' \
      "$ISSUE_COMMENTS_CHAR_BUDGET"
  fi

  # Emit kept comments in chronological order (keep_idx is newest-first).
  local login created
  for (( i = kept - 1; i >= 0; i-- )); do
    local idx=${keep_idx[$i]}
    obj=$(printf '%s' "${rows[$idx]}" | base64 -d 2>/dev/null) || continue
    login=$(printf '%s' "$obj" | jq -r '.login' 2>/dev/null) || login="unknown"
    created=$(printf '%s' "$obj" | jq -r '.created_at' 2>/dev/null) || created=""
    body=$(printf '%s' "$obj" | jq -r '.body' 2>/dev/null) || body=""
    if [ "$newest_trunc" -gt 0 ] && [ "$idx" -eq "$newest_idx" ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
      body="${body:0:$newest_trunc}"$'\n\n_[Comment truncated to fit the prompt budget — read the full comment on the issue.]_'
    fi
    printf '#### @%s — %s\n\n%s\n\n' "$login" "$created" "$body"
  done
}
