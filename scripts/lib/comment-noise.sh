#!/usr/bin/env bash
# comment-noise.sh — the no-action agent-comment NOISE classifier (issue #1411,
# epic #1402). Net-new measurement: reviewer_report.sh explicitly declares comment
# usefulness / false-positive rate out of scope, so this is the first place the org
# measures how much of its own automation chatter asks nothing of a human.
#
# It is a set of PURE functions with NO network I/O and NO top-level side effects,
# so it can be sourced by both the report (reviewer_report.sh) and its unit tests
# (tests/comment_noise.bats). It does NOT call `set -euo pipefail` — sourced-library
# exception: adding it would change the caller's shell options (mirroring the
# approved convention in persona-runner.sh; see AGENTS.md Bash guideline note).
#
# What it classifies
#   An *agent comment* is any PR comment/review whose body carries one of OUR
#   automation markers (the denominator of the noise metric). Third-party reviewer
#   bots (Copilot, CodeRabbit, …) are NOT in scope here — they are measured by
#   reviewer_report.sh's scorecard and emit no such marker.
#
#   A *no-action* comment is an agent comment that asks nothing of a human: it
#   reported no change was needed, made no change, or was a clean approval. Every
#   other agent comment is *actionable* (it applied a fix, escalated a finding, or
#   flagged something for human attention).
#
# Decision logic (single source of truth)
#   cn_marker_pattern     — ERE identifying an agent comment (the denominator).
#   cn_no_action_pattern  — ERE identifying a no-action body/marker.
#   Both are shared verbatim by the bash classifiers below AND by the jq
#   pre-classifier (CN_AGENT_COMMENT_JQ) the report applies during collection, so
#   the metric can never be computed two different ways.
#
# Public API
#   cn_is_agent_comment <body>   — exit 0 when body carries an automation marker.
#   cn_is_no_action <body>       — exit 0 when body matches a no-action shape.
#   cn_classify <body>           — prints non-agent | no-action | actionable.
#   CN_AGENT_COMMENT_JQ          — jq program: one GraphQL PR node -> a stream of
#                                  {kind:"agent_comment", repo, pr, no_action}
#                                  records (needs --arg repo/mark/noact).
#   cn_render_noise_section <jsonl_dir> — pure markdown renderer over those records.

# ---------------------------------------------------------------------------
# Decision patterns — the ONE place the metric's boundaries are defined.
# ---------------------------------------------------------------------------

# cn_marker_pattern — matches any body authored by our automation. The known
# markers are: pr-review agent verdicts (<!-- pr-review-agent … -->), every
# dev-lead comment family (fix-reviews / fix-ci / noop-guard / issue / rate-limit,
# all prefixed <!-- dev-lead… -->), persona advisories (<!-- persona:… -->), and
# the dependency advisory (<!-- dependency-advisory -->).
cn_marker_pattern() {
  printf '%s' '^<!-- (pr-review-agent|dev-lead|persona:|dependency-advisory)'
}

# cn_no_action_pattern — matches a comment that asks nothing of a human. Two kinds
# of signal, both stable and grep/jq-identical (literal phrases + marker fields):
#   * Known no-action body phrases — anchored so a reviewer quoting them mid-sentence
#     does NOT produce a false positive (unanchored substrings would match a comment
#     like '<!-- dev-lead --> The engine says "No actionable items found." — re-run'):
#       ^No actionable items found\.      (post_no_changes, dev-lead-fix-reviews — phrase starts its own line)
#       ^Engine ran but made no changes\. (dev-lead-fix-ci / on-mention no-changes  — same)
#       No action required\.$            (dependency advisory, all-LOW verdict — phrase ends the line)
#   * Marker attributes — anchored inside the leading HTML comment so a quoted
#     attribute in body text does not match (e.g. '<!-- dev-lead --> decision=approved but…'):
#       <!-- [^>]*status=no-changes       (dev-lead fix-ci / fix-reviews)
#       <!-- [^>]*decision=approved       (pr-review approval — in CN_AGENT_COMMENT_JQ only the FIRST
#                                          approval per head SHA is actionable; repeats are no-action)
cn_no_action_pattern() {
  printf '%s' '^No actionable items found\.|^Engine ran but made no changes\.|No action required\.$|<!-- [^>]*status=no-changes|<!-- [^>]*decision=approved|<!-- pr-review-agent superseded'
}

# ---------------------------------------------------------------------------
# Pure bash classifiers (unit-tested against every known shape).
# ---------------------------------------------------------------------------

# cn_is_agent_comment <body> — exit 0 when the body carries an automation marker.
cn_is_agent_comment() {
  printf '%s' "${1:-}" | grep -Eq "$(cn_marker_pattern)"
}

# cn_is_no_action <body> — exit 0 when the body matches a no-action shape.
cn_is_no_action() {
  printf '%s' "${1:-}" | grep -Eq "$(cn_no_action_pattern)"
}

# cn_classify <body> — prints exactly one of: non-agent | no-action | actionable.
# A body with no automation marker is "non-agent" and is never counted as noise.
cn_classify() {
  local body="${1:-}"
  if ! cn_is_agent_comment "$body"; then
    printf 'non-agent'
    return 0
  fi
  if cn_is_no_action "$body"; then
    printf 'no-action'
  else
    printf 'actionable'
  fi
}

