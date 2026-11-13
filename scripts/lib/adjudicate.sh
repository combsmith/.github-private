# shellcheck shell=bash
# scripts/lib/adjudicate.sh — tier 4 "adjudicate" of the PR-review cascade (#2495).
#
# The cascade hands a PR to a human when its verdict would escalate
# (post-pr-review.sh's decision=escalate branch) or when the review-cycle cap is
# reached (review-one-pr.sh). Tier 4 puts a second opinion from the strongest
# model, Fable, in front of both. Fable sees the diff and every prior tier's
# output and returns the same JSON contract as the other tiers. Only a confirmed
# `escalate` goes on to the human. An `approve` or `request_changes` replaces
# the verdict that gets posted.
#
# Guardrails:
#   - Opt-in: the Actions variable PR_REVIEW_ADJUDICATE=true. Anything else is off.
#   - The model is `ai_model_for_family fable`, never a hard-pinned id.
#   - The verdict is read only from $OUTPUT_FILE and validated strictly. It is
#     never parsed out of the model's discussion text.
#   - A rate limit, an error or invalid JSON falls back to today's human
#     escalation. Tier 4 never approves by default.
#   - Fable may not approve a PR whose security audit reported HIGH risk.
#   - One adjudication per head SHA, recorded by a bot-authored marker:
#       <!-- pr-review-agent adjudicate v1 sha=<SHA> trigger=… outcome=… decision=… overrode=… -->
#     On the cycle-cap path tier 4 also never re-runs itself: once it has run
#     since the last reset (the same reset events as the cycle cap), the cap goes
#     straight to a human.
#
# Out of scope (these go straight to a human, as before): a single-review failure
# after retries, a label-write failure, and the dev-lead guards.
#
# Sourced by review-one-pr.sh and post-pr-review.sh. Defines functions only.

_ADJ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reset-event definitions (_REVIEW_CYCLE_JQ_DEFS) and AUTOMATION_BOT_LOGINS.
if [[ -z "${_REVIEW_CYCLE_JQ_DEFS:-}" ]]; then
  # shellcheck source=review-cycle.sh
  source "$_ADJ_LIB_DIR/review-cycle.sh"
fi

ADJUDICATE_MARKER_PREFIX='<!-- pr-review-agent adjudicate v1 sha='
: "${ADJUDICATE_PROMPT:=$_ADJ_LIB_DIR/../../prompts/adjudicate.md}"
# Per-section cap on the context inlined into the adjudication prompt.
: "${ADJUDICATE_CONTEXT_MAX_CHARS:=40000}"
# A non-numeric or zero cap would make `head -c` abort the review: fall back.
if [[ ! "$ADJUDICATE_CONTEXT_MAX_CHARS" =~ ^[1-9][0-9]*$ ]]; then
  ADJUDICATE_CONTEXT_MAX_CHARS=40000
fi

# adjudicate_enabled — 0 only when PR_REVIEW_ADJUDICATE is the literal `true`.
adjudicate_enabled() {
  [[ "${PR_REVIEW_ADJUDICATE:-false}" == "true" ]]
}

# adjudicate_escalates_to_human <decision> <risk>
#   0 when post-pr-review.sh would hand this verdict to a human: an `escalate`
#   that does not qualify for an automated fix-request (AI delegation on, review
#   cycles left, risk not HIGH). The single source of that rule for both scripts.
adjudicate_escalates_to_human() {
  local decision="${1:-}" risk="${2:-}"
  [[ "$decision" == "escalate" ]] || return 1
  if [[ "${AI_DELEGATION_ENABLED:-false}" == "true" ]] \
     && [ "${REVIEW_CYCLE:-0}" -lt "${MAX_REVIEW_CYCLES:-3}" ] \
     && [[ "$risk" != "HIGH" ]]; then
    return 1
  fi
  return 0
}

# _adj_bots_json — automation logins (AUTOMATION_BOT_LOGINS plus BOT_USER) as JSON.
_adj_bots_json() {
  printf '%s %s' "${AUTOMATION_BOT_LOGINS:-}" "${BOT_USER:-donpetry-bot}" \
    | jq -R 'split(" ") | map(select(. != "")) | unique' 2>/dev/null || echo '[]'
}

