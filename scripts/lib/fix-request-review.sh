#!/usr/bin/env bash
# fix-request-review.sh — build pr-review's fix request as a COMMENT review (#2614).
#
# pr-review used to post a delegated fix request as a PR conversation comment, so
# dev-lead's fix pass, which reads review threads, needed its own route to see it
# (#2168). The fix request is now a review with event COMMENT. It is never
# REQUEST_CHANGES, because that state survives new pushes (#2570):
#   - each finding that cites a file and a line becomes an inline comment, so it
#     is an ordinary review thread for dev-lead;
#   - findings without a line stay in the review body, which also carries the
#     `<!-- pr-review-agent v1 sha=… --> <!-- decision=fix-requested … -->` marker
#     pair that the cycle cap and head-SHA idempotency read.
#
# Each inline comment starts with `<!-- pr-review-agent finding sha=<SHA> -->`.
# That marker makes the thread ours to the maintainer gates and to dev-lead's
# resolve guard (its `<!-- pr-review-agent` prefix), and it is deliberately not
# the `v1 sha=` marker, so no cycle or idempotency reader counts it.
#
# Sourced by post-pr-review.sh. Pure functions: jq only, no gh, no network.

# FRR_MAX_INLINE: the most line-cited findings posted as inline comments. Any
# beyond it are listed in the review body with their path:line.
: "${FRR_MAX_INLINE:=50}"

# Shared jq definitions. A finding is line-cited when its file is a non-empty
# string and its line is a positive integer (a number or a string of digits).
_FRR_JQ_DEFS='
  def frr_path: (.file // .path // null) | if type == "string" then ltrimstr("./") else null end;
  def frr_line:
    (.line // null)
    | if type == "number" then (if . >= 1 and . == floor then . else null end)
      elif type == "string" and test("^[0-9]+$") then (tonumber | if . >= 1 then . else null end)
      else null end;
  def frr_located: (frr_path | . != null and . != "") and (frr_line != null);
  def frr_text:
    (.message // .description // .title // .summary // null)
    | if type == "string" then . elif . == null then "(no text)" else tojson end;
  def frr_sev: ((.severity // "info") | tostring | ascii_upcase);
  def frr_cat: (.category // "") | if type == "string" and . != "" then " · `" + . + "`" else "" end;
  def frr_findings: (.findings // []) | if type == "array" then map(objects) else [] end;
'

# frr_has_findings <verdict_file>: exit 0 when .findings is a non-empty array of
# objects, so the review can be built from structured findings.
frr_has_findings() {
  jq -e "$_FRR_JQ_DEFS"'frr_findings | length > 0' "$1" >/dev/null 2>&1
}

# frr_located_findings <verdict_file> <sha>: prints the reviews-API `comments`
# array (path, line, side, body) for the first FRR_MAX_INLINE line-cited findings.
frr_located_findings() {
  jq -c --arg sha "$2" --argjson max "$FRR_MAX_INLINE" "$_FRR_JQ_DEFS"'
    [frr_findings[] | select(frr_located)][0:$max]
    | map({path: frr_path, line: frr_line, side: "RIGHT",
           body: ("<!-- pr-review-agent finding sha=" + $sha + " -->\n**" + frr_sev + "**" + frr_cat + "\n\n" + frr_text)})
  ' "$1"
}

# frr_unlocated_findings_md <verdict_file>: prints one markdown bullet per finding
# that is not posted inline: every finding without a usable line, then any
# line-cited finding past FRR_MAX_INLINE (with its path:line). Empty when none.
frr_unlocated_findings_md() {
  jq -r --argjson max "$FRR_MAX_INLINE" "$_FRR_JQ_DEFS"'
    frr_findings as $all
    | ([$all[] | select(frr_located | not)]
       | map("- **" + frr_sev + "**" + (if (frr_path // "") != "" then " `" + frr_path + "`" else "" end) + ": " + frr_text)),
      ([$all[] | select(frr_located)][$max:]
       | map("- `" + frr_path + ":" + (frr_line | tostring) + "` **" + frr_sev + "**: " + frr_text))
    | .[]
  ' "$1"
}

# frr_located_as_md <comments_json>: renders inline comments as body bullets, for
# the fallback when GitHub refuses them (a line outside the diff is a 422).
frr_located_as_md() {
  jq -r '
    .[]
    | "- `" + .path + ":" + (.line | tostring) + "` "
      + (.body | sub("^<!-- pr-review-agent finding sha=[0-9a-f]* -->\n"; "") | gsub("\n+"; " "))
  ' <<< "$1"
}

# frr_review_payload <sha> <body_file> <comments_json>: prints the JSON for
# POST /repos/{owner}/{repo}/pulls/{n}/reviews. commit_id binds the review to
# the reviewed commit; `comments` is left out when there are none.
frr_review_payload() {
  jq -n --arg sha "$1" --rawfile body "$2" --argjson comments "$3" '
    {commit_id: $sha, event: "COMMENT", body: ($body | rtrimstr("\n"))}
    + (if ($comments | length) > 0 then {comments: $comments} else {} end)
  '
}
