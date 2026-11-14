#!/usr/bin/env bash
# reviewer_report.sh — org-wide Third-Party Reviewer Scorecard.
#
# Measures the agentic third-party code reviewers (GitHub Apps) that participate
# in PR review across the org and renders a DETERMINISTIC weekly Markdown report.
# No LLM is
# used anywhere in this pipeline: every metric is computed with jq/awk/bash from
# GitHub's own review data. (An LLM narrative is a deliberately separate, human-
# triggered add-on — not part of this script.)
#
# Why org-wide: the reviewer bots run as GitHub Apps installed at the org level
# and review PRs in every product repo, so a single-repo scan sees only a sliver
# of their activity. We sweep every non-archived repo, matching token_report.sh.
#
# Data source: ONE batched GraphQL query per repo (paginated over PRs, newest
# first) returns each PR's reviews, review threads (with resolution state and
# reactions), and issue comments in a single round-trip — far fewer calls than
# per-PR REST. Bot identity comes from the shared advisory-review-gate registry.
# Every bot message gets one class — finding / clean / refused / skipped / status /
# unclassified (#2504) — from the bot's rows in the scorecard-only sidecar
# scripts/lib/reviewer-message-classes.tsv first, and the gate's shared rate-limit
# pattern (the "refused" fallback) second. Only finding / clean count as a review.
#
# Layout (mirrors token_report.sh):
#   * The render_* / aggregate helpers are PURE — they read a directory of
#     normalized JSONL and write Markdown to stdout. Unit-tested in
#     tests/reviewer_report.bats (no network).
#   * main() does the network I/O: repo discovery, GraphQL collection, and the
#     week-over-week snapshot fetch/publish.
#
# Usage:
#   ORG=combsmith LOOKBACK_DAYS=7 GH_TOKEN=<pat> bash scripts/reviewer_report.sh > report.md
#
# Environment:
#   ORG                 — GitHub org to scan (default: combsmith)
#   LOOKBACK_DAYS       — rolling window of PR activity to include (default: 7)
#   GH_TOKEN            — PAT with repo read across the org (PRs + reviews)
#   REVIEWER_REPORT_OUT — optional path; when set, the report is ALSO written there.
#   REVIEWER_SNAPSHOT_OUT — optional path; when set, the current week's per-bot
#                         headline metrics are written there as JSON (uploaded by
#                         the workflow as an artifact for next week's WoW diff).
#   REVIEWER_PREV_SNAPSHOT — optional path to last week's snapshot JSON; when set
#                         (and readable), the report shows week-over-week deltas.
#                         main() fetches this automatically via the GitHub API when
#                         SNAPSHOT_REPO is set; pass it directly in tests.
#   SNAPSHOT_REPO       — repo holding the snapshot artifacts (default: this repo,
#                         combsmith/.github-private).
#   GH_OP_TIMEOUT       — per-gh-call timeout in seconds (default 60). 0 disables.
#   COLLECT_CONCURRENCY — max concurrent per-repo GraphQL sweeps (default 8).
#   MAX_PR_PAGES        — safety cap on GraphQL PR pages per repo (default 20 ×25 PRs).

set -euo pipefail

ORG="${ORG:-combsmith}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"
SNAPSHOT_REPO="${SNAPSHOT_REPO:-combsmith/.github-private}"

# ---------------------------------------------------------------------------
# Reviewer registry — reuse the advisory-review-gate single source of truth so
# bot logins and rate-limit detection never drift from the approval gate.
# ---------------------------------------------------------------------------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_here/lib/advisory-review-gate.sh" ]]; then
  # shellcheck source=scripts/lib/advisory-review-gate.sh
  source "$_here/lib/advisory-review-gate.sh"
fi

# No-action agent-comment noise classifier (#1411). Provides CN_AGENT_COMMENT_JQ
# (the shared jq pre-classifier applied during collection) and the pure
# cn_render_noise_section renderer. Derive its two decision patterns once so the
# collection workers and the renderer agree by construction.
if [[ -f "$_here/lib/comment-noise.sh" ]]; then
  # shellcheck source=scripts/lib/comment-noise.sh
  source "$_here/lib/comment-noise.sh"
  CN_MARKER_RE="$(cn_marker_pattern)"
  CN_NOACTION_RE="$(cn_no_action_pattern)"
fi

# Deterministic false-NEGATIVE metric (#1596): accepted findings a trusted advisory
# bot raised on a PR pr-review had already approved. Provides _MISS_JQ_DEFS +
# PR_REVIEW_MISS_COLLECT_JQ (the additive collection pass) and the pure
# pr_review_render_miss_section renderer. Reuses REVIEWER_BOTS as its trusted set.
if [[ -f "$_here/lib/pr-review-miss-rate.sh" ]]; then
  # shellcheck source=scripts/lib/pr-review-miss-rate.sh
  source "$_here/lib/pr-review-miss-rate.sh"
fi

# The reviewers this scorecard tracks. RATE_LIMIT_NOTICE_BOTS (from the gate) is
# exactly our target set — the gate bots PLUS coderabbitai — so we reuse it as
# the canonical login list rather than re-declaring it (#drift-guard). If the
# library is unavailable (e.g. a stripped test env), fall back to a literal list.
if declare -p RATE_LIMIT_NOTICE_BOTS >/dev/null 2>&1 && [[ "${#RATE_LIMIT_NOTICE_BOTS[@]}" -gt 0 ]]; then
  REVIEWER_BOTS=("${RATE_LIMIT_NOTICE_BOTS[@]}")
else
  REVIEWER_BOTS=(gemini-code-assist copilot-pull-request-reviewer sonarqubecloud chatgpt-codex-connector coderabbitai qodo-code-review codeant-ai graphite-app cubic-dev-ai)
fi

# Human-facing display names, keyed by GraphQL login (no "[bot]" suffix).
# -g (global): this file may be sourced from within a function (e.g. a bats
# setup()), where a bare `declare -A` would create a function-local that vanishes
# before the render loop runs — leaving the name to be misparsed as an indexed
# array (arithmetic on the login key) under `set -u`.
declare -gA REVIEWER_LABELS=(
  [copilot-pull-request-reviewer]="GitHub Copilot"
  [gemini-code-assist]="Gemini Code Assist"
  [chatgpt-codex-connector]="Codex"
  [coderabbitai]="CodeRabbit"
  [sonarqubecloud]="SonarCloud"
  [qodo-code-review]="Qodo Merge"
  [codeant-ai]="CodeAnt"
  [graphite-app]="Graphite"
  [cubic-dev-ai]="cubic"
)

# Rate-limit / out-of-quota body pattern — reuse the gate's if present.
if declare -F _advisory_rate_limit_pattern >/dev/null 2>&1; then
  RATE_LIMIT_RE="$(_advisory_rate_limit_pattern)"
else
  RATE_LIMIT_RE='usage limit|rate[-_ ]?limit|too many requests|quota (exceeded|reached|exhausted)|out of (quota|credits|tokens|requests)|limit (reached|exceeded|exhausted)|(reached|exceeded|hit) (the |your )?(usage |rate |daily |monthly )?limit|used up its prepaid credits|Qodo.{0,40}(monthly|usage|PR|review) limit|CodeAnt.{0,40}(monthly|trial|usage) limit'
fi

# Author-scoped cubic rate-limit clause — reuse the gate's if present, else mirror
# it. Matched ONLY against cubic's own submissions (author == cubic-dev-ai) in
# _NORMALIZE_JQ below, so a genuine finding by another reviewer that merely mentions
# cubic's trial is not miscounted as a cubic/other-bot refusal (#1903). The mirror
# is kept in sync with the gate by tests/dev-lead/unit/test_advisory_review_gate.bats.
if declare -F _advisory_cubic_rate_limit_pattern >/dev/null 2>&1; then
  CUBIC_RATE_LIMIT_RE="$(_advisory_cubic_rate_limit_pattern)"
else
  CUBIC_RATE_LIMIT_RE='cubic.{0,40}(trial|free trial) (ended|expired)'
fi

# Check-run reporters (#1908): logins that deliver a review as a check run rather
# than (or in addition to) a PR review — Graphite's clean pass posts ONLY a
# "Graphite / AI Reviews" check run and no PR review, so it must be fetched
# separately or every clean pass miscounts as "No response". Data-driven from
# reviewer-sources.tsv (check_run_name column), never a hard-coded login here.
# Map: login → exact check-run name. Empty when the registry is absent.
declare -gA REVIEWER_CHECK_RUN_NAMES=()
if declare -F reviewer_sources_check_run_reporters >/dev/null 2>&1; then
  while IFS=$'\t' read -r _crr_login _crr_name || [[ -n "$_crr_login" ]]; do
    [[ -n "$_crr_login" ]] && REVIEWER_CHECK_RUN_NAMES["$_crr_login"]="$_crr_name"
  done < <(reviewer_sources_check_run_reporters 2>/dev/null || true)
  unset _crr_login _crr_name
fi

# cubic-dev-ai login — reuse the gate's if present, else mirror it. Used in the
# refusal predicate of _NORMALIZE_JQ to scope the cubic clause to cubic's own
# submissions only (#1903). The mirror is kept in sync with the gate by tests.
if declare -F _advisory_cubic_login >/dev/null 2>&1; then
  CUBIC_LOGIN="$(_advisory_cubic_login)"
else
  CUBIC_LOGIN='cubic-dev-ai'
fi

# Per-bot message-class patterns (#2504) from the scorecard-only sidecar
# scripts/lib/reviewer-message-classes.tsv, as a JSON map
#   { "<login>": [ {class, kind, pattern}, ... in file order ] }.
# It is spliced into _NORMALIZE_JQ as a literal (JSON is valid jq), so the worker
# subshells and the unit tests need no extra --argjson. A row whose regex does not
# compile is dropped here rather than breaking every PR (the bats suite fails on it).
# `{}` when the loader is absent: every message then falls through to the shared
# refusal fallback and the structural defaults.
REVIEWER_MESSAGE_CLASS_JSON='{}'
if declare -F reviewer_sources_message_class_patterns >/dev/null 2>&1; then
  _mc_rows="$(reviewer_sources_message_class_patterns)" \
    || echo "WARN: reviewer-message-classes.tsv has invalid rows — they are ignored (see above)" >&2
  if [[ -n "$_mc_rows" ]]; then
    REVIEWER_MESSAGE_CLASS_JSON="$(jq -Rsc '
      split("\n") | map(select(length > 0) | split("\t")
        | {login: (.[0] | ascii_downcase), class: .[1], kind: .[2], pattern: (.[3:] | join("\t"))})
      | map(select(.pattern != "" and .login != ""))
      | map(select(. as $r | try ("" | test($r.pattern; "i") | true) catch false))
      | reduce .[] as $r ({}; .[$r.login] += [{class: $r.class, kind: $r.kind, pattern: $r.pattern}])
    ' <<<"$_mc_rows" 2>/dev/null)" || REVIEWER_MESSAGE_CLASS_JSON='{}'
    [[ -n "$REVIEWER_MESSAGE_CLASS_JSON" ]] || REVIEWER_MESSAGE_CLASS_JSON='{}'
  fi
  unset _mc_rows
