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
# per-PR REST. Bot identity comes from the shared advisory-review-gate registry;
# rate-limit / out-of-quota notices are detected with its shared body pattern.
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
if [ -f "$_here/lib/advisory-review-gate.sh" ]; then
  # shellcheck source=scripts/lib/advisory-review-gate.sh
  source "$_here/lib/advisory-review-gate.sh"
fi

# No-action agent-comment noise classifier (#1411). Provides CN_AGENT_COMMENT_JQ
# (the shared jq pre-classifier applied during collection) and the pure
# cn_render_noise_section renderer. Derive its two decision patterns once so the
# collection workers and the renderer agree by construction.
if [ -f "$_here/lib/comment-noise.sh" ]; then
  # shellcheck source=scripts/lib/comment-noise.sh
  source "$_here/lib/comment-noise.sh"
  CN_MARKER_RE="$(cn_marker_pattern)"
  CN_NOACTION_RE="$(cn_no_action_pattern)"
fi

# Deterministic false-NEGATIVE metric (#1596): accepted findings a trusted advisory
# bot raised on a PR pr-review had already approved. Provides _MISS_JQ_DEFS +
# PR_REVIEW_MISS_COLLECT_JQ (the additive collection pass) and the pure
# pr_review_render_miss_section renderer. Reuses REVIEWER_BOTS as its trusted set.
if [ -f "$_here/lib/pr-review-miss-rate.sh" ]; then
  # shellcheck source=scripts/lib/pr-review-miss-rate.sh
  source "$_here/lib/pr-review-miss-rate.sh"
fi

# The reviewers this scorecard tracks. RATE_LIMIT_NOTICE_BOTS (from the gate) is
# exactly our target set — the gate bots PLUS coderabbitai — so we reuse it as
# the canonical login list rather than re-declaring it (#drift-guard). If the
# library is unavailable (e.g. a stripped test env), fall back to a literal list.
if declare -p RATE_LIMIT_NOTICE_BOTS >/dev/null 2>&1 && [ "${#RATE_LIMIT_NOTICE_BOTS[@]}" -gt 0 ]; then
  REVIEWER_BOTS=("${RATE_LIMIT_NOTICE_BOTS[@]}")
else
  REVIEWER_BOTS=(gemini-code-assist copilot-pull-request-reviewer sonarqubecloud chatgpt-codex-connector coderabbitai qodo-code-review codeant-ai graphite-app)
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
)

# Rate-limit / out-of-quota body pattern — reuse the gate's if present.
if declare -F _advisory_rate_limit_pattern >/dev/null 2>&1; then
  RATE_LIMIT_RE="$(_advisory_rate_limit_pattern)"