# adjudicate_done_at_sha <items_json> <sha>
#   0 when an automation-authored review/comment already records an adjudication
#   at <sha>. A marker pasted by anyone else does not count.
adjudicate_done_at_sha() {
  local items="${1:-[]}" sha="${2:-}"
  [[ -n "$sha" ]] || return 1
  jq -e --argjson bots "$(_adj_bots_json)" --arg m "${ADJUDICATE_MARKER_PREFIX}${sha} " \
    "$_REVIEW_CYCLE_JQ_DEFS"'
    any(.[]; is_automation_author($bots) and ((.body // "") | contains($m)))
  ' <<<"$items" >/dev/null 2>&1
}

# _ADJ_RESET_JQ — jq that binds $reset to the latest cycle-cap reset event (a
# human approval or a human escalation), exactly as compute_review_cycle does.
_ADJ_RESET_JQ='
  map(select(.when != null and .when != ""))
  | ([.[] | select(is_human_approval($bots)) | .when] | max // "") as $last_approval
  | ([.[] | select(is_escalation) | (escalation_reset_ts($bots) // .when)] | max // "") as $last_escalation
  | (if $last_approval > $last_escalation then $last_approval else $last_escalation end) as $reset
'

# adjudicate_since_reset <items_json>
#   0 when tier 4 already ran (bot-authored marker) after the latest reset event,
#   so a cap reached after tier 4's own verdict goes straight to a human. A marker
#   inside an escalation comment does not count: that comment IS a reset event, and
#   its createdAt can trail its own `reset=` stamp, so its tier-4 run belongs to the
#   window it closed, not the next one.
adjudicate_since_reset() {
  local items="${1:-[]}"
  jq -e --argjson bots "$(_adj_bots_json)" --arg m "$ADJUDICATE_MARKER_PREFIX" \
    "$_REVIEW_CYCLE_JQ_DEFS$_ADJ_RESET_JQ"'
    | any(.[]; is_automation_author($bots) and ((.body // "") | contains($m))
               and (is_escalation | not) and (.when > $reset))
  ' <<<"$items" >/dev/null 2>&1
}

# adjudicate_prior_reviews <items_json>
#   Print the cascade's own verdicts since the latest reset (the prior cycles the
#   cap counted), oldest first, the last five, each capped.
adjudicate_prior_reviews() {
  local items="${1:-[]}"
  jq -r --argjson bots "$(_adj_bots_json)" "$_REVIEW_CYCLE_JQ_DEFS$_ADJ_RESET_JQ"'
    | [.[] | select(is_automation_author($bots) and has_marker and (.when > $reset))]
    | sort_by(.when) | .[-5:] | .[]
    | "--- \(.when) ---\n\((.body // "") | .[0:6000])\n"
  ' <<<"$items" 2>/dev/null || true
}

# adjudicate_validate <file>
#   0 when <file> holds the tier-4 contract: an object with decision
#   approve|request_changes|escalate, risk LOW|MEDIUM|HIGH, a non-empty summary
#   string and a findings array. Anything else is invalid and never approves.
adjudicate_validate() {
  local f="${1:-}"
  [[ -f "$f" ]] && [[ ! -L "$f" ]] && [[ -s "$f" ]] || return 1
  jq -e '
    type == "object"
    and ((.decision // "") | IN("approve", "request_changes", "escalate"))
    and ((.risk // "") | IN("LOW", "MEDIUM", "HIGH"))
    and ((.summary | type) == "string") and ((.summary | length) > 0)
    and ((.findings | type) == "array")
  ' "$f" >/dev/null 2>&1
}

# adjudicate_guard <decision> <audit_risk>
#   Echo the decision after the guardrails: an approve over a security audit that
#   reported HIGH risk becomes escalate. <audit_risk> is empty when no audit ran.
adjudicate_guard() {
  local decision="${1:-}" audit_risk="${2:-}"
  if [ "$decision" = "approve" ] && [ "$audit_risk" = "HIGH" ]; then
    echo "escalate"
  else
    echo "$decision"
  fi
}

# adjudicate_context_append <ctx_file> <label> <file>
#   Append <file> to the prompt context under a heading, capped. Absent or empty
#   files are skipped.
adjudicate_context_append() {
  local ctx="$1" label="$2" f="$3"
  [[ -s "$f" ]] || return 0
  {
    printf '### %s\n\n```\n' "$label"
    head -c "$ADJUDICATE_CONTEXT_MAX_CHARS" "$f"
    printf '\n```\n\n'
  } >> "$ctx"
}

# _adj_is_rate_limited <text> — engine.sh's is_rate_limited when loaded.
_adj_is_rate_limited() {
  if declare -F is_rate_limited >/dev/null 2>&1; then
    is_rate_limited "$1"
  else
    printf '%s\n' "$1" | grep -qiE 'rate.?limit|usage limit|429|overloaded'
  fi
}

# run_adjudication <trigger> <context_file> <out_file>
#   Run Fable over the adjudicate prompt plus <context_file>, which writes its
#   verdict to <out_file> ($OUTPUT_FILE). Sets:
#     ADJ_MODEL    the resolved Fable id (ai_model_for_family fable)
#     ADJ_OUTCOME  ok | rate-limited | error | invalid-json | engine-unsupported
#   Returns 0 only when <out_file> holds a valid verdict. A failure never exits
#   the caller and never produces a verdict, so the caller escalates to a human.
#   Token records go to TOKEN_LOG_FILE through run_agentic under tier `adjudicate`.
run_adjudication() {
  local trigger="$1" ctx="$2" out="$3"
  local dir prompt stdout_f stderr_f rc=0 so se
  ADJ_OUTCOME="" ADJ_MODEL=""
  if ! declare -F ai_model_for_family >/dev/null 2>&1; then
    # shellcheck source=engine-models.sh
    source "$_ADJ_LIB_DIR/engine-models.sh"
  fi
  ADJ_MODEL="$(ai_model_for_family fable 2>/dev/null)" || ADJ_MODEL=""
  if [[ "${REVIEW_ENGINE:-claude}" != "claude" ]]; then
    echo "    [tier4] Fable needs the claude engine (REVIEW_ENGINE=${REVIEW_ENGINE:-}) — not adjudicating"
    ADJ_OUTCOME="engine-unsupported"
    return 1
  fi
  if [[ -z "$ADJ_MODEL" ]] || ! declare -F run_agentic >/dev/null 2>&1; then
    echo "::warning::[tier4] could not resolve the Fable model or the engine is not loaded — not adjudicating"
    ADJ_OUTCOME="error"
    return 1
  fi

  dir="$(dirname "$out")"
  mkdir -p "$dir"
  prompt="$dir/adjudicate-prompt.md"
  stdout_f="$dir/adjudicate-stdout.txt"
  stderr_f="$dir/adjudicate.log"
  {
    cat "$ADJUDICATE_PROMPT"
    printf '\n\n## Adjudication context\n\n'
    printf 'PR_URL: %s\n' "${PR_URL:-}"
    printf 'PR_HEAD_SHA: %s\n' "${PR_HEAD_SHA:-}"
    printf 'ADJUDICATION_TRIGGER: %s\n\n' "$trigger"
    cat "$ctx" 2>/dev/null || true
  } > "$prompt"
  rm -f "$out"

  # A subshell keeps the caller's OUTPUT_FILE untouched.
  # Timeout tier 4 to 25 minutes, reserving ~35 minutes in a 60-minute job for
  # earlier tiers and the fallback human escalation.
  ( export OUTPUT_FILE="$out"; timeout 25m run_agentic "$prompt" "$ADJ_MODEL" adjudicate ) \
    >"$stdout_f" 2>"$stderr_f" || rc=$?
  so="$(cat "$stdout_f" 2>/dev/null || true)"
  se="$(cat "$stderr_f" 2>/dev/null || true)"

  if [[ "$rc" -ne 0 ]]; then
    if _adj_is_rate_limited "$so" || _adj_is_rate_limited "$se"; then
      ADJ_OUTCOME="rate-limited"
    else
      ADJ_OUTCOME="error"
    fi
    echo "::warning::[tier4] adjudication run failed (exit $rc, $ADJ_OUTCOME) — falling back to human escalation"
    [[ -n "$se" ]] && printf '    [tier4] stderr: %s\n' "${se:0:2000}"
    return 1
  fi
  if ! adjudicate_validate "$out"; then
    if [ ! -s "$out" ] && { _adj_is_rate_limited "$so" || _adj_is_rate_limited "$se"; }; then
      ADJ_OUTCOME="rate-limited"
    else
      ADJ_OUTCOME="invalid-json"
    fi
    echo "::warning::[tier4] adjudication did not write a valid verdict to OUTPUT_FILE ($ADJ_OUTCOME) — falling back to human escalation"
    return 1
  fi
  ADJ_OUTCOME="ok"
  return 0
}

# _adj_safe <value> — <value> if it is a plain token, else `invalid`, so nothing
# read back from a verdict can close the marker comment or inject markup.
_adj_safe() {
  local v="${1:-}"
  if [[ "$v" =~ ^[A-Za-z0-9._:/@-]*$ ]]; then printf '%s' "$v"; else printf 'invalid'; fi
}

# adjudicate_record_json <trigger> <model> <outcome> <decision> <overrode> <guard>
#   The structured record attached to a verdict as `.adjudication`. <decision> is
#   empty when no valid verdict came back; <guard> is `audit-high` or empty.
adjudicate_record_json() {
  jq -cn --arg t "${1:-}" --arg m "${2:-}" --arg o "${3:-}" --arg d "${4:-}" \
    --arg ov "${5:-false}" --arg g "${6:-}" \
    '{trigger:$t, model:$m, outcome:$o, decision:$d, overrode:($ov == "true"), guard:$g}'
}

# _adj_field <record_json> <field>
_adj_field() {
  local v
  v="$(jq -r --arg f "$2" '.[$f] | if . == null then "" else tostring end' <<<"$1" 2>/dev/null || true)"
  _adj_safe "$v"
}

# adjudicate_note <record_json> <sha>
#   The marker plus a markdown line stating that tier 4 ran, its model, its
#   decision and whether it overrode the escalation (or why it fell back).
adjudicate_note() {
  local rec="$1" sha t m o d ov g dw yn line
  sha="$(_adj_safe "$2")"
  t="$(_adj_field "$rec" trigger)"; m="$(_adj_field "$rec" model)"
  o="$(_adj_field "$rec" outcome)"; d="$(_adj_field "$rec" decision)"
  ov="$(_adj_field "$rec" overrode)"; g="$(_adj_field "$rec" guard)"
  [[ "$ov" == "true" ]] || ov="false"
  dw="${d:-none}"
  [[ "$ov" == "true" ]] && yn="yes" || yn="no"
  printf '%s%s trigger=%s outcome=%s decision=%s overrode=%s -->\n' \
    "$ADJUDICATE_MARKER_PREFIX" "$sha" "${t:-unknown}" "${o:-unknown}" "$dw" "$ov"
  case "$o" in
    ok)
      line="**Tier 4 (adjudicate):** ran on \`${m:-unknown}\` (trigger: ${t:-unknown}) — decision: **${dw}**; overrode the human escalation: **${yn}**. FINAL_TIER=adjudicate"
      if [ "$g" = "audit-high" ]; then
        line="$line"$'\n\n'"Fable returned **approve**, but the security audit reported HIGH risk, so the PR still escalates to a human (guardrail)."
      fi
      ;;
    rate-limited) line="**Tier 4 (adjudicate):** ran on \`${m:-unknown}\` but was rate-limited — falling back to human escalation (no override)." ;;
    invalid-json) line="**Tier 4 (adjudicate):** ran on \`${m:-unknown}\` but returned invalid JSON — falling back to human escalation (no override)." ;;
    engine-unsupported) line="**Tier 4 (adjudicate):** could not run \`${m:-unknown}\`: Fable needs the claude engine — falling back to human escalation (no override)." ;;
    context-error) line="**Tier 4 (adjudicate):** could not gather the PR context for \`${m:-unknown}\` — falling back to human escalation (no override)." ;;
    *) line="**Tier 4 (adjudicate):** ran on \`${m:-unknown}\` but errored — falling back to human escalation (no override)." ;;
  esac
  printf '%s\n' "$line"
}

# adjudicate_log_line <record_json> — the run-log line for tier 4.
adjudicate_log_line() {
  local rec="$1" g
  g="$(_adj_field "$rec" guard)"
  printf '    [tier4] adjudicate ran: model=%s trigger=%s outcome=%s decision=%s overrode=%s%s\n' \
    "$(_adj_field "$rec" model)" "$(_adj_field "$rec" trigger)" "$(_adj_field "$rec" outcome)" \
    "$(d="$(_adj_field "$rec" decision)"; printf '%s' "${d:-none}")" \
    "$(_adj_field "$rec" overrode)" "${g:+ guard=$g}"
}

# adjudicate_strip <verdict_file>
#   Remove any `.adjudication` a model wrote into its own verdict, in place. Only
#   tier 4 (this file) may attach the record; post-pr-review.sh acts on it, so a
#   self-claimed record could otherwise turn a human escalation into a fix-request.
#   A verdict without the field is left byte-identical.
adjudicate_strip() {
  local v="$1" tmp
  jq -e 'type == "object" and has("adjudication")' "$v" >/dev/null 2>&1 || return 0
  tmp="$(mktemp)" || return 1
  if jq 'del(.adjudication)' "$v" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$v"
  else
    rm -f "$tmp"
    return 1
  fi
}

# adjudicate_attach <verdict_file> <record_json> — add `.adjudication` in place.
adjudicate_attach() {
  local v="$1" rec="$2" tmp
  tmp="$(mktemp)" || return 1
  if jq --argjson a "$rec" '. + {adjudication: $a}' "$v" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$v"
  else
    rm -f "$tmp"
    return 1
  fi
}

# adjudicate_build_verdict <adj_out> <final_decision> <record_json> <sha> <prior_tier> <out_verdict>
#   Build the verdict that replaces an escalation. The marker and layout are built
#   here, never taken from model text. HTML comments are stripped from the model's
#   summary and findings, so they cannot smuggle a marker into the body.
#     approve          → decision approve with a complete approval marker
#     request_changes  → decision escalate tagged `.adjudication.decision`, which
#                        post-pr-review.sh posts as a fix-request
adjudicate_build_verdict() {
  local adj="$1" final="$2" rec="$3" sha="$4" prior="$5" outv="$6" model
  model="$(_adj_field "$rec" model)"
  jq --arg final "$final" --arg sha "$sha" --arg prior "$(_adj_safe "$prior")" \
     --arg model "$model" --argjson rec "$rec" '
    def clean: tostring | gsub("<!--[\\s\\S]*?-->"; "") | gsub("<!--[\\s\\S]*$"; "");
    (.summary | clean) as $summary
    | ((.findings // []) | map(if type == "object" then
          {severity: ((.severity // "INFO") | clean), description: ((.description // tostring) | clean)}
        else {severity: "INFO", description: clean} end)) as $findings
    | ($findings | map("- **\(.severity)**: \(.description)") | join("\n")) as $ftext
    | (if $ftext == "" then "- No specific findings" else $ftext end) as $ftext
    | .risk as $risk
    | if $final == "approve" then
        {decision: "approve", risk: $risk, summary: $summary, findings: $findings,
         escalate_to_ai: false, metadata_only: false, adjudication: $rec,
         body: ("<!-- pr-review-agent v1 sha=\($sha) decision=approved risk=\($risk) -->\n\n"
           + "## Automated review — APPROVED ✓ (adjudicated)\n\n"
           + "**Risk:** \($risk)\n**Reviewed commit:** `\($sha)`\n"
           + "**Cascade:** triage → \(if $prior == "" then "cascade" else $prior end) → adjudicate (\($model))\n"
           + "`FINAL_TIER: adjudicate`\n\n"
           + "### Summary\n\($summary)\n\n### Findings\n\($ftext)\n\n---\n"
           + "_Tier 4 (adjudicate) replaced an escalation to a human with this approval. Reply if you need a human review._")}
      else
        {decision: "escalate", risk: $risk, summary: $summary, findings: $findings,
         escalate_to_ai: true, metadata_only: false, adjudication: $rec,
         body: ("**Adjudication (tier 4, \($model)):** \($summary)\n\n\($ftext)\n\n`FINAL_TIER: adjudicate`")}
      end
  ' "$adj" > "$outv"
}

# adjudicate_cascade_verdict <verdict_file> <audit_risk> <items_json> <diff_file> [<label>|<file> ...]
#   Tier 4 on a cascade verdict that would escalate to a human (review-one-pr.sh's
#   post_cascade_verdict). Rewrites <verdict_file> in place:
#     - Fable approve / request_changes → the replacement verdict (FINAL_TIER is
#       exported as `adjudicate`);
#     - a confirmed escalate, an approve blocked by a HIGH security audit, or any
#       failure → the original verdict plus an `.adjudication` record, so
#       post-pr-review.sh still escalates and states what tier 4 did;
#     - already adjudicated at this head SHA → untouched (one per head SHA).
#   <audit_risk> is the security audit's risk, empty when tier 3 did not run. The
#   context is every "<label>|<file>" prior-tier output plus the verdict and diff.
adjudicate_cascade_verdict() {
  local verdict="$1" audit_risk="${2:-}" items="${3:-[]}" diff="${4:-}"
  shift 4 || shift $#
  local dir ctx out entry raw final guard="" rec
  dir="${ADJUDICATE_WORK_DIR:-/tmp/cascade}"
  ctx="$dir/adjudicate-context.md"
  out="$dir/adjudicate.json"
  if adjudicate_done_at_sha "$items" "${PR_HEAD_SHA:-}"; then
    echo "    [tier4] adjudicate skipped: tier 4 already ran at ${PR_HEAD_SHA:-} (one adjudication per head SHA) — escalating to a human"
    return 0
  fi
  echo "    [tier4] the cascade verdict would escalate to a human — adjudicating"
  mkdir -p "$dir"
  : > "$ctx"
  for entry in "$@"; do
    adjudicate_context_append "$ctx" "${entry%%|*}" "${entry#*|}"
  done
  adjudicate_context_append "$ctx" "cascade verdict (would escalate to a human)" "$verdict"
  # Validate diff: reject empty or whitespace-only diff before calling run_adjudication
  if [[ -n "$diff" ]] && [[ -s "$diff" ]] && grep -qvE '^[[:space:]]*$' "$diff" 2>/dev/null; then
    adjudicate_context_append "$ctx" "PR diff (truncated to 3000 lines)" "$diff"
  elif [[ -n "$diff" ]]; then
    # Diff was empty or whitespace-only: context error
    ADJ_MODEL="$(ai_model_for_family fable 2>/dev/null || true)"
    rec=$(adjudicate_record_json cascade-escalate "$ADJ_MODEL" context-error "" false "")
    echo "::warning::[tier4] PR diff is empty or whitespace-only — cannot adjudicate without context"
    adjudicate_log_line "$rec"
    adjudicate_attach "$verdict" "$rec" || true
    return 0
  fi
  if run_adjudication cascade-escalate "$ctx" "$out"; then
    raw=$(jq -r '.decision' "$out")
    final=$(adjudicate_guard "$raw" "$audit_risk")
    [[ "$raw" != "$final" ]] && guard="audit-high"
    if [[ "$final" == "approve" ]] || [[ "$final" == "request_changes" ]]; then
      rec=$(adjudicate_record_json cascade-escalate "$ADJ_MODEL" ok "$final" true "")
      adjudicate_build_verdict "$out" "$final" "$rec" "${PR_HEAD_SHA:-}" "${FINAL_TIER:-single}" "$verdict"
      export FINAL_TIER="adjudicate"
    else
      rec=$(adjudicate_record_json cascade-escalate "$ADJ_MODEL" ok escalate false "$guard")
      adjudicate_attach "$verdict" "$rec" || true
    fi
  else
    rec=$(adjudicate_record_json cascade-escalate "$ADJ_MODEL" "$ADJ_OUTCOME" "" false "")
    adjudicate_attach "$verdict" "$rec" || true
  fi
  adjudicate_log_line "$rec"
}