fi

# Expected-off bot × repo cells (#2506) from the same sidecar, as a JSON array
#   [ {login, repo}, ... ]
# where repo is "owner/name" or a bare "name". An off cell renders "off (by design)"
# in the coverage matrix and never raises an outage alert. `[]` when the loader is
# absent; a malformed row is dropped by the loader (and the bats suite fails on it).
REVIEWER_EXPECTED_OFF_JSON='[]'
if declare -F reviewer_sources_expected_off_cells >/dev/null 2>&1; then
  _off_rows="$(reviewer_sources_expected_off_cells)" \
    || echo "WARN: reviewer-message-classes.tsv has invalid expected-off rows — they are ignored (see above)" >&2
  if [[ -n "$_off_rows" ]]; then
    REVIEWER_EXPECTED_OFF_JSON="$(jq -Rsc '
      split("\n") | map(select(length > 0) | split("\t")
        | {login: (.[0] | ascii_downcase), repo: (.[1] // "")} | select(.repo != ""))
    ' <<<"$_off_rows" 2>/dev/null)" || REVIEWER_EXPECTED_OFF_JSON='[]'
    [[ -n "$REVIEWER_EXPECTED_OFF_JSON" ]] || REVIEWER_EXPECTED_OFF_JSON='[]'
  fi
  unset _off_rows
fi

# ---------------------------------------------------------------------------
# Pure rendering / aggregation helpers (unit-tested, no network)
# ---------------------------------------------------------------------------

# _fmt_int <number> — integer with thousands separators (1234 → 1,234).
_fmt_int() {
  awk -v n="${1:-0}" 'BEGIN {
    n = int(n + 0.5); s = ""; if (n < 0) { neg = 1; n = -n }
    if (n == 0) s = "0"
    while (n > 0) { r = n % 1000; n = int(n / 1000);
      s = (n > 0) ? sprintf("%03d", r) (s == "" ? "" : "," s) : r (s == "" ? "" : "," s) }
    printf "%s%s", (neg ? "-" : ""), s
  }'
}

# _fmt_pct <numerator> <denominator> — integer percent, "n/a" when denom is 0.
_fmt_pct() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { if (b <= 0) print "n/a"; else printf "%d%%", (a / b * 100) + 0.5 }'
}

# _fmt_dur <seconds> — compact human duration (e.g. 45s, 12m, 3.4h, 2.1d).
# Prints "—" for empty/negative input so an absent metric renders cleanly.
_fmt_dur() {
  awk -v s="${1:-}" 'BEGIN {
    if (s == "" || s < 0) { print "—"; exit }
    s = s + 0
    if (s < 90)            printf "%ds", s
    else if (s < 5400)     printf "%dm", (s/60) + 0.5
    else if (s < 172800)   printf "%.1fh", s/3600
    else                   printf "%.1fd", s/86400
  }'
}

# _delta_arrow <curr> <prev> — "(▲ +3)" / "(▼ -2)" / "(±0)" / "" (no prior).
# Higher = up-arrow; the arrow is directional only, not good/bad (that varies by
# metric — more approvals is good, more rate-limits is bad), so we keep it neutral.
_delta_arrow() {
  local curr="${1:-}" prev="${2:-}"
  [[ -z "$prev" ]] && { printf ''; return 0; }
  awk -v c="${curr:-0}" -v p="${prev:-0}" 'BEGIN {
    d = c - p
    if (d > 0)      printf "(▲ +%g)", d
    else if (d < 0) printf "(▼ %g)", d
    else            printf "(±0)"
  }'
}