# ---------------------------------------------------------------------------
# Shared jq pre-classifier — the report's collection path applies THIS program
# (not the bash functions, for bulk speed) but keyed on the SAME patterns, passed
# in as --arg mark / --arg noact, so collection and tests agree by construction.
# ---------------------------------------------------------------------------
# Input: one GraphQL PR node (same shape reviewer_report.sh collects: .url plus
#   .reviews.nodes[], .comments.nodes[], .reviewThreads.nodes[].comments.nodes[],
#   each carrying .bodyText and submittedAt/createdAt). Output: one agent_comment
#   record per marker-bearing body whose own timestamp is >= $cutoff, pre-flagged
#   no_action. Uses test($noact; "m") for multiline ^ / $ anchors. Approvals with
#   decision=approved: the FIRST occurrence per head SHA within the PR is marked
#   no_action:false (it unblocks merge); subsequent repeats are no_action:true.
#   Args: --arg repo, --arg mark, --arg noact, --arg cutoff.
# shellcheck disable=SC2034  # consumed by callers via jq, not executed here
CN_AGENT_COMMENT_JQ='
  . as $pr
  | ( [ (.reviews?.nodes // [])[]?      | { body: .bodyText?, ts: (.submittedAt? // .createdAt?) } ]
    + [ (.comments?.nodes // [])[]?     | { body: .bodyText?, ts: .createdAt? } ]
    + [ (.reviewThreads?.nodes // [])[]? | (.comments?.nodes // [])[]? | { body: .bodyText?, ts: .createdAt? } ] )
  | map(select(.body != null and .ts != null and .ts >= $cutoff and (.body | test($mark))))
  | sort_by(.ts)
  | reduce .[] as $c (
      { shas: [], out: [] };
      ( $c.body | test($noact; "m") ) as $na |
      if $na and ($c.body | test("<!-- [^>]*decision=approved")) then
        ( $c.body | (capture("sha=(?<s>[0-9a-f]+)")? // {s:null}) | .s ) as $sha |
        if $sha != null and ([ .shas[] | select(. == $sha) ] | length) > 0 then
          .out += [{ kind: "agent_comment", repo: $repo, pr: ($pr.url // "" | tostring), no_action: true }]
        else
          .shas += (if $sha != null then [$sha] else [] end) |
          .out += [{ kind: "agent_comment", repo: $repo, pr: ($pr.url // "" | tostring), no_action: false }]
        end
      else
        .out += [{ kind: "agent_comment", repo: $repo, pr: ($pr.url // "" | tostring), no_action: $na }]
      end
    )
  | .out[]
'

# ---------------------------------------------------------------------------
# Pure markdown renderer over {kind:"agent_comment", pr, no_action} JSONL.
# ---------------------------------------------------------------------------

# _cn_pct <numerator> <denominator> — integer percent, "n/a" when denom is 0.
_cn_pct() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { if (b <= 0) print "n/a"; else printf "%d%%", (a / b * 100) + 0.5 }'
}

# _cn_ratio <numerator> <denominator> — 2-decimal ratio, "0.00" when denom is 0.
_cn_ratio() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { if (b <= 0) print "0.00"; else printf "%.2f", a / b }'
}

# cn_render_noise_section <jsonl_dir> — read every *.jsonl in the dir, keep only
# agent_comment records, and render the "Agent comment noise" markdown section.
# PURE: no network. A dir with no agent comments renders a clean zero-state.
cn_render_noise_section() {
  local dir="${1:-}"
  local total=0 noact=0 prs=0 active_prs=0 affected_prs=0
  if [[ -n "$dir" ]] && [[ -d "$dir" ]]; then
    local files=("$dir"/*.jsonl)
    if [[ -e "${files[0]}" ]]; then
      local counts
      # One jq pass: agent comment totals, distinct PR sets, and active-PR denominator.
      counts="$(jq -rs '
        map(select(.kind == "agent_comment")) as $ac
        | map(select(.kind == "pr")) as $all_prs
        | [ ($ac | length),
            ($ac | map(select(.no_action)) | length),
            ($ac | map(.pr) | unique | length),
            ($all_prs | map(.pr) | unique | length),
            ($ac | map(select(.no_action)) | map(.pr) | unique | length) ]
        | @tsv' "${files[@]}" 2>/dev/null || printf '0\t0\t0\t0\t0')"
      IFS=$'\t' read -r total noact prs active_prs affected_prs <<<"$counts"
    fi
  fi
  total="${total:-0}"; noact="${noact:-0}"; prs="${prs:-0}"
  active_prs="${active_prs:-0}"; affected_prs="${affected_prs:-0}"

  printf '## Agent comment noise\n\n'
  printf -- '- **Agent comments:** %s\n' "$total"
  printf -- '- **No-action comments:** %s (%s of agent comments)\n' "$noact" "$(_cn_pct "$noact" "$total")"
  printf -- '- **Active PRs (window):** %s\n' "$active_prs"
  printf -- '- **PRs with agent comments:** %s\n' "$prs"
  printf -- '- **Affected PRs (≥1 no-action comment):** %s\n' "$affected_prs"
  printf -- '- **No-action comments per PR:** %s\n\n' "$(_cn_ratio "$noact" "$prs")"
  printf -- '- **Noise** = agent comments that ask nothing of a human — a reported no-change, a no-op engine run, or a clean/repeat approval. '
  printf 'Actionable agent comments (applied fixes, escalated findings, human-attention flags) are excluded. '
  printf 'Classification is deterministic (`scripts/lib/comment-noise.sh`), computed from the automation markers each comment already carries — no LLM.\n\n'
}
