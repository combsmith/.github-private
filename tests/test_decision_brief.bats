#!/usr/bin/env bats
# Unit tests for the decision-brief stage tooling (scripts/decision-brief/):
# the slug derivation, the discussion→dispatch bridge, the provenance +
# structure validator, the PR opener and the Ripe-from-queue sweep. gh is
# mocked everywhere — no network. Fixtures: tests/fixtures/decision-brief/.
#
# Run with: bats tests/test_decision_brief.bats

bats_require_minimum_version 1.5.0

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DB_DIR="$ROOT/scripts/decision-brief"
FIX="$ROOT/tests/fixtures/decision-brief"

setup() {
  TMP="$(mktemp -d)"
  MOCK_BIN="$TMP/bin"
  mkdir -p "$MOCK_BIN"
  GH_LOG="$TMP/gh.log"
  export GH_LOG
  export PATH="$MOCK_BIN:$PATH"
  export GH_TOKEN="pat"
  unset DRY_RUN DRY_RUN_LOG TARGET_REPO WORKFLOW_FILE GITHUB_REF
}

teardown() { rm -rf "$TMP"; }

# mock_gh <script-body> — install a gh stub that logs every invocation.
mock_gh() {
  { printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$GH_LOG"\n'; printf '%s\n' "$1"; } >"$MOCK_BIN/gh"
  chmod +x "$MOCK_BIN/gh"
}

copy_good() { cp -R "$FIX/good" "$TMP/pkg"; echo "$TMP/pkg"; }

validate() { run bash "$DB_DIR/validate-package.sh" "$@"; }

# ── slug ──────────────────────────────────────────────────────────────────────

@test "slug: ideation title with emoji and em-dash pitch → the Name, CamelCase split" {
  source "$DB_DIR/lib/slug.sh"
  [ "$(db_slug_from_title '💡 DemandRadar — multi-source demand-discovery engine')" = "demand-radar" ]
  [ "$(db_slug_from_title 'ContentTwin')" = "content-twin" ]
  [ "$(db_slug_from_title '💡 A2AProbe — conformance suite')" = "a2a-probe" ]
  [ "$(db_slug_from_title '💡 MCPServerCard — metadata generator')" = "mcp-server-card" ]
}

@test "slug: plain titles are kebab-cased, squeezed and capped at 48 chars on a word boundary" {
  source "$DB_DIR/lib/slug.sh"
  [ "$(db_slug_from_title 'Wire the decision-brief agent stage (Mary → brief.md at Ripe)')" = "wire-the-decision-brief-agent-stage-mary-brief" ]
  [ "$(db_slug_from_title '  Foo__bar!!  baz ')" = "foo-bar-baz" ]
  s="$(db_slug_from_title 'aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeeeeeeeee ffffffffff')"
  [ "${#s}" -le 48 ]
  db_slug_is_valid "$s"
}

@test "slug: the same title always yields the same slug (stable folder, stable branch)" {
  source "$DB_DIR/lib/slug.sh"
  [ "$(db_slug_from_title '💡 WidgetLint — a lint')" = "$(db_slug_from_title '💡 WidgetLint — a different pitch')" ]
}

@test "slug: validity rejects empty, uppercase, the _TEMPLATE folder and stray hyphens" {
  source "$DB_DIR/lib/slug.sh"
  db_slug_is_valid "widget-lint"
  run ! db_slug_is_valid ""
  run ! db_slug_is_valid "Widget-Lint"
  run ! db_slug_is_valid "_TEMPLATE"
  run ! db_slug_is_valid "-leading"
  run ! db_slug_is_valid "double--hyphen"
}

# ── redispatch bridge ─────────────────────────────────────────────────────────

@test "redispatch: re-dispatches decision-brief.yml with discussion, target_repo and dry_run=false" {
  mock_gh 'exit 0'
  REPO="combsmith/.github-private" DISCUSSION_NUMBER=572 run bash "$DB_DIR/redispatch.sh"
  [ "$status" -eq 0 ]
  grep -qF "workflow run decision-brief.yml" "$GH_LOG"
  grep -qF -- "--repo combsmith/.github-private" "$GH_LOG"
  grep -qF -- "-f discussion=572" "$GH_LOG"
  grep -qF -- "-f target_repo=combsmith/.github-private" "$GH_LOG"
  grep -qF -- "-f dry_run=false" "$GH_LOG"
  # Only inputs decision-brief.yml declares: gh rejects an undeclared input.
  ! grep -qE -- "-f (force_replan|reconcile)=" "$GH_LOG" || false
}

@test "redispatch: honors TARGET_REPO (fleet host) and DRY_RUN" {
  mock_gh 'exit 0'
  REPO="combsmith/.github-private" TARGET_REPO="acme/widgets" DISCUSSION_NUMBER=7 DRY_RUN=true \
    run bash "$DB_DIR/redispatch.sh"
  [ "$status" -eq 0 ]
  grep -qF -- "-f target_repo=acme/widgets" "$GH_LOG"
  grep -qF -- "-f dry_run=true" "$GH_LOG"
}

@test "redispatch: rejects a non-numeric discussion and a malformed target repo without dispatching" {
  mock_gh 'exit 0'
  REPO="combsmith/.github-private" DISCUSSION_NUMBER="572; rm -rf /" run bash "$DB_DIR/redispatch.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"positive integer"* ]]
  [ ! -s "$GH_LOG" ]
  REPO="combsmith/.github-private" TARGET_REPO="acme/widgets;x" DISCUSSION_NUMBER=5 run bash "$DB_DIR/redispatch.sh"
  [ "$status" -ne 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "redispatch: passes --ref for a branch GITHUB_REF, not for a PR merge ref" {
  mock_gh 'exit 0'
  REPO=r/r DISCUSSION_NUMBER=1 GITHUB_REF=refs/heads/feature run bash "$DB_DIR/redispatch.sh"
  grep -qF -- "--ref refs/heads/feature" "$GH_LOG"
  : >"$GH_LOG"
  REPO=r/r DISCUSSION_NUMBER=1 GITHUB_REF=refs/pull/9/merge run bash "$DB_DIR/redispatch.sh"
  ! grep -qF -- "--ref" "$GH_LOG" || false
}

# ── validate-package: structure ───────────────────────────────────────────────

@test "validate: the good package passes every check" {
  pkg="$(copy_good)"
  validate "$pkg" --slug widget-lint --discussion 413
  [ "$status" -eq 0 ]
  ! grep -q '^FAIL' <<<"$output" || false
}

@test "validate: the untouched incubator _TEMPLATE fails (draft status, placeholders, empty rows)" {
  validate "$FIX/template"
  [ "$status" -ne 0 ]
  grep -q 'FAIL|brief.md|frontmatter|status=.draft' <<<"$output"
  grep -q 'FAIL|brief.md|placeholders' <<<"$output"
  grep -q 'FAIL|market-research.md|placeholders' <<<"$output"
}

@test "validate: a missing file and a missing required section are reported" {
  pkg="$(copy_good)"; rm "$pkg/ost.md"
  sed -i.bak 's/^## 6\. Riskiest assumptions.*/## 6. Things/' "$pkg/brief.md"
  validate "$pkg"
  [ "$status" -ne 0 ]
  grep -q 'FAIL|ost.md|present|missing' <<<"$output"
  grep -q 'FAIL|brief.md|sections|missing section(s): Riskiest assumption' <<<"$output"
}

@test "validate: honours extra required_sections from a package-spec.json" {
  pkg="$(copy_good)"
  printf '{"required_artifacts":[{"file":"brief.md","required_sections":["Problem","Budget envelope"]}]}' >"$TMP/spec.json"
  validate "$pkg" --spec "$TMP/spec.json"
  [ "$status" -ne 0 ]
  grep -q 'missing section(s): Budget envelope' <<<"$output"
}

@test "validate: the score must be a RICE/ICE line with its arithmetic AND a stated Confidence" {
  pkg="$(copy_good)"
  sed -i.bak 's/ICE = 3 × 2 × 4 = 24 \/ 125/we think it is worth doing/' "$pkg/brief.md"
  validate "$pkg"
  grep -q 'FAIL|brief.md|score|no RICE/ICE score line' <<<"$output"
  pkg2="$TMP/pkg2"; cp -R "$FIX/good" "$pkg2"
  sed -i.bak 's/Confidence = 2\/5 (thread evidence, no measured rate)/Conf. 2/' "$pkg2/brief.md"
  validate "$pkg2"
  grep -q 'FAIL|brief.md|score|.*Confidence' <<<"$output"
}

@test "validate: the riskiest-assumptions table needs a Cheapest-test column and one full row" {
  pkg="$(copy_good)"
  sed -i.bak 's/^| 1 | The three incidents.*$/| 1 | | | | |/' "$pkg/brief.md"
  validate "$pkg"
  [ "$status" -ne 0 ]
  grep -q 'FAIL|brief.md|assumptions|.*no fully-filled row' <<<"$output"
  pkg2="$TMP/pkg2"; cp -R "$FIX/good" "$pkg2"
  sed -i.bak 's/Cheapest test/Next step/' "$pkg2/brief.md"
  validate "$pkg2"
  grep -q "FAIL|brief.md|assumptions|.*no 'Cheapest test' column" <<<"$output"
}

@test "validate: the recommendation must take a position and name the idea:approved gate" {
  pkg="$(copy_good)"
  sed -i.bak 's/\*\*Recommendation: go\*\*/**Recommendation: it depends**/; s/say no if/say maybe if/' "$pkg/brief.md"
  validate "$pkg"
  grep -q 'FAIL|brief.md|decision|.*takes no position' <<<"$output"
  pkg2="$TMP/pkg2"; cp -R "$FIX/good" "$pkg2"
  sed -i.bak 's/`idea:approved`/the label/' "$pkg2/brief.md"
  validate "$pkg2"
  grep -q 'FAIL|brief.md|decision|.*idea:approved' <<<"$output"
}

@test "validate: identity — slug line, source-discussion link and the links to the other artifacts" {
  pkg="$(copy_good)"
  validate "$pkg" --slug other-slug --discussion 999
  [ "$status" -ne 0 ]
  grep -q 'FAIL|brief.md|identity|does not carry' <<<"$output"
  grep -q 'FAIL|brief.md|identity|Source Discussion link to /discussions/999 missing' <<<"$output"
  pkg2="$TMP/pkg2"; cp -R "$FIX/good" "$pkg2"
  sed -i.bak 's/See `ost.md`\./See the tree./' "$pkg2/brief.md"
  validate "$pkg2"
  grep -q 'FAIL|brief.md|links' <<<"$output"
}

@test "validate: ost.md must carry a mermaid block; brief.md must be status final" {
  pkg="$(copy_good)"
  sed -i.bak 's/^```mermaid$/```text/' "$pkg/ost.md"
  sed -i.bak 's/^status: final$/status: draft/' "$pkg/brief.md"
  validate "$pkg"
  grep -q 'FAIL|ost.md|mermaid' <<<"$output"
  grep -q "FAIL|brief.md|frontmatter|status='draft'" <<<"$output"
}

# ── validate-package: provenance guard (#1160) ────────────────────────────────

@test "provenance: an unsourced market figure in market-research.md fails the package" {
  pkg="$(copy_good)"
  printf '\nThe addressable market is $2.4B and growing 30%% a year.\n' >>"$pkg/market-research.md"
  # Appended after Sources — move it into Market signal instead.
  sed -i.bak '/^## Market signal$/a\
The addressable market is $2.4B and growing 30% a year.
' "$pkg/market-research.md"
  validate "$pkg"
  [ "$status" -ne 0 ]
  grep -q 'FAIL|market-research.md|provenance|.*2.4B' <<<"$output"
}

@test "provenance: an unsourced figure in brief.md Problem / Market sections fails; §5 arithmetic does not" {
  pkg="$(copy_good)"
  sed -i.bak '/^## 1\. Problem$/a\
About 40% of maintainers hit this every month.
' "$pkg/brief.md"
  validate "$pkg"
  [ "$status" -ne 0 ]
  grep -q 'FAIL|brief.md|provenance|.*40%' <<<"$output"
  # The ICE arithmetic in §5 (3 × 2 × 4 = 24 / 125) is not a market claim.
  ! grep -q 'FAIL|brief.md|provenance|.*24 / 125' <<<"$output" || false
}

@test "provenance: a figure with a URL, a [^n] footnote, [ASSUMPTION] or 'unknown — needs discovery' passes" {
  pkg="$(copy_good)"
  sed -i.bak '/^## Market signal$/a\
Buffer lists 140k customers (https://buffer.com/about).\
Hootsuite claims 18 million users [^2].\
[ASSUMPTION] roughly 500 small orgs in the first segment — not confirmed in the thread.\
Willingness to pay per seat: unknown — needs discovery.
' "$pkg/market-research.md"
  printf '[^2]: https://www.hootsuite.com/about\n' >>"$pkg/market-research.md"
  validate "$pkg"
  [ "$status" -eq 0 ]
}

@test "provenance: market-research.md needs a Sources section with a URL or the no-sources sentence" {
  pkg="$(copy_good)"
  sed -i.bak 's/^## Sources$/## Appendix/' "$pkg/market-research.md"
  validate "$pkg"
  grep -q 'FAIL|market-research.md|sources|no' <<<"$output"
  pkg2="$TMP/pkg2"; cp -R "$FIX/good" "$pkg2"
  sed -i.bak 's#^\[\^1\]: https://www.npmjs.com/package/ajv$#none#; s/ \[\^1\]\./ (unknown — needs discovery)./' "$pkg2/market-research.md"
  validate "$pkg2"
  grep -q 'FAIL|market-research.md|sources|Sources lists no URL' <<<"$output"
  pkg3="$TMP/pkg3"; cp -R "$FIX/good" "$pkg3"
  sed -i.bak 's#^\[\^1\]: https://www.npmjs.com/package/ajv$#No external sources were consulted — every market claim above is marked unknown — needs discovery.#; s/ \[\^1\]\./ (unknown — needs discovery)./' "$pkg3/market-research.md"
  validate "$pkg3"
  [ "$status" -eq 0 ]
}

@test "provenance: lines inside the Sources section and fenced code are not scanned" {
  pkg="$(copy_good)"
  printf '%s\n' '[^3]: https://example.com/report — "$5B market, 20% CAGR"' >>"$pkg/market-research.md"
  sed -i.bak '/^## Risks & unknowns$/a\
```\
$9B figure inside a code fence is not a claim\
```
' "$pkg/market-research.md"
  validate "$pkg"
  [ "$status" -eq 0 ]
}

# ── open-pr ───────────────────────────────────────────────────────────────────

@test "open-pr (DRY_RUN): logs the intended PR with the files under ideas/<slug>/ and the back-link, touches nothing" {
  pkg="$(copy_good)"
  mock_gh 'echo "gh must not be called in dry-run" >&2; exit 99'
  DRY_RUN=1 DRY_RUN_LOG="$TMP/dry.jsonl" REPO="acme/widgets" SLUG="widget-lint" PACKAGE_DIR="$pkg" \
    DISCUSSION_NUMBER=413 DISCUSSION_NODE_ID="D_x" IDEA_TITLE="WidgetLint" GIT_USER_NAME=tester \
    run bash "$DB_DIR/open-pr.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
  [ "$(jq -r 'select(.op=="open_pr") | .branch' "$TMP/dry.jsonl")" = "incubate/widget-lint" ]
  [ "$(jq -r 'select(.op=="open_pr") | .files | join(",")' "$TMP/dry.jsonl")" = "ideas/widget-lint/brief.md,ideas/widget-lint/market-research.md,ideas/widget-lint/ost.md" ]
  [ "$(jq -r 'select(.op=="open_pr") | .author' "$TMP/dry.jsonl")" = "tester" ]
  grep -q '"op":"discussion_comment"' "$TMP/dry.jsonl"
}

@test "open-pr: rejects a bad slug and a package without brief.md before any call" {
  mock_gh 'exit 0'
  pkg="$(copy_good)"
  REPO=a/b SLUG="Bad_Slug" PACKAGE_DIR="$pkg" DISCUSSION_NUMBER=1 run bash "$DB_DIR/open-pr.sh"
  [ "$status" -ne 0 ]; [ ! -s "$GH_LOG" ]
  rm "$pkg/brief.md"
  REPO=a/b SLUG="ok" PACKAGE_DIR="$pkg" DISCUSSION_NUMBER=1 run bash "$DB_DIR/open-pr.sh"
  [ "$status" -ne 0 ]; [[ "$output" == *"no brief.md"* ]]; [ ! -s "$GH_LOG" ]
}

# A gh stub for the live path: Git Data API + pr list/create + graphql, keyed on
# the call shape. BRANCH_EXISTS / PR_EXISTS switch the idempotent branches.
mock_gh_live() {
  mock_gh '
case "$*" in
  "api repos/acme/widgets --jq .default_branch") echo main ;;
  "api repos/acme/widgets/git/ref/heads/main --jq .object.sha") echo base000 ;;
  "api repos/acme/widgets/git/ref/heads/incubate/widget-lint --jq .object.sha")
     if [ "${BRANCH_EXISTS:-0}" = 1 ]; then echo head111; else echo "not found" >&2; exit 1; fi ;;
  api\ repos/acme/widgets/git/commits/*) echo tree222 ;;
  "api repos/acme/widgets/git/blobs -X POST --input - --jq .sha") cat >>"$GH_LOG.blobs"; echo blob333 ;;
  "api repos/acme/widgets/git/trees -X POST --input - --jq .sha") cat >>"$GH_LOG.tree"; echo tree444 ;;
  "api repos/acme/widgets/git/commits -X POST --input - --jq .sha") cat >>"$GH_LOG.commit"; echo commit555 ;;
  *"pr list --repo acme/widgets --head incubate/widget-lint"*) if [ "${PR_EXISTS:-0}" = 1 ]; then echo "https://github.com/acme/widgets/pull/9"; fi ;;
  *"pr create"*) echo "https://github.com/acme/widgets/pull/10" ;;
  *) : ;;
esac
exit 0'
}

@test "open-pr (live, new branch): blobs → tree → commit (persona author) → new ref → PR with label → discussion back-link" {
  pkg="$(copy_good)"
  mock_gh_live
  REPO="acme/widgets" SLUG="widget-lint" PACKAGE_DIR="$pkg" DISCUSSION_NUMBER=413 \
    DISCUSSION_NODE_ID="D_x" IDEA_TITLE="WidgetLint" GIT_USER_NAME="don-petry" GITHUB_OUTPUT="$TMP/out" \
    run bash "$DB_DIR/open-pr.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'git/blobs -X POST' "$GH_LOG")" -eq 3 ]
  grep -q '"base_tree":"tree222"' "$GH_LOG.tree"
  grep -q '"path":"ideas/widget-lint/brief.md"' "$GH_LOG.tree"
  grep -q '"parents":\["base000"\]' "$GH_LOG.commit"
  grep -q '"author":{"name":"don-petry","email":"don-petry@users.noreply.github.com"}' "$GH_LOG.commit"
  grep -qF 'api repos/acme/widgets/git/refs -X POST -f ref=refs/heads/incubate/widget-lint -f sha=commit555' "$GH_LOG"
  grep -q 'pr create --repo acme/widgets --base main --head incubate/widget-lint' "$GH_LOG"
  grep -q -- '--label decision-brief' "$GH_LOG"
  grep -q 'addDiscussionComment' "$GH_LOG"
  grep -q 'pr_url=https://github.com/acme/widgets/pull/10' "$TMP/out"
  ! grep -qF '.github-private' "$GH_LOG" || false
}

@test "open-pr (live, branch + PR exist): appends to the branch, comments on the PR, opens no second PR" {
  pkg="$(copy_good)"
  mock_gh_live
  BRANCH_EXISTS=1 PR_EXISTS=1 REPO="acme/widgets" SLUG="widget-lint" PACKAGE_DIR="$pkg" DISCUSSION_NUMBER=413 \
    GIT_USER_NAME=t run bash "$DB_DIR/open-pr.sh"
  [ "$status" -eq 0 ]
  grep -q '"parents":\["head111"\]' "$GH_LOG.commit"
  grep -qF 'api repos/acme/widgets/git/refs/heads/incubate/widget-lint -X PATCH -f sha=commit555' "$GH_LOG"
  ! grep -q 'pr create' "$GH_LOG" || false
  grep -q 'pr comment https://github.com/acme/widgets/pull/9' "$GH_LOG"
  [[ "$output" == *"refreshed existing PR"* ]]
}

@test "open-pr: the commit author defaults to the business-analyst persona's runtime account" {
  pkg="$(copy_good)"
  mock_gh_live
  REPO="acme/widgets" SLUG="widget-lint" PACKAGE_DIR="$pkg" DISCUSSION_NUMBER=413 \
    run bash "$DB_DIR/open-pr.sh"
  [ "$status" -eq 0 ]
  expected="$(bash "$ROOT/scripts/lib/resolve-persona-identity.sh" business-analyst "$ROOT/personas" account)"
  grep -q "\"author\":{\"name\":\"${expected}\"" "$GH_LOG.commit"
}

# ── ripe-from-queue ───────────────────────────────────────────────────────────

@test "ripe-from-queue helpers: only the Ripe section is read; numbers are distinct and in order" {
  source "$DB_DIR/ripe-from-queue.sh"
  run bash -c "source '$DB_DIR/ripe-from-queue.sh'; dbq_ripe_section < '$FIX/queue-body.md' | dbq_discussion_numbers | paste -sd, -"
  [ "$output" = "413,44" ]
}

# gh stub for the sweep: queue issue, per-discussion GraphQL, contents/PR probes.
mock_gh_sweep() {
  mock_gh '
case "$*" in
  *"issue list --repo acme/widgets --label idea-triage"*) jq -Rs "{title:\"🧭 Idea Promotion Queue\", body:.}" < "$QUEUE_FILE" | jq -r ".body" ;;
  *graphql*)
     case "$*" in
       *"num=413"*) echo "{\"data\":{\"repository\":{\"discussion\":{\"title\":\"💡 WidgetLint — a lint\",\"category\":{\"name\":\"Ideas\"},\"labels\":{\"nodes\":[${LABELS_413:-}]}}}}}" ;;
       *"num=44"*)  echo "{\"data\":{\"repository\":{\"discussion\":{\"title\":\"DemandRadar\",\"category\":{\"name\":\"Ideas\"},\"labels\":{\"nodes\":[]}}}}}" ;;
       *) echo "{}" ;;
     esac ;;
  *"contents/ideas/widget-lint/brief.md"*) if [ "${BRIEF_EXISTS:-0}" = 1 ]; then echo sha; else exit 1; fi ;;
  *"contents/"*) exit 1 ;;
  *"pr list"*) : ;;
  *) : ;;
esac
exit 0'
}

@test "ripe-from-queue: dispatches one central brief run per Ripe idea with target_repo and dry_run=false" {
  export QUEUE_FILE="$FIX/queue-body.md"
  mock_gh_sweep
  REPO="acme/widgets" CENTRAL_REPO="combsmith/.github-private" run bash "$DB_DIR/ripe-from-queue.sh"
  [ "$status" -eq 0 ]
  grep -qF -- "workflow run decision-brief.yml --repo combsmith/.github-private -f discussion=413 -f target_repo=acme/widgets -f dry_run=false" "$GH_LOG"
  grep -qF -- "-f discussion=44 -f target_repo=acme/widgets" "$GH_LOG"
  ! grep -qF -- "-f discussion=500" "$GH_LOG" || false
  [[ "$output" == *"dispatched=2 skipped=0"* ]]
}

@test "ripe-from-queue: skips an idea that already has a brief, one already idea:approved, and honours the cap" {
  export QUEUE_FILE="$FIX/queue-body.md"
  mock_gh_sweep
  BRIEF_EXISTS=1 REPO="acme/widgets" run bash "$DB_DIR/ripe-from-queue.sh"
  [ "$status" -eq 0 ]
  ! grep -qF -- "-f discussion=413" "$GH_LOG" || false
  grep -qF -- "-f discussion=44" "$GH_LOG"
  : >"$GH_LOG"
  LABELS_413='{"name":"idea:approved"}' REPO="acme/widgets" run bash "$DB_DIR/ripe-from-queue.sh"
  [[ "$output" == *"skip #413: already idea:approved"* ]]
  ! grep -qF -- "-f discussion=413" "$GH_LOG" || false
  : >"$GH_LOG"
  MAX_BRIEFS=1 REPO="acme/widgets" run bash "$DB_DIR/ripe-from-queue.sh"
  [ "$(grep -c 'workflow run' "$GH_LOG")" -eq 1 ]
  [[ "$output" == *"cap reached"* ]]
}

@test "ripe-from-queue: DRY_RUN logs the intended dispatches; no queue issue is a clean no-op" {
  export QUEUE_FILE="$FIX/queue-body.md"
  mock_gh_sweep
  DRY_RUN=1 DRY_RUN_LOG="$TMP/dry.jsonl" REPO="acme/widgets" run bash "$DB_DIR/ripe-from-queue.sh"
  [ "$status" -eq 0 ]
  ! grep -q 'workflow run' "$GH_LOG" || false
  [ "$(jq -r 'select(.discussion==413) | .slug' "$TMP/dry.jsonl")" = "widget-lint" ]
  mock_gh 'exit 0'
  REPO="acme/widgets" run bash "$DB_DIR/ripe-from-queue.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no open Idea Promotion Queue"* ]]
}

# ── gather-context ────────────────────────────────────────────────────────────

mock_gh_gather() {
  mock_gh '
case "$*" in
  *graphql*) echo "{\"data\":{\"repository\":{\"discussion\":{\"id\":\"D_target\",\"title\":\"💡 WidgetLint — a lint for manifests\",\"body\":\"see #12\",\"url\":\"https://github.com/acme/widgets/discussions/413\",\"createdAt\":\"t\",\"updatedAt\":\"t\",\"author\":{\"login\":\"don\"},\"category\":{\"name\":\"Ideas\",\"slug\":\"ideas\"},\"labels\":{\"nodes\":[{\"name\":\"needs-brief\"}]},\"comments\":{\"nodes\":[{\"author\":{\"login\":\"bot\"},\"body\":\"<!-- feature-ideation:enhanced -->\\n## Enhancement\",\"createdAt\":\"t\",\"url\":\"u\"}]}}}}}" ;;
  *"issue list --repo acme/widgets --label idea-triage"*) echo "" ;;
  *"contents/ideas/_TEMPLATE/brief.md"*) if [ "${NO_TEMPLATE:-0}" = 1 ]; then exit 1; fi; base64 < "'"$FIX"'/template/brief.md" | tr -d "\n" ;;
  *"contents/ideas/_TEMPLATE/market-research.md"*) base64 < "'"$FIX"'/template/market-research.md" | tr -d "\n" ;;
  *"contents/ideas/_TEMPLATE/ost.md"*) base64 < "'"$FIX"'/template/ost.md" | tr -d "\n" ;;
  *"contents/ideas/package-spec.json"*) printf "{\"required_artifacts\":[]}" | base64 | tr -d "\n" ;;
  *"contents/ideas/widget-lint"*) exit 1 ;;
  "api repos/acme/widgets/issues/12 --jq "*) echo "{\"number\":12,\"title\":\"prereq\",\"state\":\"open\",\"url\":\"u\"}" ;;
  *) echo "{}" ;;
esac
exit 0'
}

@test "gather-context: reads the TARGET repo only, derives the slug, finds the enhancement comment and the template" {
  mock_gh_gather
  CTX="$TMP/ctx.json"
  GITHUB_ENV="$TMP/env" REPO="acme/widgets" DISCUSSION_NUMBER=413 CONTEXT_PATH="$CTX" \
    run bash "$DB_DIR/gather-context.sh"
  [ "$status" -eq 0 ]
  grep -qF -- "owner=acme" "$GH_LOG"
  grep -qF -- "name=widgets" "$GH_LOG"
  ! grep -qF -- ".github-private" "$GH_LOG" || false
  [ "$(jq -r '.repo' "$CTX")" = "acme/widgets" ]
  [ "$(jq -r '.slug' "$CTX")" = "widget-lint" ]
  [ "$(jq -r '.package_dir' "$CTX")" = "ideas/widget-lint" ]
  [ "$(jq -r '.discussion.number' "$CTX")" = "413" ]
  [ "$(jq -r '.enhancement.author' "$CTX")" = "bot" ]
  jq -e '.template["brief.md"] | contains("Decision Brief")' "$CTX" >/dev/null
  jq -e '.package_spec.required_artifacts' "$CTX" >/dev/null
  [ "$(jq -r '.referenced_issues[0].number' "$CTX")" = "12" ]
  grep -q '^DISCUSSION_NODE_ID=D_target$' "$TMP/env"
  grep -q '^SLUG=widget-lint$' "$TMP/env"
}

@test "gather-context: fails loud when the target has no ideas/_TEMPLATE/brief.md" {
  NO_TEMPLATE=1 mock_gh_gather
  export NO_TEMPLATE=1
  REPO="acme/widgets" DISCUSSION_NUMBER=413 CONTEXT_PATH="$TMP/ctx.json" run bash "$DB_DIR/gather-context.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no ideas/_TEMPLATE/brief.md"* ]]
}

@test "gather-context: an explicit SLUG override wins; an invalid one is rejected" {
  mock_gh_gather
  SLUG="custom-name" REPO="acme/widgets" DISCUSSION_NUMBER=413 CONTEXT_PATH="$TMP/ctx.json" \
    run bash "$DB_DIR/gather-context.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.slug' "$TMP/ctx.json")" = "custom-name" ]
  SLUG="Not Valid" REPO="acme/widgets" DISCUSSION_NUMBER=413 CONTEXT_PATH="$TMP/ctx2.json" \
    run bash "$DB_DIR/gather-context.sh"
  [ "$status" -ne 0 ]
}
