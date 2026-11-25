#!/usr/bin/env bash
# pr-review-miss-rate.sh — DETERMINISTIC false-negative metric for pr-review (#1596).
#
# We already measure pr-review's operational health (pr_review_health.sh) and its
# false POSITIVES (evals/deep-review). This library adds the one signal that was
# free and perfectly labelled but evaporating: a trusted third-party advisory bot
# found a real defect on a PR pr-review had already APPROVED. That is a false
# NEGATIVE — a miss.
#
# No LLM is involved here (matching reviewer_report.sh's stated design): every
# figure is computed with jq from GitHub review data. The functions are PURE —
# they read JSON and write JSON/Markdown, doing no network I/O — so they are
# unit-tested in tests/test_pr_review_miss_rate.bats. The collection wrapper lives
# in scripts/reviewer_report.sh, which already fetches each PR's reviews, review
# threads (with resolution state) and comments in one GraphQL round-trip per repo.
#
# ── The metric ───────────────────────────────────────────────────────────────
#   missed_findings   — threads a trusted advisory bot opened AFTER pr-review's
#                       approving review, that were resolved as ACCEPTED (a fix
#                       landed / the disposition accepted it) rather than refuted.
#   caught_findings   — findings pr-review raised itself that were accepted.
#   partial_evidence_approvals
#                     — approvals issued via the advisory-gate timeout fallback,
#                       i.e. before all registered bots reported (recorded on the
#                       PR by scripts/lib/advisory-review-gate.sh as a marker).
#
# ── The crux: accepted vs refuted (documented rule) ──────────────────────────
# Roughly 3 of 4 advisory-bot findings are false positives correctly refuted, so a
# naive "a bot opened a thread → pr-review missed it" counter would be dominated by
# noise and would push the agent toward MORE false positives. We therefore classify
# each finding by the disposition recorded in its resolving reply and count ONLY
# accepted ones. The rule (pr_review_classify_disposition):
#   1. An explicit machine marker wins:  <!-- disposition: accepted|refuted -->
#      (last one on the thread takes effect).
#   2. Otherwise keyword heuristics over the NON-BOT reply comments:
#        - accepted signals: "good catch", "fixed", "addressed", "accepted", …
#        - refuted signals:  "false positive", "not applicable", "by design", …
#   3. If neither (or both) fire → AMBIGUOUS.
# A finding counts as a miss ONLY when the disposition is "accepted" AND the thread
# is resolved. Anything AMBIGUOUS counts as NOT a miss — we deliberately under-count
# rather than manufacture misses from noise.

# ── Defaults ─────────────────────────────────────────────────────────────────
# Trusted advisory bots whose accepted findings count. Kept as a JSON array string
# so the pure functions need no external registry; reviewer_report.sh passes its
# own REVIEWER_BOTS list in, which is the advisory-review-gate single source.
: "${PR_REVIEW_DEFAULT_BOTS:=[\"gemini-code-assist\",\"copilot-pull-request-reviewer\",\"sonarqubecloud\",\"chatgpt-codex-connector\",\"coderabbitai\",\"qodo-code-review\",\"codeant-ai\",\"graphite-app\",\"cubic-dev-ai\"]}"
# The login pr-review acts as (see AGENTS.md "Agent identity"): its own findings
# are threads it opens, and are the source of caught_findings.
: "${PR_REVIEW_APPROVER:=donpetry-bot}"

# pr-review's approving-review marker (see scripts/lib/review-cycle.sh) and the
# advisory-gate partial-evidence marker (see scripts/lib/advisory-review-gate.sh).
PR_REVIEW_APPROVAL_RE='<!-- pr-review-agent v1 sha=[a-f0-9]+[[:space:]]+decision=approved'
PR_REVIEW_PARTIAL_RE='<!-- pr-review-agent partial-evidence v1'