else
  RATE_LIMIT_RE='usage limit|rate[-_ ]?limit|too many requests|quota (exceeded|reached|exhausted)|out of (quota|credits|tokens|requests)|limit (reached|exceeded|exhausted)|(reached|exceeded|hit) (the |your )?(usage |rate |daily |monthly )?limit|used up its prepaid credits|Qodo.{0,40}(monthly|usage|PR|review) limit|CodeAnt.{0,40}(monthly|trial|usage) limit'
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
  [ -z "$prev" ] && { printf ''; return 0; }
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
#   {kind:"bot_pr", repo, pr, bot, created, first_at, latency_s,
#      reviews, approved, changes_req, commented, dismissed, rate_limited,
#      inline_comments, threads_total, threads_resolved, threads_outdated,
#      thumbs_up, thumbs_down}                                     (participation)
# Args: --arg repo, --argjson bots (login array), --arg rl (rate-limit regex).
# A "bot_pr" record is emitted only for a bot that actually touched the PR.
# shellcheck disable=SC2089  # this is a jq program; embedded quotes are meant to be literal
_NORMALIZE_JQ='
  def is_bot($login): ($login != null) and ($login | ascii_downcase) as $l
    | ($bots | map(ascii_downcase) | index($l)) != null;
  # All submissions (reviews + inline thread comments + issue comments) by tracked
  # bots, tagged with source so we can count verdicts vs comments separately.
  . as $pr
  | ([ (.reviews.nodes // [])[]
       | select(.author.login as $a | is_bot($a))
       | { bot: (.author.login|ascii_downcase), at: .submittedAt,
           kind: "review", state: (.state // "COMMENTED"),
           body: (.bodyText // ""), reactions: 0, resolved: false, outdated: false } ]
    + [ (.reviewThreads.nodes // [])[] as $t
        | ($t.comments.nodes // [])[]
        | select(.author.login as $a | is_bot($a))
        | { bot: (.author.login|ascii_downcase), at: .createdAt,
            kind: "inline", state: "COMMENTED", body: (.bodyText // ""),
            reactions_up: ([ (.reactionGroups // [])[] | select(.content=="THUMBS_UP") | .users.totalCount ] | add // 0),
            reactions_down: ([ (.reactionGroups // [])[] | select(.content=="THUMBS_DOWN") | .users.totalCount ] | add // 0),
            resolved: ($t.isResolved // false), outdated: ($t.isOutdated // false) } ]
    + [ (.comments.nodes // [])[]
        | select(.author.login as $a | is_bot($a))
        | { bot: (.author.login|ascii_downcase), at: .createdAt,
            kind: "issue", state: "COMMENTED", body: (.bodyText // ""),
            reactions_up: 0, reactions_down: 0, resolved: false, outdated: false } ]
    ) as $subs
  | ( { kind: "pr", repo: $repo, pr: ($pr.url),
        created: $pr.createdAt, merged: ($pr.mergedAt // null),
        draft: ($pr.isDraft // false), author: ($pr.author.login // "") } ),
    ( $subs | group_by(.bot)[] as $grp
      # Tag each submission as a refusal (an out-of-quota / rate-limit notice) vs a
      # real response. A PR counts as "reviewed" if the bot gave ANY real response,
      # even alongside a rate-limit notice; it counts as "refused" only when the
      # bot'"'"'s SOLE action on the PR was to decline. This is the key correctness
      # fix over the old "any rate-limit text present" flag.
      | ($grp | map(. + {refusal: ((.body // "") | test($rl; "i"))})) as $mine
      | ($mine | map(select(.refusal | not))) as $real
      | ($mine | map(select(.refusal)))       as $refd
      | ($real | map(.at) | min) as $first_real
      | ($real | map(select(.kind=="review")) | length) as $rev_events
      | { kind: "bot_pr", repo: $repo, pr: ($pr.url),
          bot: $grp[0].bot, created: $pr.createdAt,
          real_responses: ($real | length),
          refusals:       ($refd | length),
          # Latency = time to first REAL response (null when the bot only refused,
          # so refusals never pollute the latency percentiles).
          latency_s: (if ($real | length) == 0 then null
                      else (($first_real | fromdateiso8601) - ($pr.createdAt | fromdateiso8601)) end),
          # Reviews = formal review submissions. A bot that posts NO formal review
          # but delivers its verdict as a top-level comment (e.g. SonarCloud'"'"'s
          # quality-gate comment) has that comment counted as its review, so its
          # work is not invisible. Bots that DO submit reviews are unaffected, so
          # their extra summary comments are never double-counted. Refusals are
          # already excluded ($real holds only non-refusal responses).
          reviews:      (if $rev_events > 0 then $rev_events
                         else ($real | map(select(.kind=="issue")) | length) end),
          approved:     ($real | map(select(.kind=="review" and .state=="APPROVED")) | length),
          changes_req:  ($real | map(select(.kind=="review" and .state=="CHANGES_REQUESTED")) | length),
          inline_comments:  ($real | map(select(.kind=="inline")) | length),
          threads_total:    ($real | map(select(.kind=="inline")) | length),
          threads_resolved: ($real | map(select(.kind=="inline" and .resolved)) | length),
          thumbs_up:   ($real | map(.reactions_up // 0)   | add // 0),
          thumbs_down: ($real | map(.reactions_down // 0) | add // 0) } )
'

# aggregate_snapshot <jsonl_dir> — PURE. Reads normalized JSONL and emits the
# per-bot headline-metric snapshot as compact JSON (also the WoW artifact payload).
# Every eligible (non-draft) PR falls into exactly one bucket PER BOT, and the three
# buckets sum to eligible_prs:
#   reviewed_prs     — the bot gave a real review/comment
#   refused_prs      — the bot responded ONLY to decline (rate-limited / out of quota)
#   no_response_prs  — the bot never appeared on the PR
# reviews / refusal_events are EVENT counts (each submission counted, so a PR
# re-reviewed across N commits contributes N reviews); the *_prs fields are PR
# counts. reviewed_prs + refused_prs + no_response_prs == eligible_prs.
#   { "eligible_prs": N, "total_prs": N,
#     "bots": { "<login>": { reviewed_prs, refused_prs, no_response_prs, engaged_prs,
#               reviews, refusal_events, approved, changes_req, inline_comments,
#               threads_total, threads_resolved, thumbs_up, thumbs_down,
#               latency_p50, latency_p95 } , ... } }
aggregate_snapshot() {
  local dir="$1"
  local files=("$dir"/*.jsonl)
  [ -e "${files[0]}" ] || { echo '{"eligible_prs":0,"total_prs":0,"bots":{}}'; return 0; }
  jq -s '
    (map(select(.kind=="pr"))) as $prs
    | (map(select(.kind=="bot_pr"))) as $bp
    | ($prs | length) as $total
    # Bucket over ELIGIBLE (non-draft) PRs only, so the three buckets sum to eligible.
    | (reduce ($prs[] | select(.draft == false)) as $p ({}; .[$p.pr] = true)) as $elig_map
    | ($elig_map | length) as $eligible
    | ($bp | map(select($elig_map[.pr]))) as $bpe
    | ($bpe | group_by(.bot) | map(
        (.[0].bot) as $bot
        | (map(select((.real_responses // 0) > 0))) as $reviewed
        | (map(select((.real_responses // 0) == 0 and (.refusals // 0) > 0))) as $refused
        | ([.[].latency_s] | map(select(. != null)) | sort) as $lat
        | { key: $bot, value: {
            reviewed_prs:     ($reviewed | length),
            refused_prs:      ($refused | length),
            no_response_prs:  ($eligible - ($reviewed | length) - ($refused | length)),
            engaged_prs:      length,
            reviews:          ([.[].reviews] | add),
            refusal_events:   ([.[].refusals] | add),
            approved:         ([.[].approved] | add),
            changes_req:      ([.[].changes_req] | add),
            inline_comments:  ([.[].inline_comments] | add),
            threads_total:    ([.[].threads_total] | add),
            threads_resolved: ([.[].threads_resolved] | add),
            thumbs_up:        ([.[].thumbs_up] | add),
            thumbs_down:      ([.[].thumbs_down] | add),
            latency_p50: (if ($lat|length)==0 then null else $lat[(((($lat|length)-1)*0.50)|floor)] end),
            latency_p95: (if ($lat|length)==0 then null else $lat[(((($lat|length)-1)*0.95)|round)] end)
          } } ) | from_entries) as $bots
    | { eligible_prs: $eligible, total_prs: $total, bots: $bots }
  ' "${files[@]}" 2>/dev/null || echo '{"eligible_prs":0,"total_prs":0,"bots":{}}'
}

# _prev <snapshot_json_file> <bot> <field> — prior-week scalar or "" when absent.
_prev() {
  local f="${1:-}" bot="$2" field="$3"
  [ -n "$f" ] && [ -f "$f" ] || { printf ''; return 0; }
  jq -r --arg b "$bot" --arg k "$field" '.bots?[$b]?[$k]? // empty' "$f" 2>/dev/null || printf ''
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
  if [ -n "$generated_at" ]; then
    printf '_Generated %s · org `%s` · %s repos scanned · %s PRs active (%s non-draft, review-eligible)_\n\n' \
      "$generated_at" "$ORG" "$repo_count" "$(_fmt_int "$total")" "$(_fmt_int "$eligible")"
  else
    printf '_org `%s` · %s repos scanned · %s PRs active (%s non-draft, review-eligible)_\n\n' \
      "$ORG" "$repo_count" "$(_fmt_int "$total")" "$(_fmt_int "$eligible")"
  fi

  if [ "${total:-0}" -eq 0 ]; then
    printf 'No pull-request activity found in the last %s days.\n' "$lookback"
    if declare -F cn_render_noise_section >/dev/null 2>&1; then
      cn_render_noise_section "$dir"
    fi
    return 0
  fi

  printf 'Deterministic report — every figure is computed with `jq`/`awk` from GitHub review data; '
  printf 'no LLM is involved. Bots are identified by their GraphQL App login '
  printf '(`scripts/lib/advisory-review-gate.sh`); rate-limit/out-of-quota notices are detected by body text. '
  printf '**Reviews** and **Rate-limited** count *every event*, not distinct PRs — a PR re-reviewed across N commits contributes N reviews. '
  printf '**No response** counts eligible PRs the reviewer never engaged with at all. '
  printf '_Latency_ = time from PR creation to the bot'"'"'s first **real** review (refusals excluded). '
  printf 'Deltas (▲/▼) are vs the prior week and directional only.\n\n'

  # ---- Scorecard table -----------------------------------------------------
  printf '## Scorecard\n\n'
  printf '| Reviewer | Total PRs | Reviews | ✅ / 🔄 | Rate-limited | No response | Latency p50 | Latency p95 |\n'
  printf '|---|---:|---:|:--:|---:|---:|---:|---:|\n'

  local bot label reviews refusal_events no_resp approved changes_req p50 p95
  for bot in "${REVIEWER_BOTS[@]}"; do
    label="${REVIEWER_LABELS[$bot]:-$bot}"
    # Pull this bot's aggregates out of the snapshot (0 when absent this week).
    # IFS=tab preserves empty latency fields (a missing percentile must not shift
    # the remaining columns left — that was a field-misalignment bug).
    IFS=$'\t' read -r reviews refusal_events no_resp approved changes_req p50 p95 <<<"$(
      jq -r --arg b "$bot" --argjson elig "${eligible:-0}" '
        (.bots?[$b] // {}) as $x
        | [ ($x.reviews // 0), ($x.refusal_events // 0),
            ($x.no_response_prs // $elig),
            ($x.approved // 0), ($x.changes_req // 0),
            (if $x.latency_p50 == null then "" else $x.latency_p50 end),
            (if $x.latency_p95 == null then "" else $x.latency_p95 end) ]
        | @tsv' <<<"$snap"
    )"

    local prev_reviews prev_refusals
    prev_reviews="$(_prev "$prev" "$bot" reviews)"
    prev_refusals="$(_prev "$prev" "$bot" refusal_events)"
    printf '| %s | %s | %s %s | %s / %s | %s %s | %s | %s | %s |\n' \
      "$label" \
      "$(_fmt_int "$eligible")" \
      "$(_fmt_int "$reviews")" "$(_delta_arrow "$reviews" "$prev_reviews")" \
      "$(_fmt_int "$approved")" "$(_fmt_int "$changes_req")" \
      "$(_fmt_int "$refusal_events")" "$(_delta_arrow "$refusal_events" "$prev_refusals")" \
      "$(_fmt_int "$no_resp")" \
      "$(_fmt_dur "$p50")" "$(_fmt_dur "$p95")"
  done
  printf '\n'
  printf -- '- **Total PRs** — review-eligible (non-draft) PRs in the window; the denominator each row is measured against.\n'
  printf -- '- **Reviews** — count of reviews the bot submitted, **each occurrence** (a PR re-reviewed on 5 commits = 5). A bot that posts no formal review but delivers its verdict as a comment (e.g. SonarCloud'"'"'s quality-gate comment) has that comment counted as its review. Rate-limit notices are never counted.\n'
  printf -- '- **✅ / 🔄** — of those reviews, how many were APPROVED / CHANGES_REQUESTED (comment-only responses carry no verdict).\n'
  printf -- '- **Rate-limited** — count of out-of-quota / rate-limit refusals, each occurrence.\n'
  printf -- '- **No response** — eligible PRs the bot never engaged with at all (no review, comment, or refusal).\n\n'

  # ---- Coverage / overlap --------------------------------------------------
  local co_review multi_bot
  co_review="$(jq -s '
    [ .[] | select(.kind=="bot_pr") ] | group_by(.pr)
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
MAX_PR_PAGES="${MAX_PR_PAGES:-20}"

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
_PR_QUERY='
query($owner:String!, $name:String!, $cursor:String) {
  repository(owner:$owner, name:$name) {
    pullRequests(first: 25, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        url number createdAt updatedAt mergedAt isDraft
        author { login }
        reviews(first: 50) { nodes { author { login } state submittedAt bodyText } }
        reviewThreads(first: 50) {
          nodes {
            isResolved isOutdated
            comments(first: 20) {
              nodes {
                author { login } createdAt bodyText path
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

# _collect_one_repo <repo> — GraphQL-paginate one repo's recently-updated PRs,
# stopping once a page's PRs predate CUTOFF (PRs are ordered by UPDATED_AT desc),
# and append normalized JSONL records to a unique file in COLLECT_JSONL_DIR.
# Always exits 0: a failed repo degrades to a WARN + skip, never an aborted run.
_collect_one_repo() {
  local repo="$1" owner name cursor="" page=0 out
  owner="${repo%%/*}"; name="${repo##*/}"
  out="$(mktemp "${COLLECT_JSONL_DIR}/repo.XXXXXX.jsonl")" || return 0

  local bots_json
  bots_json="$(printf '%s\n' "${REVIEWER_BOTS[@]}" | jq -R . | jq -sc .)"

  while :; do
    page=$((page + 1))
    [ "$page" -gt "${MAX_PR_PAGES}" ] && break

    local resp gql_args
    gql_args=(api graphql -f query="$_PR_QUERY" -F owner="$owner" -F name="$name")
    [ -n "$cursor" ] && gql_args+=(-F cursor="$cursor")
    if ! resp="$(_gh_timeout "${gql_args[@]}" 2>/dev/null)"; then
      echo "WARN: GraphQL query for ${repo} (page ${page}) failed or timed out — partial data" >&2
      break
    fi

    # Emit normalized records for PRs inside the window; count how many nodes were
    # in-window so we can stop paginating once a full page is older than CUTOFF.
    local in_window
    in_window="$(jq -r --arg cutoff "$CUTOFF" '
      [ .data?.repository?.pullRequests?.nodes[]? | select(.updatedAt >= $cutoff) ] | length
    ' <<<"$resp" 2>/dev/null || echo 0)"

    jq -c --arg repo "$repo" --argjson bots "$bots_json" --arg rl "$RATE_LIMIT_RE" --arg cutoff "$CUTOFF" \
      ".data?.repository?.pullRequests?.nodes[]? | select(.updatedAt >= \$cutoff) | ${_NORMALIZE_JQ}" \
      <<<"$resp" >> "$out" 2>/dev/null || true

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

  CUTOFF="$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"
  export CUTOFF COLLECT_JSONL_DIR="$jsonl_dir" GH_OP_TIMEOUT MAX_PR_PAGES
  # shellcheck disable=SC2090  # jq/GraphQL program strings: literal content is intended
  export _PR_QUERY _NORMALIZE_JQ RATE_LIMIT_RE
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
  export -f _collect_one_repo _gh_timeout

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