# normalize_pr_node — jq filter (as a string) that turns one GraphQL PR node into
# a stream of normalized JSONL records. Emits:
#   {kind:"pr", repo, pr, created, merged, draft, author}         (denominator)
#   {kind:"bot_pr", repo, pr, bot, created, classes, real_responses, refusals,
#      refused_at, latency_s, reviews, approved, changes_req, inline_comments, threads_total,
#      threads_resolved, findings_threads, findings_body, findings_raised,
#      thumbs_up, thumbs_down, unclassified_samples}                                       (participation)
# Args: --arg repo, --argjson bots (login array), --arg rl (rate-limit regex).
# A "bot_pr" record is emitted for every bot that left at least one message.
#
# Per-message classes (#2504). Every bot message — review, inline comment, issue
# comment, completed check run — gets exactly ONE class:
#   finding | clean | refused | skipped | status | unclassified
# decided in this order (first hit wins):
#   0. a check run with a failed conclusion is `status` (the job broke; whatever its
#      summary says, it carries no review — #1913);
#   1. the bot's own rows in reviewer-message-classes.tsv, top to bottom. A row of
#      kind `any` reaches an inline comment only when its class is `finding` or
#      `clean` (#2527): a broad status, skip or refusal phrase inside a real inline
#      finding must not drop it from threads and findings;
#   2. the shared refusal fallback: $rl (ADVISORY_RATE_LIMIT_RE) or the author-scoped
#      cubic clause → `refused`. Never applied to inline comments: a finding that talks
#      about a rate limit is still a finding;
#   3. structural defaults: the first comment of a review thread is a `finding` and a
#      later one (a reply) is `status`; a CHANGES_REQUESTED review is a `finding`, an
#      APPROVED one `clean`; a check run that succeeded (or says the review ran) is
#      `clean`, one skipped with a decline reason `refused`, one with an empty summary
#      `status`;
#   4. otherwise `unclassified`.
# A PR counts as reviewed by a bot only when it left a `finding` or `clean` message.
#
# Findings raised (#2527) = findings_threads + findings_body:
#   findings_threads — review threads the bot opened with a finding;
#   findings_body    — findings written in its review / comment / check-run bodies.
#     coderabbitai: the counts in its "Outside diff range comments" and "Nitpick
#       comments" headers, whether or not it opened threads (those items never
#       become threads);
#     chatgpt-codex-connector: each code location its body points at, unless an
#       inline comment from the same review sits on the same file and line;
#     a finding body with none of the above counts once, and only on a PR where the
#       bot opened no thread (otherwise it is the summary of those threads).
# shellcheck disable=SC2089  # this is a jq program; embedded quotes are meant to be literal
_NORMALIZE_JQ='
  def is_bot($login): ($login != null) and ($login | ascii_downcase) as $l
    | ($bots | map(ascii_downcase) | index($l)) != null;
  def class_rules: '"$REVIEWER_MESSAGE_CLASS_JSON"';
  def failed_conclusions: ["failure","cancelled","timed_out","action_required","stale","startup_failure"];
  def classify:
    . as $m
    | ($m.body // "") as $b
    | ((($m.conclusion // "") | ascii_downcase)) as $concl
    | if $m.kind == "check_run" and (failed_conclusions | index($concl)) != null then "status"
      else
        ( [ (class_rules[$m.bot] // [])[]
            | select(.kind == $m.kind
                     or (.kind == "any" and ($m.kind != "inline" or .class == "finding" or .class == "clean")))
            | select(.pattern as $p | $b | test($p; "i"))
            | select($m.kind != "review" or $m.state != "CHANGES_REQUESTED")
            | .class ] | first ) as $rule
        | if $rule != null then $rule
          elif $m.kind != "inline"
               and ($m.state != "CHANGES_REQUESTED")
               and (($b | test($rl; "i"))
                    or ($m.bot == "'"$CUBIC_LOGIN"'" and ($b | test("'"$CUBIC_RATE_LIMIT_RE"'"; "i"))))
            then "refused"
          elif $m.kind == "inline" then (if $m.first_in_thread then "finding" else "status" end)
          elif $m.kind == "review" and $m.state == "CHANGES_REQUESTED" then "finding"
          elif $m.kind == "review" and $m.state == "APPROVED" then "clean"
          elif $m.kind == "check_run" then
            if $concl == "success" or ($b | test("review ran"; "i")) then "clean"
            elif $concl == "skipped" and ($b | test("did not run|too large|declin|rate.?limit|quota|usage limit"; "i")) then "refused"
            elif $concl == "skipped" and ($b | test("^\\s*$")) then "status"
            elif $concl == "skipped" then "skipped"
            elif ($b | test("^\\s*$")) then "status"
            else "unclassified" end
          else "unclassified" end
      end;
  # A short, inert sample of an unclassified body for the report: URLs and backticks
  # removed, whitespace collapsed, cut to 100 characters. Rendered inside a code span,
  # so an @mention in it never notifies anyone.
  def sample:
    (.body // "") | gsub("https?://[^\\s)]+"; "[url]") | gsub("[`\\s]+"; " ")
    | sub("^ "; "") | sub(" $"; "")
    | if length > 100 then .[0:100] + "…" else . end;
  # CodeRabbit body findings (#2527): the counts in its section headers. bodyText
  # carries two header forms, "Outside diff range comments (2)" and "Nitpick
  # comments: 2". The unnumbered repeats in its "Prompt to fix all issues" block
  # ("Outside diff comments:", "Nitpick comments:") carry no count and never match.
  def coderabbit_body_count:
    (.body // "") as $b
    | [ ("Outside diff range", "Nitpick") as $s
        | (first($b | match("\($s) comments[ \\t]*(?:\\([ \\t]*|:[ \\t]*)([0-9]+)"; "i"))
           | .captures[0].string | tonumber) // 0 ]
    | add;
  # Codex body findings (#2527): each code location the body points at, read from
  # bodyText as the permalink (…/blob/<sha>/<path>#L<a>-L<b>) or as the snippet
  # GitHub renders from it (a <repo>/<path> line, then Lines <a> to <b> in <sha>; the
  # whole line is the path, so a path with spaces survives; a path on the same line
  # as the Lines label is read up to the first space). Both yield a
  # repository-relative path: the leading repo-name segment (a repo
  # name never contains "/") is stripped from the snippet form, so paths compare exactly.
  # The permalink path is URL-encoded (a space is %20) while GraphQL paths are not,
  # so ASCII escapes are decoded; a multi-byte escape is left as it is.
  def codex_location: .captures | { path: .[0].string, from: (.[1].string | tonumber),
                                    to: ((.[2].string // .[1].string) | tonumber) };
  def url_decode_ascii:
    gsub("%(?<h>[0-7][0-9A-Fa-f])";
         .h | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end)
         | [.[0] * 16 + .[1]] | implode);
  def codex_locations:
    (.body // "") as $b
    | [ ($b | match("/blob/[0-9a-f]{7,40}/([^#\\s]+)#L([0-9]+)(?:-L([0-9]+))?"; "g")
            | codex_location | .path |= url_decode_ascii),
        ($b | match("(?:([^\\n]*\\S)[ \\t]*\\n\\s*|(\\S+)[ \\t]+)Lines? ([0-9]+)(?: to ([0-9]+))?\\s+in\\s+[0-9a-f]{7,40}\\b"; "g")
            | .captures | { path: (.[0].string // .[1].string), from: (.[2].string | tonumber),
                            to: ((.[3].string // .[2].string) | tonumber) }
            | .path |= (sub("^\\s+"; "") | sub("^[^/]*/"; ""))) ]
    # One location written both ways counts once.
    | unique_by([.path, .from, .to]);
  # Does this inline comment sit on $loc? The same repository-relative path, and an
  # overlapping line span on the current or the original diff.
  def at_location($loc):
    (.path // "") as $p
    | ($p != "") and $loc.path == $p
      and ([ [(.start_line // .line), .line], [(.original_start_line // .original_line), .original_line] ]
           | any(.[]; .[0] != null and .[1] != null and .[0] <= $loc.to and .[1] >= $loc.from));
  # Findings this body carries on its own, beyond the threads its bot opened. The
  # argument is that same bot inline comments on the PR.
  def body_finding_count($inline):
    . as $m
    | if $m.bot == "coderabbitai" then coderabbit_body_count
      elif $m.bot == "chatgpt-codex-connector" then
        [ codex_locations[] as $loc
          | select(($inline | any(.[]; .review_id != null and .review_id == $m.id and at_location($loc))) | not) ]
        | length
      else 0 end;
  . as $pr
  | ([ (.reviews.nodes // [])[]
       | select(.author.login as $a | is_bot($a))
       | { bot: (.author.login|ascii_downcase), at: .submittedAt, id: (.id // null),
           kind: "review", state: (.state // "COMMENTED"),
           body: (.bodyText // ""), reactions_up: 0, reactions_down: 0,
           first_in_thread: false, resolved: false, outdated: false } ]
    + [ (.reviewThreads.nodes // [])[] as $t
        | ($t.comments.nodes // []) | to_entries[]
        | .key as $idx | .value
        | select(.author.login as $a | is_bot($a))
        | { bot: (.author.login|ascii_downcase), at: .createdAt,
            kind: "inline", state: "COMMENTED", body: (.bodyText // ""),
            reactions_up: ([ (.reactionGroups // [])[] | select(.content=="THUMBS_UP") | .users.totalCount ] | add // 0),
            reactions_down: ([ (.reactionGroups // [])[] | select(.content=="THUMBS_DOWN") | .users.totalCount ] | add // 0),
            first_in_thread: ($idx == 0),
            resolved: ($t.isResolved // false), outdated: ($t.isOutdated // false),
            review_id: (.pullRequestReview.id // null), path: (.path // null),
            line: (.line // null), original_line: (.originalLine // null),
            start_line: (.startLine // null), original_start_line: (.originalStartLine // null) } ]
    + [ (.comments.nodes // [])[]
        | select(.author.login as $a | is_bot($a))
        | { bot: (.author.login|ascii_downcase), at: .createdAt,
            kind: "issue", state: "COMMENTED", body: (.bodyText // ""),
            reactions_up: 0, reactions_down: 0, first_in_thread: false, resolved: false, outdated: false } ]
    # Check-run reviews (#1908): a bot that reports through a check run (Graphite)
    # posts each review as a `<name>` check run, not a PR review — a clean pass leaves
    # NO PR review, only a completed check run. The collector attaches the matched
    # check runs under ._checkRuns. Every COMPLETED run is a message and is classified
    # like any other (#2504) — so a `neutral` "hourly limit reached" run is refused.
    # A queued or in-progress run has no result yet and is not a message.
    + [ (.["_checkRuns"] // [])[]
        | select(.bot as $a | is_bot($a))
        | select(.status == "completed")
        | { bot: (.bot|ascii_downcase), at: (.completed_at // .completedAt),
            kind: "check_run", state: "COMMENTED", conclusion: (.conclusion // ""),
            body: (.summary // ""), reactions_up: 0, reactions_down: 0,
            first_in_thread: false, resolved: false, outdated: false } ]
    ) as $subs
  | ( { kind: "pr", repo: $repo, pr: ($pr.url),
        created: $pr.createdAt, merged: ($pr.mergedAt // null),
        draft: ($pr.isDraft // false), author: ($pr.author.login // "") } ),
    ( $subs | group_by(.bot)[] as $grp
      | ($grp | map(. + {class: classify})) as $mine
      | ($mine | map(select(.class == "finding" or .class == "clean"))) as $real
      | ($mine | map(select(.class == "refused")))   as $refd
      # Messages that are not refusals, skips or status notices: the legacy review /
      # verdict counts are taken from these.
      | ($mine | map(select(.class == "finding" or .class == "clean" or .class == "unclassified"))) as $substantive
      | ($real | map(.at) | min) as $first_real
      | ($substantive | map(select(.kind=="review")) | length) as $rev_events
      # Threads this bot OPENED with a finding — reply comments are not new threads.
      | ($mine | map(select(.kind=="inline" and .first_in_thread and .class=="finding"))) as $threads
      | ($mine | map(select(.kind=="inline"))) as $inline
      | ($mine | map(select(.kind!="inline" and .class=="finding") | body_finding_count($inline))) as $body_counts
      | (($body_counts | add // 0)
         + (if ($threads | length) > 0 then 0 else ($body_counts | map(select(. == 0)) | length) end)) as $body_findings
      | { kind: "bot_pr", repo: $repo, pr: ($pr.url),
          bot: $grp[0].bot, created: $pr.createdAt,
          classes: (reduce ("finding","clean","refused","skipped","status","unclassified") as $c
                      ({}; .[$c] = ($mine | map(select(.class == $c)) | length))),
          real_responses: ($real | length),
          refusals:       ($refd | length),
          # When each refusal was posted, oldest first — the quota-timing section (#2506).
          refused_at:     ($refd | map(.at // empty) | sort),
          # Latency = time to first finding/clean message (null when the bot never
          # reviewed, so refusals and status notices never pollute the percentiles).
          latency_s: (if ($real | length) == 0 then null
                      else (($first_real | fromdateiso8601) - ($pr.createdAt | fromdateiso8601)) end),
          # Reviews (details section) = formal review submissions that are not a
          # refusal, skip or status notice. A bot that posts NO formal review but
          # delivers its verdict as a top-level comment (SonarCloud) has its finding /
          # clean comments counted instead — never its status or quota comments.
          reviews:      (if $rev_events > 0 then $rev_events
                         else ($real | map(select(.kind=="issue")) | length) end),
          approved:     ($substantive | map(select(.kind=="review" and .state=="APPROVED")) | length),
          changes_req:  ($substantive | map(select(.kind=="review" and .state=="CHANGES_REQUESTED")) | length),
          inline_comments:  ($mine | map(select(.kind=="inline" and .class=="finding")) | length),
          threads_total:    ($threads | length),
          threads_resolved: ($threads | map(select(.resolved)) | length),
          # Findings raised = threads opened + body findings (#2527, see above).
          findings_threads: ($threads | length),
          findings_body:    $body_findings,
          findings_raised:  (($threads | length) + $body_findings),
          thumbs_up:   ($mine | map(.reactions_up // 0)   | add // 0),
          thumbs_down: ($mine | map(.reactions_down // 0) | add // 0),
          unclassified_samples: ($mine | map(select(.class == "unclassified") | sample) | .[0:3]) } )
'

# aggregate_snapshot <jsonl_dir> — PURE. Reads normalized JSONL and emits the
# per-bot headline-metric snapshot as compact JSON (also the WoW artifact payload).
# Every eligible (non-draft) PR falls into exactly one bucket PER BOT (#2504), first
# match wins, and the five buckets sum to eligible_prs:
#   with_findings_prs — the bot left at least one `finding` message
#   clean_prs         — the bot left a `clean` message and no `finding`
#   refused_prs       — no finding/clean, at least one `refused` message
#   skipped_prs       — no finding/clean/refused, at least one `skipped` message
#   no_response_prs   — everything else: the bot never appeared, or left only
#                       `status` / `unclassified` messages
# reviewed_prs = with_findings_prs + clean_prs. reviews / refusal_events and the
# *_events class counts are EVENT counts (each message counted); *_prs are PR counts.
# schema_version 2 marks a snapshot carrying these fields, so the week-over-week
# diff never compares them against a v1 snapshot whose buckets meant something else.
# schema_version 3 (#2527) adds findings_threads / findings_body and counts
# CodeRabbit and Codex body findings in findings_raised, so its delta needs a v3 prior.
#   { "schema_version": 3, "eligible_prs": N, "total_prs": N,
#     "bots": { "<login>": { with_findings_prs, clean_prs, refused_prs, skipped_prs,
#               no_response_prs, reviewed_prs, engaged_prs, findings_raised,
#               findings_threads, findings_body,
#               finding_events, clean_events, skipped_events, status_events,
#               unclassified_events, reviews, refusal_events, approved, changes_req,
#               inline_comments, threads_total, threads_resolved, thumbs_up,
#               thumbs_down, latency_p50, latency_p95 } , ... } }
# Unclassified sample bodies are deliberately NOT in the snapshot (see
# _render_unclassified_samples) — the artifact holds numbers only.
aggregate_snapshot() {
  local dir="$1"
  local files=("$dir"/*.jsonl)
  [[ -e "${files[0]}" ]] || { echo '{"schema_version":3,"eligible_prs":0,"total_prs":0,"bots":{}}'; return 0; }
  jq -s '
    def is_dependabot: test("^dependabot(-preview)?(\\[bot\\])?$"; "i");
    (map(select(.kind=="pr"))) as $prs
    | (map(select(.kind=="bot_pr"))) as $bp
    | ($prs | length) as $total
    # Bucket over ELIGIBLE (non-draft, non-Dependabot) PRs only, so the buckets sum to eligible.
    | (reduce ($prs[] | select(.draft == false and ((.author // "") | is_dependabot | not))) as $p ({}; .[$p.pr] = true)) as $elig_map
    | ($elig_map | length) as $eligible
    | ($bp | map(select($elig_map[.pr]))) as $bpe
    | ($bpe | group_by(.bot) | map(
        (.[0].bot) as $bot
        | (map(select((.real_responses // 0) > 0))) as $reviewed
        | ($reviewed | map(select((.classes.finding // 0) > 0))) as $with_findings
        | (map(select((.real_responses // 0) == 0 and (.refusals // 0) > 0))) as $refused
        | (map(select((.real_responses // 0) == 0 and (.refusals // 0) == 0
                      and (.classes.skipped // 0) > 0))) as $skipped
        | ([.[].latency_s] | map(select(. != null)) | sort) as $lat
        | { key: $bot, value: {
            with_findings_prs: ($with_findings | length),
            clean_prs:        (($reviewed | length) - ($with_findings | length)),
            refused_prs:      ($refused | length),
            skipped_prs:      ($skipped | length),
            no_response_prs:  ($eligible - ($reviewed | length) - ($refused | length) - ($skipped | length)),
            reviewed_prs:     ($reviewed | length),
            engaged_prs:      length,
            findings_raised:  ([.[].findings_raised // 0] | add),
            findings_threads: ([.[].findings_threads // 0] | add),
            findings_body:    ([.[].findings_body // 0] | add),
            finding_events:   ([.[].classes.finding // 0] | add),
            clean_events:     ([.[].classes.clean // 0] | add),
            skipped_events:   ([.[].classes.skipped // 0] | add),
            status_events:    ([.[].classes.status // 0] | add),
            unclassified_events: ([.[].classes.unclassified // 0] | add),
            reviews:          ([.[].reviews // 0] | add),
            refusal_events:   ([.[].refusals // 0] | add),
            approved:         ([.[].approved // 0] | add),
            changes_req:      ([.[].changes_req // 0] | add),
            inline_comments:  ([.[].inline_comments // 0] | add),
            threads_total:    ([.[].threads_total // 0] | add),
            threads_resolved: ([.[].threads_resolved // 0] | add),
            thumbs_up:        ([.[].thumbs_up // 0] | add),
            thumbs_down:      ([.[].thumbs_down // 0] | add),
            latency_p50: (if ($lat|length)==0 then null else $lat[(((($lat|length)-1)*0.50)|floor)] end),
            latency_p95: (if ($lat|length)==0 then null else $lat[(((($lat|length)-1)*0.95)|round)] end)
          } } ) | from_entries) as $bots
    | { schema_version: 3, eligible_prs: $eligible, total_prs: $total, bots: $bots }
  ' "${files[@]}" 2>/dev/null || echo '{"schema_version":3,"eligible_prs":0,"total_prs":0,"bots":{}}'
}

# _prev <snapshot_json_file> <bot> <field> — prior-week scalar or "" when absent.
_prev() {
  local f="${1:-}" bot="$2" field="$3"
  [[ -n "$f" ]] && [[ -f "$f" ]] || { printf ''; return 0; }
  jq -r --arg b "$bot" --arg k "$field" '.bots?[$b]?[$k]? // empty' "$f" 2>/dev/null || printf ''
}

# _prev_since <min_schema> <snapshot_json_file> <bot> <field> — like _prev, but ""
# unless the prior snapshot is schema_version >= <min_schema>. A field whose meaning
# changed in a schema bump must not show a delta against an older snapshot.
_prev_since() {
  local min="$1" f="${2:-}" bot="$3" field="$4"
  [[ -n "$f" ]] && [[ -f "$f" ]] || { printf ''; return 0; }
  jq -r --argjson min "$min" --arg b "$bot" --arg k "$field" '
    if ((.schema_version? // 1) | tonumber? // 1) >= $min then
      (.bots?[$b]? // null) as $bot
      | if $bot == null then (if $k == "no_response_prs" then .eligible_prs else empty end)
        else ($bot[$k]? // empty) end
    else empty end
  ' "$f" 2>/dev/null || printf ''
}

# _prev_v2 <snapshot_json_file> <bot> <field> — "" unless the prior snapshot is
# schema_version >= 2 (#2504). A v1 snapshot has no with_findings_prs / skipped_prs,
# and its refused_prs / no_response_prs were counted under the old rules, so a
# headline delta against it would be wrong. No delta is shown instead.
_prev_v2() { _prev_since 2 "$@"; }

# _prev_v3 <snapshot_json_file> <bot> <field> — "" unless the prior snapshot is
# schema_version >= 3 (#2527): findings_raised before v3 left out CodeRabbit and
# Codex body findings on PRs where the bot also opened threads.
_prev_v3() { _prev_since 3 "$@"; }

# _pct_num <numerator> <denominator> — integer percent, "" when denom is 0 (for deltas).
_pct_num() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { if (b <= 0) print ""; else printf "%d", (a / b * 100) + 0.5 }'
}

# _render_collection_health <jsonl_dir> <repo_count> — PURE. Prints a PROMINENT
# section for any repo the collector could not fetch (#1908) and for any per-PR
# connection that hit the GraphQL fetch cap. Prints NOTHING when collection was
# clean. This is the in-report surfacing the issue requires: a silent stderr WARN
# is not enough, because a dropped repo makes every count below a floor, not a
# total, and that must be visible to whoever reads the scorecard.
_render_collection_health() {
  local dir="$1" repo_count="$2"
  local files=("$dir"/*.jsonl)
  [[ -e "${files[0]}" ]] || return 0

  local errs
  errs="$(jq -rs --argjson m "${repo_count:-0}" '
    ([ .[] | select(.kind=="collect_error") ] | unique_by(.repo)) as $e
    | if ($e | length) == 0 then empty
      else "## ⚠️ Collection health\n\n"
        + "**\($e | length) of \($m) repos could not be collected** after retries — "
        + "their PRs are absent or incomplete in every metric below, so all counts are a **floor, not a total**. "
        + "This is the #1908 failure mode (silent page-1 GraphQL failure); investigate before trusting the numbers or the week-over-week deltas.\n\n"
        + ([ $e[] | "- `\(.repo)` — \(.reason // "collection failed")" ] | join("\n"))
        + "\n"
      end
  ' "${files[@]}" 2>/dev/null || true)"
  [ -n "$errs" ] && printf '%s\n' "$errs"

  local trunc
  trunc="$(jq -rs '
    ([ .[] | select(.kind=="truncation") ] | unique_by([.repo, .pr, .connection])) as $t
    | if ($t | length) == 0 then empty
      else "### Truncated connections\n\n"
        + "These per-PR connections hit the GraphQL fetch cap, so the affected reviewer counts may **undercount** on these PRs (truncation is reported here, never silent — #1908):\n\n"
        + ([ $t[] | "- `\(.repo)` PR `\(.pr)` — `\(.connection)` truncated" ] | join("\n"))
        + "\n"
      end
  ' "${files[@]}" 2>/dev/null || true)"
  [ -n "$trunc" ] && printf '%s\n' "$trunc"

  local crerr
  crerr="$(jq -rs '
    ([ .[] | select(.kind=="check_run_error") ] | unique_by([.repo, .pr])) as $c
    | if ($c | length) == 0 then empty
      else "### Check-run fetch failures\n\n"
        + "A check-run REST fetch failed on these PRs, so a check-run reporter clean pass may be missed and miscounted as No response (surfaced here, never silent — #1908):\n\n"
        + ([ $c[] | "- `\(.repo)` PR `\(.pr)` — check-run fetch failed" ] | join("\n"))
        + "\n"
      end
  ' "${files[@]}" 2>/dev/null || true)"
  [ -n "$crerr" ] && printf '%s\n' "$crerr"
  return 0
}

# _render_unclassified_samples <jsonl_dir> — PURE (#2504). For each tracked bot that
# left `unclassified` messages on eligible PRs, prints its count and up to 3 truncated
# sample bodies, so a new message shape is visible and can be given a pattern in
# scripts/lib/reviewer-message-classes.tsv. Prints NOTHING when every message was
# classified. Samples are already made inert at normalization (URLs and backticks
# removed, 100 characters max) and are printed inside code spans, so an @mention in a
# bot body never notifies anyone from the report comment.
_render_unclassified_samples() {
  local dir="$1"
  local files=("$dir"/*.jsonl)
  [[ -e "${files[0]}" ]] || return 0
  local data
  data="$(jq -sc '
    def is_dependabot: test("^dependabot(-preview)?(\\[bot\\])?$"; "i");
    (reduce (.[] | select(.kind=="pr" and .draft == false and ((.author // "") | is_dependabot | not))) as $p ({}; .[$p.pr] = true)) as $elig
    | [ .[] | select(.kind=="bot_pr" and $elig[.pr] and ((.classes.unclassified // 0) > 0)) ]
    | group_by(.bot)
    | map({ key: .[0].bot,
            value: { count: ([.[].classes.unclassified] | add),
                     samples: ([.[].unclassified_samples // [] | .[]] | .[0:3]) } })
    | from_entries' "${files[@]}" 2>/dev/null || printf '{}')"
  { [[ -z "$data" ]] || [[ "$data" = "{}" ]]; } && return 0

  printf '## Unclassified messages\n\n'
  printf 'Bot messages that no pattern recognized. They count toward no column above. '
  printf 'Add a row to `scripts/lib/reviewer-message-classes.tsv` for each new shape (see `docs/reviewer-report.md`).\n\n'
  local bot label lines
  for bot in "${REVIEWER_BOTS[@]}"; do
    lines="$(jq -r --arg b "$bot" '
      .[$b] // empty
      | "**\(.count)** unclassified message\(if .count == 1 then "" else "s" end)",
        (.samples[] | gsub("https?://[^\\s)]+"; "[url]") | gsub("[`\\s]+"; " ") | .[0:101]
                    | "  - `\(.)`")' <<<"$data" 2>/dev/null || true)"
    [[ -n "$lines" ]] || continue
    label="${REVIEWER_LABELS[$bot]:-$bot}"
    printf -- '- **%s** — %s\n' "$label" "${lines%%$'\n'*}"
    if [[ "$lines" != "${lines%%$'\n'*}" ]]; then printf '%s\n' "${lines#*$'\n'}"; fi
  done
  printf '\n'
  return 0
}

# ---------------------------------------------------------------------------
# Coverage matrix, outage alerts and quota timing (#2506) — PURE
# ---------------------------------------------------------------------------
# Every count in these three sections leaves out Dependabot-authored PRs.
#   opened   — non-draft PRs created in the window (on or after the window start,
#              REVIEWER_WINDOW_START, else CUTOFF; with neither set, every collected PR).
#   reviewed — opened PRs on which the bot left a `finding` or `clean` message (#2504).
#   day      — the UTC calendar day a PR was opened.
# Expected-off cells come from REVIEWER_EXPECTED_OFF_JSON (the sidecar's `off` rows).
_COVERAGE_JQ_DEFS='
  def is_dependabot: test("^dependabot(-preview)?(\\[bot\\])?$"; "i");
  # Is $bot expected off on $repo? A declared "owner/name" matches that repo; a bare
  # "name" matches the repo of that name under any owner.
  def is_off($bot; $repo):
    ($repo | ascii_downcase) as $r
    | any($off[]; (.login | ascii_downcase) == ($bot | ascii_downcase)
                  and ((.repo | ascii_downcase) as $d
                       | if ($d | contains("/")) then $d == $r else $d == ($r | split("/") | last) end));
  def opened_prs:
    [ .[] | select(.kind == "pr" and .draft == false
                   and ((.author // "") | is_dependabot | not)
                   and ($start == "" or (.created // "") >= $start))
          | {pr, repo, day: (.created[0:10])} ]
    | unique_by(.pr);
  # "<bot> <pr url>" → true for every PR the bot reviewed.
  def reviewed_set:
    reduce (.[] | select(.kind == "bot_pr" and (.real_responses // 0) > 0)) as $b
      ({}; .[$b.bot + " " + $b.pr] = true);
  def bot_label($b): $labels[$b] // $b;
'

# _coverage_jq <jsonl_dir> <jq program> — run a coverage program over the slurped
# records with $bots, $off, $start and $labels bound. Returns non-zero when jq fails,
# so a renderer never reads a failure as "no alerts".
_coverage_jq() {
  local dir="$1" prog="$2"
  local files=("$dir"/*.jsonl)
  [[ -e "${files[0]}" ]] || return 0
  local bots_json labels_json b
  bots_json="$(printf '%s\n' "${REVIEWER_BOTS[@]}" | jq -R . | jq -sc .)"
  labels_json='{}'
  for b in "${REVIEWER_BOTS[@]}"; do
    labels_json="$(jq -c --arg k "$b" --arg v "${REVIEWER_LABELS[$b]:-$b}" '. + {($k): $v}' <<<"$labels_json")"
  done
  jq -rs --argjson bots "$bots_json" --argjson off "${REVIEWER_EXPECTED_OFF_JSON:-[]}" \
    --arg start "${REVIEWER_WINDOW_START:-${CUTOFF:-}}" --argjson labels "$labels_json" \
    "${_COVERAGE_JQ_DEFS} ${prog}" "${files[@]}"
}

# _coverage_failed <section> — the line a section prints when its jq program failed.
_coverage_failed() {
  printf '⚠️ The %s could not be computed (jq failed; see the run log). This is not the same as none.\n\n' "$1"
}

# _render_outage_alerts <jsonl_dir> — PURE (#2506). The "Outage alerts" section, put
# at the top of the report. Two rules, each over the expected-on cells only:
#   1. org-wide silence: on 2 or more consecutive days the bot reviewed none of the PRs
#      opened that day in the repos where it is expected on, and those days have at
#      least 3 opened PRs between them. Only days on which such a PR was opened count;
#      a day with none neither ends nor extends a run.
#   2. single-repo silence: a cell with at least 3 opened PRs and 0 reviewed.
# Each alert names the bot, the repo(s) and the first silent day. Prints "none" when
# no rule fires.
_render_outage_alerts() {
  local dir="$1" alerts
  printf '## Outage alerts\n\n'
  alerts="$(_coverage_jq "$dir" '
    . as $all
    | ($all | opened_prs) as $o
    | ($all | reviewed_set) as $rv
    | ($o | map(.repo) | unique) as $repos
    # Rule 1 — runs of silent days per bot, over the repos where it is expected on.
    | [ $bots[] as $b
        | ($o | map(select(is_off($b; .repo) | not))) as $on
        | ($on | group_by(.day)
               | map({ day: .[0].day, opened: length, repos: (map(.repo) | unique),
                       reviewed: (map(select($rv[$b + " " + .pr])) | length) })) as $days
        | reduce ($days[], {reviewed: 1}) as $d ({runs: [], cur: null};
            if $d.reviewed == 0 then
              .cur = (if .cur == null then {first: $d.day, days: 1, opened: $d.opened, repos: $d.repos}
                      else (.cur | .days += 1 | .opened += $d.opened | .repos = ((.repos + $d.repos) | unique)) end)
            else (if .cur != null then .runs += [.cur] else . end) | .cur = null end)
        | .runs[] | select(.days >= 2 and .opened >= 3)
        | "- **\(bot_label($b))** — no PR reviewed on \(.days) consecutive days with PRs (\(.opened) PRs opened) in "
          + (.repos | map("`\(.)`") | join(", ")) + "; first silent day **\(.first)**." ]
    # Rule 2 — a cell with at least 3 opened PRs and none reviewed all window.
    + [ $bots[] as $b | $repos[] as $r
        | select(is_off($b; $r) | not)
        | ($o | map(select(.repo == $r))) as $prs
        | select(($prs | length) >= 3 and ($prs | map(select($rv[$b + " " + .pr])) | length) == 0)
        | "- **\(bot_label($b))** — 0 of \($prs | length) PRs opened in `\($r)` reviewed in the whole window; "
          + "first silent day **\($prs | map(.day) | min)**." ]
    | .[]')" || { _coverage_failed "outage alerts"; return 0; }

  if [[ -z "$alerts" ]]; then
    printf 'none\n\n'
    return 0
  fi
  printf '%s\n\n' "$alerts"
  printf '_Rules and how to mark a cell off by design: `docs/reviewer-report.md` (Outage alerts)._\n\n'
}

# _render_coverage_matrix <jsonl_dir> — PURE (#2506). One row per repo with an opened
# PR, one column per tracked bot; each cell is "reviewed / opened", or
# "off (by design)" for an expected-off cell.
_render_coverage_matrix() {
  local dir="$1" table
  printf '## Coverage matrix\n\n'
  table="$(_coverage_jq "$dir" '
    . as $all
    | ($all | opened_prs) as $o
    | ($all | reviewed_set) as $rv
    | ($o | map(.repo) | unique) as $repos
    | if ($repos | length) == 0 then empty
      else
        ("| Repo | " + ($bots | map(bot_label(.)) | join(" | ")) + " |"),
        ("|---|" + ($bots | map("---:|") | join(""))),
        ( $repos[] as $r
          | ($o | map(select(.repo == $r))) as $prs
          | "| `\($r)` | "
            + ($bots | map(. as $b
                | if is_off($b; $r) then "off (by design)"
                  else "\($prs | map(select($rv[$b + " " + .pr])) | length) / \($prs | length)" end)
              | join(" | "))
            + " |" )
      end')" || { _coverage_failed "coverage matrix"; return 0; }

  if [[ -z "$table" ]]; then
    printf 'No non-draft, non-Dependabot PRs were opened in the window.\n\n'
    return 0
  fi
  printf 'PRs each bot reviewed (a `finding` or `clean` message) out of the non-draft PRs opened in each repo in the window. '
  printf 'Dependabot PRs are left out. `off (by design)` marks a bot that is meant not to run on that repo '
  printf '(declared in `scripts/lib/reviewer-message-classes.tsv`).\n\n'
  printf '%s\n\n' "$table"
}

# _render_quota_timing <jsonl_dir> — PURE (#2506). For each bot with `refused`
# messages in the window (Dependabot PRs left out): refusals per UTC day and the time
# of the first refusal that day, so the hour a daily quota runs out is visible.
_render_quota_timing() {
  local dir="$1" rows
  printf '## Quota timing\n\n'
  rows="$(_coverage_jq "$dir" '
    (reduce (.[] | select(.kind == "pr")) as $p ({}; .[$p.pr] = (($p.author // "") | is_dependabot))) as $dep
    | [ .[] | select(.kind == "bot_pr" and ($dep[.pr] | not)) ] | unique_by([.bot, .pr])
    | [ .[] | .bot as $b | (.refused_at // [])[] | select($start == "" or . >= $start) | {bot: $b, at: .} ] as $ev
    | $bots[] as $b
    | ($ev | map(select(.bot == $b)) | group_by(.at[0:10]))[]
    | "| \(bot_label($b)) | \(.[0].at[0:10]) | \(length) | \(map(.at) | min | .[11:16]) |"')" || { _coverage_failed "quota timing"; return 0; }

  if [[ -z "$rows" ]]; then
    printf 'none\n\n'
    return 0
  fi
  printf 'Refusals (quota, rate limit, trial or plan) per bot per UTC day, and the time of the first one that day. Dependabot PRs are left out.\n\n'
  printf '| Reviewer | Day (UTC) | Refusals | First refusal (UTC) |\n'
  printf '|---|---|---:|---:|\n'
  printf '%s\n\n' "$rows"
}

# render_reviewer_report <jsonl_dir> <lookback> <repo_count> [generated_at]
# Writes the full Markdown report to stdout. PURE: no network. Optional prior
# snapshot for WoW deltas via REVIEWER_PREV_SNAPSHOT.
render_reviewer_report() {
  local dir="$1" lookback="$2" repo_count="$3" generated_at="${4:-}"
  local prev="${REVIEWER_PREV_SNAPSHOT:-}"

  local snap; snap="$(aggregate_snapshot "$dir")"
  local eligible total
  eligible="$(jq -r '.eligible_prs' <<<"$snap")"
  total="$(jq -r '.total_prs' <<<"$snap")"

  printf '# 🔎 Third-Party Reviewer Scorecard — %s-day Report\n\n' "$lookback"
  if [[ -n "$generated_at" ]]; then
    printf '_Generated %s · org `%s` · %s repos scanned · %s PRs active (%s non-draft, review-eligible)_\n\n' \
      "$generated_at" "$ORG" "$repo_count" "$(_fmt_int "$total")" "$(_fmt_int "$eligible")"
  else
    printf '_org `%s` · %s repos scanned · %s PRs active (%s non-draft, review-eligible)_\n\n' \
      "$ORG" "$repo_count" "$(_fmt_int "$total")" "$(_fmt_int "$eligible")"
  fi

  # Surface collection failures / truncation FIRST and unconditionally, so a run
  # that dropped repos never presents its partial counts as complete (#1908).
  _render_collection_health "$dir" "$repo_count"

  if [[ "${total:-0}" -eq 0 ]]; then
    printf 'No pull-request activity found in the last %s days.\n' "$lookback"
    if declare -F cn_render_noise_section >/dev/null 2>&1; then
      cn_render_noise_section "$dir"
    fi
    return 0
  fi

  # Outage alerts (#2506) sit at the top so a bot that went silent is seen first.
  _render_outage_alerts "$dir"

  printf 'Deterministic report — every figure is computed with `jq`/`awk` from GitHub review data; '
  printf 'no LLM is involved. Bots are identified by their GraphQL App login '
  printf '(`scripts/lib/advisory-review-gate.sh`). Every bot message — review, inline comment, top-level comment, check run — '
  printf 'gets exactly one class (`finding`, `clean`, `refused`, `skipped`, `status` or `unclassified`) from that bot'"'"'s patterns '
  printf '(`scripts/lib/reviewer-message-classes.tsv`) first and the shared rate-limit pattern second. '
  printf 'A PR counts as **reviewed** only when the bot left a `finding` or `clean` message on it; status notices and unclassified messages never count. '
  printf 'Each eligible PR lands in exactly one bucket per bot, so the five PR columns sum to **Total PRs**. '
  printf '_Latency_ = time from PR creation to the bot'"'"'s first `finding` or `clean` message. '
  printf 'Deltas (▲/▼) are vs the prior week and directional only.\n\n'

  # ---- Scorecard table (#2504) ---------------------------------------------
  printf '## Scorecard\n\n'
  printf '| Reviewer | Total PRs | With findings | Clean | Refused | Skipped | No response | Findings raised | Resolved %% | Latency p50 | Latency p95 |\n'
  printf '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n'

  local bot label wf clean refused skipped no_resp findings thr_total thr_res p50 p95
  local f pv pct prev_pct prev_tt prev_tr
  for bot in "${REVIEWER_BOTS[@]}"; do
    label="${REVIEWER_LABELS[$bot]:-$bot}"
    # Pull this bot's aggregates out of the snapshot (0 when absent this week).
    # IFS=tab preserves empty latency fields (a missing percentile must not shift
    # the remaining columns left — that was a field-misalignment bug).
    IFS=$'\t' read -r wf clean refused skipped no_resp findings thr_total thr_res p50 p95 <<<"$(
      jq -r --arg b "$bot" --argjson elig "${eligible:-0}" '
        (.bots?[$b] // {}) as $x
        | [ ($x.with_findings_prs // 0), ($x.clean_prs // 0), ($x.refused_prs // 0),
            ($x.skipped_prs // 0), ($x.no_response_prs // $elig), ($x.findings_raised // 0),
            ($x.threads_total // 0), ($x.threads_resolved // 0),
            (if $x.latency_p50 == null then "" else $x.latency_p50 end),
            (if $x.latency_p95 == null then "" else $x.latency_p95 end) ]
        | @tsv' <<<"$snap"
    )"

    # "<value> <delta>" for each new count column; the delta is blank unless the
    # prior snapshot carries the #2504 fields (schema_version >= 2).
    local -a cells=()
    for f in "with_findings_prs:$wf" "clean_prs:$clean" "refused_prs:$refused" \
             "skipped_prs:$skipped" "no_response_prs:$no_resp" "findings_raised:$findings"; do
      if [[ "${f%%:*}" == findings_raised ]]; then
        pv="$(_prev_v3 "$prev" "$bot" "${f%%:*}")"
      else
        pv="$(_prev_v2 "$prev" "$bot" "${f%%:*}")"
      fi
      cells+=("$(_fmt_int "${f#*:}") $(_delta_arrow "${f#*:}" "$pv")")
    done
    # Resolved % with a percentage-point delta (blank when either week had no threads).
    pct="$(_pct_num "$thr_res" "$thr_total")"
    prev_tt="$(_prev_v2 "$prev" "$bot" threads_total)"
    prev_tr="$(_prev_v2 "$prev" "$bot" threads_resolved)"
    prev_pct=""
    [[ -n "$prev_tt" ]] && prev_pct="$(_pct_num "${prev_tr:-0}" "$prev_tt")"
    if [[ -n "$pct" ]] && [[ -n "$prev_pct" ]]; then
      cells+=("$(_fmt_pct "$thr_res" "$thr_total") $(_delta_arrow "$pct" "$prev_pct")")
    else
      cells+=("$(_fmt_pct "$thr_res" "$thr_total") ")
    fi

    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$label" "$(_fmt_int "$eligible")" "${cells[@]}" "$(_fmt_dur "$p50")" "$(_fmt_dur "$p95")"
  done
  printf '\n'
  printf -- '- **Total PRs** — review-eligible (non-draft) PRs in the window; the denominator each row is measured against.\n'
  printf -- '- **With findings** — PRs where the bot left at least one `finding` message (an inline thread, a review that requests changes, a body that reports issues).\n'
  printf -- '- **Clean** — PRs where the bot reviewed and reported nothing: at least one `clean` message and no `finding`.\n'
  printf -- '- **Refused** — PRs where the bot only declined for quota, rate limit, trial or plan reasons (no finding or clean message).\n'
  printf -- '- **Skipped** — PRs where the bot only reported that it skipped the review because of configuration (for example auto review turned off).\n'
  printf -- '- **No response** — every other eligible PR: the bot never appeared, or left only `status` or `unclassified` messages.\n'
  printf -- '- **Findings raised** — review threads the bot opened plus findings written in its review, comment or check-run bodies. CodeRabbit'"'"'s outside-diff and nitpick items and Codex'"'"'s body suggestions without a matching inline comment always count; any other finding body counts once, and only on a PR where the bot opened no thread (otherwise it summarizes those threads). The Details section splits the two.\n'
  printf -- '- **Resolved %%** — threads the bot opened that are resolved, out of all threads it opened.\n\n'

  # ---- Details (#2504) — the old event counts, verdicts and reactions --------
  printf '## Details\n\n'
  printf '| Reviewer | Reviews | ✅ / 🔄 | Refusal events | 👍 / 👎 | Status messages | Unclassified messages | Findings: threads / bodies |\n'
  printf '|---|---:|:--:|---:|:--:|---:|---:|:--:|\n'
  local reviews refusal_events approved changes_req up down st_ev uc_ev f_thr f_body prev_reviews prev_refusals
  for bot in "${REVIEWER_BOTS[@]}"; do
    label="${REVIEWER_LABELS[$bot]:-$bot}"
    IFS=$'\t' read -r reviews refusal_events approved changes_req up down st_ev uc_ev f_thr f_body <<<"$(
      jq -r --arg b "$bot" '
        (.bots?[$b] // {}) as $x
        | [ ($x.reviews // 0), ($x.refusal_events // 0), ($x.approved // 0), ($x.changes_req // 0),
            ($x.thumbs_up // 0), ($x.thumbs_down // 0), ($x.status_events // 0),
            ($x.unclassified_events // 0), ($x.findings_threads // 0), ($x.findings_body // 0) ]
        | @tsv' <<<"$snap"
    )"
    prev_reviews="$(_prev "$prev" "$bot" reviews)"
    prev_refusals="$(_prev "$prev" "$bot" refusal_events)"
    printf '| %s | %s %s | %s / %s | %s %s | %s / %s | %s | %s | %s / %s |\n' \
      "$label" \
      "$(_fmt_int "$reviews")" "$(_delta_arrow "$reviews" "$prev_reviews")" \
      "$(_fmt_int "$approved")" "$(_fmt_int "$changes_req")" \
      "$(_fmt_int "$refusal_events")" "$(_delta_arrow "$refusal_events" "$prev_refusals")" \
      "$(_fmt_int "$up")" "$(_fmt_int "$down")" \
      "$(_fmt_int "$st_ev")" "$(_fmt_int "$uc_ev")" \
      "$(_fmt_int "$f_thr")" "$(_fmt_int "$f_body")"
  done
  printf '\n'
  printf -- '- **Reviews** — formal reviews the bot submitted, **each occurrence** (a PR re-reviewed on 5 commits = 5), leaving out refusals, skips and status notices. A bot that posts no formal review but delivers its verdict as a comment (e.g. SonarCloud'"'"'s quality-gate comment) has its `finding` / `clean` comments counted instead.\n'
  printf -- '- **✅ / 🔄** — of those reviews, how many were APPROVED / CHANGES_REQUESTED (comment-only responses carry no verdict).\n'
  printf -- '- **Refusal events** — every `refused` message, each occurrence.\n'
  printf -- '- **👍 / 👎** — reactions on the bot'"'"'s inline comments.\n'
  printf -- '- **Status / Unclassified messages** — message counts; neither ever makes a PR count as reviewed.\n'
  printf -- '- **Findings: threads / bodies** — the two parts of **Findings raised**: review threads the bot opened, and findings counted from its review, comment or check-run bodies.\n\n'

  _render_quota_timing "$dir"

  _render_unclassified_samples "$dir"

  # ---- Coverage matrix (#2506) ----------------------------------------------
  _render_coverage_matrix "$dir"

  # ---- Coverage / overlap --------------------------------------------------
  # Only bots that actually REVIEWED (a finding or clean message) count toward
  # overlap — a status notice or refusal is not coverage (#2504).
  local co_review multi_bot
  co_review="$(jq -s '
    def is_dependabot: test("^dependabot(-preview)?(\\[bot\\])?$"; "i");
    (reduce (.[] | select(.kind=="pr" and .draft == false and ((.author // "") | is_dependabot | not))) as $p ({}; .[$p.pr] = true)) as $elig
    | [ .[] | select(.kind=="bot_pr" and (.real_responses // 0) > 0 and ($elig[.pr] // false)) ] | group_by(.pr)
    | map(select(length >= 2)) | length
  ' "$dir"/*.jsonl 2>/dev/null || echo 0)"
  multi_bot="$(_fmt_pct "$co_review" "$eligible")"
  printf '## Coverage overlap\n\n'
  printf -- '- **PRs reviewed by ≥2 bots:** %s of %s eligible (%s)\n' \
    "$(_fmt_int "$co_review")" "$(_fmt_int "$eligible")" "$multi_bot"
  printf -- '- Higher overlap = more redundant coverage; lower = reviewers are specializing or missing PRs.\n\n'

  # ---- Agent comment noise (#1411) -----------------------------------------
  # The no-action share of OUR automation's own comments — the net-new noise
  # metric. Same code path produces the pre-rollout baseline and every after-run.
  if declare -F cn_render_noise_section >/dev/null 2>&1; then
    cn_render_noise_section "$dir"
  fi

  # ---- pr-review miss rate (#1596) -----------------------------------------
  # The false-negative signal: accepted defects an advisory bot found on a PR
  # pr-review had already approved, overall and per third-party reviewer.
  if declare -F pr_review_render_miss_section >/dev/null 2>&1; then
    pr_review_render_miss_section "$dir"
  fi

  # ---- Known gaps ----------------------------------------------------------
  printf '## Known gaps\n\n'
  printf -- '- **Cost is not measured here.** These reviewers are external SaaS GitHub Apps and emit no token-usage artifacts, so per-review $ cost is not observable from our side. For our own Claude reviewer'"'"'s spend, see the [Token Cost Observatory](../../issues?q=is%%3Aissue+label%%3Atoken-report).\n'
  printf -- '- **Comment usefulness / false-positive rate** for the third-party reviewers requires judgment and is intentionally out of this deterministic report (a separate, human-approved LLM add-on). Note the **Agent comment noise** section above is a different, deterministic metric — it scores OUR automation'"'"'s no-action share from the markers each comment already carries.\n'
  printf -- '- **Latency baseline** is PR-creation time (v1). A refinement to last-human-push is tracked for v2.\n\n'
  printf -- '_Source: `scripts/reviewer_report.sh` · `.github/workflows/reviewer-report.yml` — no LLM in this pipeline._\n'

  # ---- Persist this week's snapshot for next week's WoW diff ----------------
  if [ -n "${REVIEWER_SNAPSHOT_OUT:-}" ]; then
    printf '%s\n' "$snap" > "$REVIEWER_SNAPSHOT_OUT"
  fi
}

# ---------------------------------------------------------------------------
# Network I/O (main)
# ---------------------------------------------------------------------------

GH_OP_TIMEOUT="${GH_OP_TIMEOUT:-60}"
COLLECT_CONCURRENCY="${COLLECT_CONCURRENCY:-8}"
# PR_PAGE_SIZE (#1908): PRs requested per GraphQL page. Kept deliberately SMALL
# (10, was 25) because the verified undercount root cause was busy repos exceeding
# GitHub's GraphQL resource limit on page 1 and being silently dropped entirely.
# A lighter page is the fix; do NOT raise this or the nested connections back up.
PR_PAGE_SIZE="${PR_PAGE_SIZE:-10}"
# On a resource-limit/timeout error the fetch retries with a HALVED page size and
# backoff up to this many attempts before the repo is recorded as un-collected.
PR_FETCH_MAX_ATTEMPTS="${PR_FETCH_MAX_ATTEMPTS:-4}"
# Safety cap on pages per repo. Raised (was 20) to keep total coverage steady now
# that each page holds fewer PRs; the UPDATED_AT early-stop ends most repos sooner.
MAX_PR_PAGES="${MAX_PR_PAGES:-50}"

# _gh_timeout <gh-args...> — run `gh` under a per-call timeout so one hung request
# cannot stall the run. gh is invoked via `bash -c` so an exported shell-function
# stub (unit tests) still resolves under `timeout` (which only execs binaries).
_gh_timeout() {
  if [ "${GH_OP_TIMEOUT:-0}" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout "${GH_OP_TIMEOUT}" bash -c 'gh "$@"' _ "$@"
  else
    gh "$@"
  fi
}

# GraphQL query: one repo's PRs (newest first) with reviews, threads, comments.
# $prFirst is the per-page PR count (small, and halved on retry, see PR_PAGE_SIZE).
# headRefOid feeds the separate per-PR check-run fetch (#1908) for check-run reporters.
# Review ids and inline-comment path / lines let Codex body suggestions be matched to
# the inline comments of the same review (#2527).
_PR_QUERY='
query($owner:String!, $name:String!, $cursor:String, $prFirst:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequests(first: $prFirst, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        url number createdAt updatedAt mergedAt isDraft headRefOid
        author { login }
        reviews(first: 50) { nodes { id author { login } state submittedAt bodyText } }
        reviewThreads(first: 50) {
          nodes {
            isResolved isOutdated
            comments(first: 20) {
              nodes {
                author { login } createdAt bodyText path
                line originalLine startLine originalStartLine pullRequestReview { id }
                reactionGroups { content users { totalCount } }
              }
            }
          }
        }
        comments(first: 50) { nodes { author { login } createdAt bodyText } }
      }
    }
  }
}'

# _collect_check_runs_for_page <owner> <name> <graphql_resp> [out_jsonl] — echo a
# JSON object mapping each in-window PR url → [ {bot,status,conclusion,summary,completed_at} ]
# for the CHECK-RUN reporters (#1908). One lightweight REST call per in-window PR
# head commit (`/commits/{sha}/check-runs`), filtered to the configured names — a
# separate, cheap fetch that does NOT add weight to the (resource-limited) PR page
# query. Echoes `{}` when there are no reporters or no in-window PRs. Best-effort:
# a failed per-PR fetch is skipped, never fatal — but when <out_jsonl> is given a
# {kind:"check_run_error"} diagnostic is appended so the miss is surfaced in
# Collection health, never silent (#1908): a dropped fetch could turn a check-run
# reporter's clean pass into a false "No response".
_collect_check_runs_for_page() {
  local owner="$1" name="$2" resp="$3" out="${4:-}"
  local reporters_json="${REVIEWER_CHECK_RUN_JSON:-"{}"}"
  [ "$reporters_json" = "{}" ] && { printf '{}'; return 0; }

  local prs
  prs="$(jq -c --arg cutoff "$CUTOFF" '
    [ .data?.repository?.pullRequests?.nodes[]?
      | select(.updatedAt >= $cutoff)
      | {url, sha: (.headRefOid // "")} | select(.sha != "") ]' <<<"$resp" 2>/dev/null || printf '[]')"
  { [ -z "$prs" ] || [ "$prs" = "[]" ]; } && { printf '{}'; return 0; }

  # Stream the (url, sha) pairs as TSV from a SINGLE jq, then loop — no per-row jq
  # to read fields. @tsv also escapes embedded newlines, hardening against a
  # crafted PR URL splitting a row. `|| [ -n "$url" ]` processes a final row with
  # no trailing newline.
  local acc='{}' url sha
  while IFS=$'\t' read -r url sha || [ -n "$url" ]; do
    [ -z "$url" ] && continue
    local cr_resp matched
    # `--paginate` follows Link headers so a reporter's run past the first 100 check
    # runs is still seen — reading only page 1 would falsely report "No response"
    # when the configured run sorts after the 100th (#1908). Assign first, then test,
    # so a fetch failure under `set -e` is a clean skip, not a swallowed error.
    if ! cr_resp="$(_gh_timeout api --paginate "repos/${owner}/${name}/commits/${sha}/check-runs?per_page=100" 2>/dev/null)" \
         || [ -z "$cr_resp" ]; then
      # Fetch failed: without a record this PR's check-run reporters are silently absent,
      # so a Graphite clean pass would miscount as "No response". Surface it (#1908).
      [ -n "$out" ] && jq -cn --arg repo "${owner}/${name}" --arg pr "$url" \
        '{kind:"check_run_error", repo:$repo, pr:$pr, reason:"check-run REST fetch failed"}' \
        >> "$out" 2>/dev/null || true
      continue
    fi
    # `-s` slurps the (possibly multi-page) `--paginate` object stream into an array;
    # `.[].check_runs[]?` flattens runs across every page.
    matched="$(jq -c -s --argjson names "$reporters_json" '
      ($names | to_entries | map({(.value): .key}) | add) as $byname
      | [ .[].check_runs[]?
          | select(($byname[.name] // null) != null)
          | { bot: $byname[.name], status: .status, conclusion: .conclusion,
              summary: (.output.summary // ""), completed_at: .completed_at } ]' \
      <<<"$cr_resp" 2>/dev/null || printf '[]')"
    { [ -z "$matched" ] || [ "$matched" = "[]" ]; } && continue
    acc="$(jq -c --arg url "$url" --argjson m "$matched" '. + {($url): $m}' <<<"$acc" 2>/dev/null || printf '%s' "$acc")"
  done < <(jq -r '.[] | [.url, .sha] | @tsv' <<<"$prs" 2>/dev/null || true)
  printf '%s' "$acc"
}

# _collect_one_repo <repo> — GraphQL-paginate one repo's recently-updated PRs,
# stopping once a page's PRs predate CUTOFF (PRs are ordered by UPDATED_AT desc),
# and append normalized JSONL records to a unique file in COLLECT_JSONL_DIR.
# Always exits 0: a repo that fails even after retries degrades to a {kind:
# "collect_error"} record (surfaced prominently in the report, #1908), never an
# aborted run.
_collect_one_repo() {
  local repo="$1" owner name cursor="" page=0 out
  owner="${repo%%/*}"; name="${repo##*/}"
  out="$(mktemp "${COLLECT_JSONL_DIR}/repo.XXXXXX.jsonl")" || return 0

  local bots_json
  bots_json="$(printf '%s\n' "${REVIEWER_BOTS[@]}" | jq -R . | jq -sc .)"

  while :; do
    page=$((page + 1))
    if [ "$page" -gt "${MAX_PR_PAGES}" ]; then
      # The MAX_PR_PAGES cap stopped this repo before its in-window PRs were exhausted
      # (the bottom-of-loop stop did not fire), so later PRs are dropped. Emit a
      # truncation record so Collection health marks the scorecard a floor, never silent (#1908).
      jq -cn --arg repo "$repo" --arg cap "$MAX_PR_PAGES" \
        '{kind:"truncation", repo:$repo, pr:"(pagination)", connection:"pullRequests", reason:"MAX_PR_PAGES (\($cap)) reached"}' \
        >> "$out" 2>/dev/null || true
      break
    fi

    # Fetch this page, retrying with a HALVED page size + backoff on a resource-limit
    # / timeout error before giving up (#1908). A GraphQL resource-limit error can
    # arrive as a non-zero exit OR as an HTTP-200 body carrying an `errors` array —
    # possibly ALONGSIDE partial `data`. Treat ANY of these as a failure to retry: a
    # page is "fetched" only when it has non-null pullRequests AND no `errors`, so a
    # partial page is never counted as complete. Assign the command substitution
    # first, then test, so a non-zero exit under `set -e` is not swallowed.
    local resp="" this_first="${PR_PAGE_SIZE}" attempt=0 fetched=0
    while :; do
      attempt=$((attempt + 1))
      local gql_args
      gql_args=(api graphql -f query="$_PR_QUERY" -F owner="$owner" -F name="$name" -F prFirst="$this_first")
      [ -n "$cursor" ] && gql_args+=(-F cursor="$cursor")
      resp="$(_gh_timeout "${gql_args[@]}" 2>/dev/null || true)"
      if [ -n "$resp" ] \
           && jq -e '((.errors // []) | length) == 0 and (.data?.repository?.pullRequests != null)' <<<"$resp" >/dev/null 2>&1; then
        fetched=1; break
      fi
      if [ "$attempt" -ge "${PR_FETCH_MAX_ATTEMPTS}" ] || [ "$this_first" -le 1 ]; then
        break
      fi
      this_first=$((this_first / 2)); [ "$this_first" -lt 1 ] && this_first=1
      sleep "$(( attempt < 5 ? attempt : 5 ))"
    done
    if [ "$fetched" -ne 1 ]; then
      echo "WARN: GraphQL query for ${repo} (page ${page}) failed after ${attempt} attempts — repo NOT collected (#1908)" >&2
      jq -cn --arg repo "$repo" \
        --arg reason "page-${page} GraphQL failure after ${attempt} attempts (resource-limit/timeout) — halved to first:${this_first}" \
        '{kind:"collect_error", repo:$repo, reason:$reason}' >> "$out" 2>/dev/null || true
      break
    fi

    # Emit normalized records for PRs inside the window; count how many nodes were
    # in-window so we can stop paginating once a full page is older than CUTOFF.
    local in_window
    in_window="$(jq -r --arg cutoff "$CUTOFF" '
      [ .data?.repository?.pullRequests?.nodes[]? | select(.updatedAt >= $cutoff) ] | length
    ' <<<"$resp" 2>/dev/null || echo 0)"

    # Check-run reviews (#1908): fetch each in-window PR's head-commit check runs for
    # the configured reporters and inject them as ._checkRuns so normalization can
    # count a clean pass (check run only, no PR review) as a real response.
    local crmap='{}'
    if [ "${REVIEWER_CHECK_RUN_JSON:-"{}"}" != "{}" ]; then
      crmap="$(_collect_check_runs_for_page "$owner" "$name" "$resp" "$out")" || crmap='{}'
    fi

    jq -c --arg repo "$repo" --argjson bots "$bots_json" --arg rl "$RATE_LIMIT_RE" --arg cutoff "$CUTOFF" --argjson crmap "$crmap" \
      ".data?.repository?.pullRequests?.nodes[]? | select(.updatedAt >= \$cutoff) | (. + {\"_checkRuns\": (\$crmap[.url] // [])}) | ${_NORMALIZE_JQ}" \
      <<<"$resp" >> "$out" 2>/dev/null || true

    # Truncation surfacing (#1908): a nested connection that hit its GraphQL fetch
    # cap (≥50) may undercount a bot's reviews/comments on that PR. Emit one
    # {kind:"truncation"} record per capped connection so the report states it
    # explicitly — truncation must NEVER be silent (the old code only WARNed to
    # stderr, and only when the noise pass was enabled).
    jq -c --arg repo "$repo" --arg cutoff "$CUTOFF" '
      .data?.repository?.pullRequests?.nodes[]? | select(.updatedAt >= $cutoff) | . as $pr
      | ( if ((.reviews?.nodes // []) | length) >= 50 then {kind:"truncation",repo:$repo,pr:($pr.url),connection:"reviews"} else empty end),
        ( if ((.comments?.nodes // []) | length) >= 50 then {kind:"truncation",repo:$repo,pr:($pr.url),connection:"comments"} else empty end),
        ( if ((.reviewThreads?.nodes // []) | length) >= 50 then {kind:"truncation",repo:$repo,pr:($pr.url),connection:"reviewThreads"} else empty end),
        # Each reviewThread'"'"'s comments are fetched only up to 20 (comments(first: 20)); a
        # thread that exceeds that undercounts inline comments / thread metrics, so surface it too.
        ( if any((.reviewThreads?.nodes // [])[]?; ((.comments?.nodes // []) | length) >= 20) then {kind:"truncation",repo:$repo,pr:($pr.url),connection:"reviewThreads.comments"} else empty end)
    ' <<<"$resp" >> "$out" 2>/dev/null || true

    # Additive no-action-noise pass (#1411): emit one agent_comment record per
    # marker-bearing comment/review on each in-window PR, regardless of author
    # (our agents commit as human logins). A distinct record kind, so it never
    # perturbs the bot scorecard aggregation above.
    if [ -n "${CN_AGENT_COMMENT_JQ:-}" ] && [ -n "${CN_MARKER_RE:-}" ] && [ -n "${CN_NOACTION_RE:-}" ]; then
      jq -c --arg repo "$repo" --arg mark "$CN_MARKER_RE" --arg noact "$CN_NOACTION_RE" --arg cutoff "$CUTOFF" \
        '.data?.repository?.pullRequests?.nodes[]? | select(.updatedAt >= $cutoff) | '"${CN_AGENT_COMMENT_JQ}" \
        <<<"$resp" >> "$out" 2>/dev/null || true
      # Warn when per-PR arrays hit the GraphQL fetch cap (≥50), as truncated arrays
      # produce an incomplete noise baseline (#1411).
      jq -r --arg repo "$repo" '
        .data?.repository?.pullRequests?.nodes[]? |
        [
          if ((.reviews?.nodes // []) | length) >= 50 then "reviews" else empty end,
          if ((.comments?.nodes // []) | length) >= 50 then "comments" else empty end,
          if ((.reviewThreads?.nodes // []) | length) >= 50 then "reviewThreads" else empty end
        ] as $capped |
        if ($capped | length) > 0 then
          "WARN: \($repo) PR \(.url // "unknown") hit GraphQL cap on: \($capped | join(", ")) — noise baseline may be incomplete"
        else empty end
      ' <<<"$resp" >&2 2>/dev/null || true
    fi

    # Additive miss-rate pass (#1596): emit one {kind:"miss_pr"} record per in-window
    # PR — the deterministic false-negative signal (accepted advisory-bot findings
    # after a pr-review approval, plus caught/partial-evidence counts). A distinct
    # record kind, so it never perturbs the bot scorecard aggregation above.
    if [ -n "${PR_REVIEW_MISS_COLLECT_JQ:-}" ] && [ -n "${_MISS_JQ_DEFS:-}" ]; then
      jq -c --arg repo "$repo" --argjson bots "$bots_json" \
        --arg approver "${PR_REVIEW_APPROVER:-donpetry-bot}" \
        --arg approval_re "${PR_REVIEW_APPROVAL_RE:-}" --arg partial_re "${PR_REVIEW_PARTIAL_RE:-}" \
        --arg cutoff "$CUTOFF" \
        "${_MISS_JQ_DEFS} .data?.repository?.pullRequests?.nodes[]? | select(.updatedAt >= \$cutoff) | ${PR_REVIEW_MISS_COLLECT_JQ}" \
        <<<"$resp" >> "$out" 2>/dev/null || true
    fi

    # Stop when this page had no in-window PRs, or there are no more pages.
    local has_next end_cursor
    has_next="$(jq -r '.data?.repository?.pullRequests?.pageInfo?.hasNextPage // false' <<<"$resp" 2>/dev/null || echo false)"
    end_cursor="$(jq -r '.data?.repository?.pullRequests?.pageInfo?.endCursor // empty' <<<"$resp" 2>/dev/null || echo '')"
    { [ "$in_window" -eq 0 ] || [ "$has_next" != "true" ] || [ -z "$end_cursor" ]; } && break
    cursor="$end_cursor"
  done
}

# _window_cutoff — the window start, LOOKBACK_DAYS ago, as an ISO-8601 UTC timestamp.
_window_cutoff() {
  date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ
}

# collect_org_reviews <jsonl_dir>  (stdout: "<repo_count>")
# Discover non-archived repos, then sweep each one's recent PRs in bounded parallel.
collect_org_reviews() {
  local jsonl_dir="$1"
  mkdir -p "$jsonl_dir"

  local repos_raw
  if ! repos_raw="$(_gh_timeout api "orgs/${ORG}/repos?per_page=100&type=all" --paginate \
    --jq '.[] | select(.archived == false) | .full_name')"; then
    echo "ERROR: org repo discovery for '${ORG}' failed — verify GH_TOKEN has org read access." >&2
    return 1
  fi
  [ -n "$repos_raw" ] || { echo "0"; return 0; }

  local repo_count
  repo_count="$(printf '%s\n' "$repos_raw" | awk 'NF{c++} END{print c+0}')"

  [ -n "${CUTOFF:-}" ] || CUTOFF="$(_window_cutoff)"
  export CUTOFF COLLECT_JSONL_DIR="$jsonl_dir" GH_OP_TIMEOUT MAX_PR_PAGES PR_PAGE_SIZE PR_FETCH_MAX_ATTEMPTS
  # shellcheck disable=SC2090  # jq/GraphQL program strings: literal content is intended
  export _PR_QUERY _NORMALIZE_JQ RATE_LIMIT_RE
  # Check-run reporters (#1908) — serialize the login→check-run-name map to JSON so
  # each worker subshell (associative arrays cannot cross the process boundary) can
  # fetch check runs for the configured reporters. `{}` when none are registered.
  local _crk
  REVIEWER_CHECK_RUN_JSON='{}'
  for _crk in "${!REVIEWER_CHECK_RUN_NAMES[@]}"; do
    REVIEWER_CHECK_RUN_JSON="$(jq -c --arg k "$_crk" --arg v "${REVIEWER_CHECK_RUN_NAMES[$_crk]}" \
      '. + {($k): $v}' <<<"$REVIEWER_CHECK_RUN_JSON")"
  done
  export REVIEWER_CHECK_RUN_JSON
  # No-action noise classifier (#1411) — exported so each worker subshell can run
  # the second (agent_comment) collection pass. Absent in a stripped lib env.
  export CN_AGENT_COMMENT_JQ="${CN_AGENT_COMMENT_JQ:-}" CN_MARKER_RE="${CN_MARKER_RE:-}" CN_NOACTION_RE="${CN_NOACTION_RE:-}"
  # Miss-rate collection pass (#1596) — exported so each worker subshell can run the
  # third (miss_pr) collection pass. Absent in a stripped lib env.
  # shellcheck disable=SC2090
  export _MISS_JQ_DEFS="${_MISS_JQ_DEFS:-}" PR_REVIEW_MISS_COLLECT_JQ="${PR_REVIEW_MISS_COLLECT_JQ:-}"
  export PR_REVIEW_APPROVER="${PR_REVIEW_APPROVER:-donpetry-bot}" PR_REVIEW_APPROVAL_RE="${PR_REVIEW_APPROVAL_RE:-}" PR_REVIEW_PARTIAL_RE="${PR_REVIEW_PARTIAL_RE:-}"
  # REVIEWER_BOTS is a plain array; export as newline string the workers re-split.
  REVIEWER_BOTS_STR="$(printf '%s\n' "${REVIEWER_BOTS[@]}")"
  export REVIEWER_BOTS_STR
  export -f _collect_one_repo _collect_check_runs_for_page _gh_timeout

  printf '%s\n' "$repos_raw" \
    | xargs -P "$COLLECT_CONCURRENCY" -I {} \
        bash -c '
          set -o pipefail
          # Reconstitute the bot array inside the worker subshell from the exported
          # newline-delimited string (arrays cannot cross the process boundary).
          mapfile -t REVIEWER_BOTS <<< "$REVIEWER_BOTS_STR"
          _collect_one_repo "$1"
        ' _ {} \
    || true

  echo "${repo_count}"
}

# _fetch_prev_snapshot <dest_path> — download the most recent PRIOR
# reviewer-report-state artifact from SNAPSHOT_REPO into <dest_path>. Best-effort:
# a miss (first-ever run, expired artifact) leaves <dest_path> absent so the report
# simply omits WoW deltas. Never aborts the run.
_fetch_prev_snapshot() {
  local dest="$1" id
  command -v unzip >/dev/null 2>&1 || { echo "WARN: unzip unavailable — skipping WoW deltas" >&2; return 0; }
  id="$(_gh_timeout api "repos/${SNAPSHOT_REPO}/actions/artifacts?per_page=100" --paginate 2>/dev/null \
    | jq -r '[.artifacts[] | select(.name == "reviewer-report-state") | select(.expired == false)]
             | sort_by(.created_at) | last | .id // empty' 2>/dev/null)" || return 0
  [ -n "$id" ] || { echo "WARN: no prior snapshot artifact — WoW deltas omitted (first run?)" >&2; return 0; }
  local tmpzip tmpdir
  tmpzip="$(mktemp)"; tmpdir="$(mktemp -d)"
  if _gh_timeout api "repos/${SNAPSHOT_REPO}/actions/artifacts/${id}/zip" > "$tmpzip" 2>/dev/null \
     && unzip -q -o "$tmpzip" -d "$tmpdir" 2>/dev/null; then
    local f
    f="$(find "$tmpdir" -type f -name '*.json' 2>/dev/null)" || true
    f="${f%%$'\n'*}"
    [ -n "$f" ] && cp "$f" "$dest"
  fi
  rm -rf "$tmpzip" "$tmpdir"
}

main() {
  local jsonl_dir repo_count generated_at report prev_snap
  jsonl_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$jsonl_dir'" EXIT

  # Compute the window start once, here: collect_org_reviews runs in a command
  # substitution, so a CUTOFF it set would not reach the renderer, which needs it to
  # tell PRs opened in the window from older PRs updated in it (#2506).
  CUTOFF="${CUTOFF:-$(_window_cutoff)}"
  export CUTOFF

  echo "Collecting PR review activity across ${ORG} (last ${LOOKBACK_DAYS} days)..." >&2
  repo_count="$(collect_org_reviews "$jsonl_dir")"
  generated_at="$(date -u +%Y-%m-%d 2>/dev/null || echo '')"

  # Week-over-week: fetch the prior snapshot (best-effort) unless one is supplied.
  if [ -z "${REVIEWER_PREV_SNAPSHOT:-}" ]; then
    prev_snap="$jsonl_dir/prev_snapshot.json"
    _fetch_prev_snapshot "$prev_snap" || true
    [ -f "$prev_snap" ] && export REVIEWER_PREV_SNAPSHOT="$prev_snap"
  fi

  report="$(render_reviewer_report "$jsonl_dir" "$LOOKBACK_DAYS" "$repo_count" "$generated_at")"

  printf '%s\n' "$report"
  if [ -n "${REVIEWER_REPORT_OUT:-}" ]; then
    printf '%s\n' "$report" > "$REVIEWER_REPORT_OUT"
  fi
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