# ── Shared jq definitions ────────────────────────────────────────────────────
# Prepended to every jq program below so classification never drifts between the
# standalone classifier and the aggregate collection pass.
# shellcheck disable=SC2016  # single-quoted jq program: $-vars are jq bindings
_MISS_JQ_DEFS='
  def _is_bot($login; $bots):
    ($login != null)
    and (($bots | map(ascii_downcase) | index($login | ascii_downcase)) != null);

  def _disp_refuted_re:
    "false[ -]?positive|not applicable|\\bn/?a\\b|won'"'"'?t ?fix|wontfix|disagree|incorrect|already (covered|handled|tested|guarded|present)|refut|not a (real )?(issue|bug|problem|defect)|as (designed|intended)|by design|out of scope";
  def _disp_accepted_re:
    "good catch|nice catch|great catch|fixed|will fix|addressed|resolved in|accepted|valid (point|concern|finding|issue)|patched|done in";

  # _disposition(thread; bots) -> "accepted" | "refuted" | "ambiguous"
  def _disposition($thread; $bots):
    ($thread.comments.nodes // []) as $cs
    | ([ $cs[] | (.bodyText // "")
         | scan("<!--\\s*disposition:\\s*(accepted|refuted)\\s*-->"; "i") | .[0] ]
       | last) as $explicit
    | if $explicit != null then ($explicit | ascii_downcase)
      else
        ([ $cs[] | select(_is_bot(.author.login; $bots) | not) | (.bodyText // "") ]
         | join("\n") | ascii_downcase) as $replies
        | ($replies | test(_disp_refuted_re))  as $ref
        | ($replies | test(_disp_accepted_re)) as $acc
        | if ($acc and ($ref | not)) then "accepted"
          elif ($ref and ($acc | not)) then "refuted"
          else "ambiguous" end
      end;

  # _threads(pr; bots; approver) -> array of normalized finding threads.
  def _threads($pr; $bots; $approver):
    [ ($pr.reviewThreads.nodes // [])[]
      | . as $t
      | ($t.comments.nodes // []) as $cs
      | select(($cs | length) > 0)
      | ($cs[0].author.login // "" | ascii_downcase) as $opener
      | { opener: $opener,
          opened_at: $cs[0].createdAt,
          resolved: ($t.isResolved // false),
          disp: _disposition($t; $bots),
          bot_opened: _is_bot($cs[0].author.login; $bots),
          pr_opened: ($opener == ($approver | ascii_downcase)) } ];

  # _first_approval_at(pr; approval_re; approver) -> earliest approving-review timestamp or null.
  def _first_approval_at($pr; $approval_re; $approver):
    [ ($pr.reviews.nodes // [])[]
      | select((.state // "") == "APPROVED")
      | select((.author.login // "" | ascii_downcase) == ($approver | ascii_downcase))
      | select((.bodyText // "") | test($approval_re)) | .submittedAt ] | min;

  # _missed(pr; bots; approver; approval_re) -> accepted bot findings opened after approval.
  def _missed($pr; $bots; $approver; $approval_re):
    _first_approval_at($pr; $approval_re; $approver) as $appr
    | if $appr == null then []
      else [ _threads($pr; $bots; $approver)[]
             | select(.bot_opened and .resolved and (.disp == "accepted") and (.opened_at > $appr)) ]
      end;
'

# pr_review_classify_disposition <thread_json> [<bots_json>]
#   Prints accepted | refuted | ambiguous for one reviewThread node.
pr_review_classify_disposition() {
  local thread="${1:-}" bots="${2:-$PR_REVIEW_DEFAULT_BOTS}"
  jq -rn --argjson t "$thread" --argjson bots "$bots" \
    "$_MISS_JQ_DEFS"' _disposition($t; $bots)' 2>/dev/null || echo ambiguous
}

# pr_review_pr_metrics <pr_node_json> [<bots_json>] [<approver>] [<repo>]
#   Emits one compact {kind:"miss_pr", ...} record for a single PR node.
pr_review_pr_metrics() {
  local pr="${1:-}" bots="${2:-$PR_REVIEW_DEFAULT_BOTS}" approver="${3:-$PR_REVIEW_APPROVER}" repo="${4:-}"
  jq -cn \
    --argjson pr "$pr" --argjson bots "$bots" \
    --arg approver "$approver" --arg repo "$repo" \
    --arg approval_re "$PR_REVIEW_APPROVAL_RE" --arg partial_re "$PR_REVIEW_PARTIAL_RE" \
    "$_MISS_JQ_DEFS"'
    ($pr | _first_approval_at(.; $approval_re; $approver)) as $appr
    | ($appr != null) as $approved
    | ([ ($pr.reviews.nodes // [])[]
         | select((.state // "") == "APPROVED")
         | select((.author.login // "" | ascii_downcase) == ($approver | ascii_downcase))
         | select((.bodyText // "") | test($approval_re))
         | ((.bodyText // "") | scan("sha=([a-f0-9]+)"; "i") | .[0]) ] | unique) as $appr_shas
    | ([ (($pr.reviews.nodes // []) + ($pr.comments.nodes // []))[]
         | select((.author.login // "" | ascii_downcase) == ($approver | ascii_downcase))
         | (.bodyText // "") | select(test($partial_re))
         | (scan("sha=([a-f0-9]+)"; "i") | .[0])
         | select(. as $s | $appr_shas | index($s)) ] | unique | length) as $partial
    | _missed($pr; $bots; $approver; $approval_re) as $missed
    | ([ _threads($pr; $bots; $approver)[]
         | select(.pr_opened and .resolved and (.disp == "accepted")) ]) as $caught
    | ($missed | group_by(.opener) | map({key: .[0].opener, value: length}) | from_entries) as $per_bot
    | { kind: "miss_pr", repo: $repo, pr: ($pr.url // ""),
        approved: $approved,
        missed_findings: ($missed | length),
        caught_findings: ($caught | length),
        partial_evidence_approvals: $partial,
        per_bot: $per_bot }' 2>/dev/null \
    || printf '{"kind":"miss_pr","repo":"%s","pr":"","approved":false,"missed_findings":0,"caught_findings":0,"partial_evidence_approvals":0,"per_bot":{}}\n' "$repo"
}

# pr_review_invalidatable_approvals <pr_node_json> [<bots_json>] [<approver>]
#   Prints the approving-review head SHA(s) that should be DISMISSED because a
#   trusted advisory bot opened an ACCEPTED finding after the approval at the same
#   head — the standing approval is no longer evidence of defect-freedom (AC6).
#   One SHA per line; empty when nothing needs invalidating.
pr_review_invalidatable_approvals() {
  local pr="${1:-}" bots="${2:-$PR_REVIEW_DEFAULT_BOTS}" approver="${3:-$PR_REVIEW_APPROVER}"
  jq -rn \
    --argjson pr "$pr" --argjson bots "$bots" --arg approver "$approver" \
    --arg approval_re "$PR_REVIEW_APPROVAL_RE" \
    "$_MISS_JQ_DEFS"'
    _missed($pr; $bots; $approver; $approval_re) as $missed
    | [ ($pr.reviews.nodes // [])[]
        | select((.state // "") == "APPROVED")
        | select((.author.login // "" | ascii_downcase) == ($approver | ascii_downcase))
        | select((.bodyText // "") | test($approval_re))
        | . as $rev
        # Only dismiss an approval that was STANDING when an accepted finding
        # arrived, i.e. a finding opened after this approval was submitted. A
        # fresh re-approval submitted after the finding already accounts for it,
        # so it must not be swept up (thread data carries no head SHA to match).
        | select([ $missed[] | select(.opened_at > ($rev.submittedAt // "")) ] | length > 0)
        | ((.bodyText // "") | scan("sha=([a-f0-9]+)"; "i") | .[0]) ]
      | unique | .[]' 2>/dev/null || true
}

# pr_review_aggregate_misses  (stdin: miss_pr JSONL; stdout: aggregate JSON)
#   Overall totals plus per-reviewer missed-finding attribution and the miss rate
#   (missed / (missed + caught)) as an integer percent.
pr_review_aggregate_misses() {
  jq -s '
    [ .[] | select(.kind == "miss_pr") ] as $r
    | ($r | map(.missed_findings // 0) | add // 0) as $m
    | ($r | map(.caught_findings // 0) | add // 0) as $c
    | ($r | map(.partial_evidence_approvals // 0) | add // 0) as $p
    | ($r | map(select(.approved)) | length) as $approved_prs
    | (reduce ($r[].per_bot // {} | to_entries[]) as $e ({}; .[$e.key] = ((.[$e.key] // 0) + $e.value))) as $per_bot
    | { prs_approved: $approved_prs,
        missed_findings: $m, caught_findings: $c, partial_evidence_approvals: $p,
        miss_rate_pct: (if ($m + $c) == 0 then 0 else (($m / ($m + $c)) * 100 | floor) end),
        per_bot: $per_bot }
  ' 2>/dev/null || echo '{"prs_approved":0,"missed_findings":0,"caught_findings":0,"partial_evidence_approvals":0,"miss_rate_pct":0,"per_bot":{}}'
}

# pr_review_render_miss_section <jsonl_dir>
#   PURE Markdown renderer for the reviewer scorecard's miss-rate section. Reads
#   the miss_pr records emitted during collection and prints the overall miss rate,
#   the partial-evidence count, and a per-reviewer "found first" table.
pr_review_render_miss_section() {
  local dir="$1"
  local files=("$dir"/*.jsonl) snap
  if [[ ! -e "${files[0]}" ]]; then
    snap='{"prs_approved":0,"missed_findings":0,"caught_findings":0,"partial_evidence_approvals":0,"miss_rate_pct":0,"per_bot":{}}'
  else
    snap="$(cat "${files[@]}" 2>/dev/null | pr_review_aggregate_misses)"
  fi

  local missed caught partial rate approved_prs
  missed="$(jq -r '.missed_findings' <<<"$snap")"
  caught="$(jq -r '.caught_findings' <<<"$snap")"
  partial="$(jq -r '.partial_evidence_approvals' <<<"$snap")"
  rate="$(jq -r '.miss_rate_pct' <<<"$snap")"
  approved_prs="$(jq -r '.prs_approved' <<<"$snap")"

  printf '## pr-review miss rate\n\n'
  printf 'The false-NEGATIVE signal (#1596): accepted defects a trusted advisory bot found on a PR '
  printf 'pr-review had already **approved**. Deterministic — computed with `jq` from review data, no LLM. '
  printf 'Only findings resolved as **accepted** count; refuted false positives and ambiguous dispositions do not.\n\n'
  printf -- '- **Miss rate:** %s%% — %s missed vs %s caught (accepted findings; miss = found first by a bot after approval).\n' \
    "$rate" "$missed" "$caught"
  printf -- '- **Approvals on partial evidence:** %s — pr-review approved via the advisory-gate timeout fallback (before all bots reported).\n' \
    "$partial"
  printf -- '- **Approved PRs in window:** %s.\n\n' "$approved_prs"

  # Per-reviewer: which bot repeatedly finds what pr-review misses (a prompt gap).
  local bot_rows
  bot_rows="$(jq -r '.per_bot | to_entries | sort_by(-.value)[] | "\(.key)\t\(.value)"' <<<"$snap" 2>/dev/null)"
  if [[ -n "$bot_rows" ]]; then
    printf '### Misses by reviewer (who found it first)\n\n'
    printf '| Reviewer | Accepted misses caught first |\n|---|---:|\n'
    local login count label
    while IFS=$'\t' read -r login count; do
      [[ -n "$login" ]] || continue
      if declare -p REVIEWER_LABELS >/dev/null 2>&1; then
        label="${REVIEWER_LABELS[$login]:-$login}"
      else
        label="$login"
      fi
      printf '| %s | %s |\n' "$label" "$count"
    done <<<"$bot_rows"
    printf '\n'
    printf -- '_A class of defect one reviewer repeatedly finds first is directly actionable — a prompt gap for pr-review._\n\n'
  fi
}

# ── Collection-pass jq (used by scripts/reviewer_report.sh) ───────────────────
# The reviewer_report collection worker prepends _MISS_JQ_DEFS and applies this
# filter to each in-window PR node, emitting one miss_pr record per PR. Exposed as
# a filter string (no leading `.`) so it composes after `select(...) |`, mirroring
# the #1411 agent_comment additive pass.
# shellcheck disable=SC2016,SC2034  # jq literal ($-refs are jq vars); consumed by reviewer_report.sh via env
PR_REVIEW_MISS_COLLECT_JQ='
  . as $pr
  | ($pr | _first_approval_at(.; $approval_re; $approver)) as $appr
  | ($appr != null) as $approved
  | ([ ($pr.reviews.nodes // [])[]
       | select((.state // "") == "APPROVED")
       | select((.author.login // "" | ascii_downcase) == ($approver | ascii_downcase))
       | select((.bodyText // "") | test($approval_re))
       | ((.bodyText // "") | scan("sha=([a-f0-9]+)"; "i") | .[0]) ] | unique) as $appr_shas
  | ([ (($pr.reviews.nodes // []) + ($pr.comments.nodes // []))[]
       | select((.author.login // "" | ascii_downcase) == ($approver | ascii_downcase))
       | (.bodyText // "") | select(test($partial_re))
       | (scan("sha=([a-f0-9]+)"; "i") | .[0])
       | select(. as $s | $appr_shas | index($s)) ] | unique | length) as $partial
  | _missed($pr; $bots; $approver; $approval_re) as $missed
  | ([ _threads($pr; $bots; $approver)[]
       | select(.pr_opened and .resolved and (.disp == "accepted")) ]) as $caught
  | ($missed | group_by(.opener) | map({key: .[0].opener, value: length}) | from_entries) as $per_bot
  | { kind: "miss_pr", repo: $repo, pr: ($pr.url // ""),
      approved: $approved,
      missed_findings: ($missed | length),
      caught_findings: ($caught | length),
      partial_evidence_approvals: $partial,
      per_bot: $per_bot }
'
