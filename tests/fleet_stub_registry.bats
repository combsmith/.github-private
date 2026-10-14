#!/usr/bin/env bats
# Tests for the collapsed-role STUB_REGISTRY rows (#1729 AC11(b)) and the AC4
# no-resurrection proof.
#
# The five petry-projects/markets roles that collapsed into agent-ingress.yml
# (markets#513) are registered in BOTH scripts/fleet_monitor.sh and
# scripts/fleet_stub_remediate.sh. These tests drive the real fleet_monitor.sh
# and fleet_stub_remediate.sh drivers against a `gh` shim that serves files from
# a fixture tree, so no live API call is made. Run:
#   bats tests/fleet_stub_registry.bats
#
# tests/fixtures/agent-ingress/markets-agent-ingress.yml is petry-projects/markets
# .github/workflows/agent-ingress.yml verbatim at 5fe86cbc (the merged collapse).

MONITOR="${BATS_TEST_DIRNAME}/../scripts/fleet_monitor.sh"
REMEDIATE="${BATS_TEST_DIRNAME}/../scripts/fleet_stub_remediate.sh"
MARKETS_INGRESS="${BATS_TEST_DIRNAME}/fixtures/agent-ingress/markets-agent-ingress.yml"
INGRESS_STUB=".github/workflows/agent-ingress.yml"
INGRESS_CANON="standards/workflows/agent-ingress.yml"
ROLES=(dev-lead pr-auto-review pr-review pr-review-mention ci-failure-analyst)

setup() {
  # shellcheck source=scripts/fleet_stub_drift.sh
  source "${BATS_TEST_DIRNAME}/../scripts/fleet_stub_drift.sh"

  WORK="$(mktemp -d "${BATS_TEST_TMPDIR}/work.XXXXXX")"
  # FAKE_ROOT/<owner>/<repo>/<path> is what the shim serves for a contents read;
  # an absent file answers HTTP 404, exactly like the contents API.
  FAKE_ROOT="${WORK}/root"; export FAKE_ROOT
  CALLS="${WORK}/calls.log"; export CALLS
  ORG="petry-projects"; export ORG
  STUB_BIN="${WORK}/bin"
  mkdir -p "$FAKE_ROOT" "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  unset GITHUB_ENV GITHUB_STEP_SUMMARY

  cat > "$STUB_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
if [ "$1" = "pr" ]; then
  # `pr list` finds no open remediation PR; `pr create` is logged above.
  exit 0
fi
[ "$1" = "api" ] || exit 0
shift
raw=0; jq_expr=""; method="GET"; path=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) [ "$2" = "Accept: application/vnd.github.raw" ] && raw=1; shift 2 ;;
    --jq) jq_expr="$2"; shift 2 ;;
    --method|-X) method="$2"; shift 2 ;;
    --field|-f|-F|--input) shift 2 ;;
    -*) shift ;;
    *) [ -z "$path" ] && path="$1"; shift ;;
  esac
done
case "$path" in
  "orgs/${ORG}") echo '{}' ;;
  "orgs/${ORG}/repos"*) for r in ${FAKE_REPOS:-}; do echo "$r"; done ;;
  repos/*/contents/*)
    [ "$method" = "GET" ] || { echo '{}'; exit 0; }
    rest="${path#repos/}"; repo="${rest%%/contents/*}"
    file="${rest#*/contents/}"; file="${file%%\?*}"
    f="${FAKE_ROOT}/${repo}/${file}"
    if [ ! -f "$f" ]; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    if [ "$raw" -eq 1 ]; then cat "$f"; else git hash-object "$f"; fi ;;
  repos/*/git/ref/heads/*) echo "basesha0000000000000000000000000000000000" ;;
  repos/*/actions/workflows\?*)
    # Section 2 lists workflows as an array; 2e asks for the ingress id.
    case "$jq_expr" in first\(*) ;; *) echo '[]' ;; esac ;;
  repos/*/actions/*) ;;
  repos/*/*) ;;
  repos/*) echo "main" ;;
esac
exit 0
SHIM
  chmod +x "$STUB_BIN/gh"
}

teardown() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  return 0
}

# put_file <owner/repo> <path> — copy stdin into the fixture tree.
put_file() {
  mkdir -p "$(dirname "${FAKE_ROOT}/$1/$2")"
  cat > "${FAKE_ROOT}/$1/$2"
}

# drop_job <job> — print stdin with the <job> block removed.
drop_job() {
  awk -v job="$1" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    !injob && $0 ~ ("^  " job ":([ \t]|$)") { injob = 1; next }
    injob && ($0 ~ /^[ \t]*$/ || indent($0) > 2) { next }
    { injob = 0; print }
  '
}

# publish_canonicals — the canonical ingress (the markets file) plus the three
# per-role legacy canonicals petry-projects/.github publishes.
publish_canonicals() {
  put_file "petry-projects/.github" "$INGRESS_CANON" < "$MARKETS_INGRESS"
  local r
  for r in dev-lead pr-auto-review pr-review-mention; do
    printf 'name: %s canonical legacy stub\n' "$r" \
      | put_file "petry-projects/.github" "standards/workflows/${r}.yml"
  done
}

# run_monitor <repo...> — run fleet_monitor.sh over the given repos in $WORK.
run_monitor() {
  export FAKE_REPOS="$*"
  cd "$WORK"
  run bash "$MONITOR"
}

# role_counts <label> — the "ALIGNED/DRIFTED/MISSING" line of that label's
# report section, or empty when the section was not written.
role_counts() {
  awk -v h="## $1 stub coverage & drift" '
    $0 == h { f = 1; next }
    f && /ALIGNED:/ { print; exit }
  ' "${WORK}/fleet_monitor_report.md"
}

counts_line() {
  printf '✅ ALIGNED: %s  🔴 DRIFTED: %s  ⬜ MISSING (not enrolled): %s' "$1" "$2" "$3"
}

# registry_rows <script> — print the STUB_REGISTRY rows declared in <script>.
# fleet_monitor.sh runs on source, so the array literal is evaluated on its own.
registry_rows() {
  local STUB_REGISTRY=()
  eval "$(sed -n '/^STUB_REGISTRY=(/,/^)/p' "$1")"
  printf '%s\n' "${STUB_REGISTRY[@]}"
}

# ---------------------------------------------------------------------------
# The registry rows
# ---------------------------------------------------------------------------

@test "registry: fleet_monitor.sh and fleet_stub_remediate.sh carry identical rows (lockstep)" {
  monitor_rows="$(registry_rows "$MONITOR")"
  remediate_rows="$(registry_rows "$REMEDIATE")"
  [ -n "$monitor_rows" ]
  [ "$monitor_rows" = "$remediate_rows" ]
}

@test "registry: one row per collapsed markets role, pointing at agent-ingress.yml" {
  rows="$(registry_rows "$MONITOR")"
  local role legacy_canon
  for role in "${ROLES[@]}"; do
    case "$role" in
      pr-review|ci-failure-analyst) legacy_canon="" ;;
      *) legacy_canon="standards/workflows/${role}.yml" ;;
    esac
    want="$(printf '%s\t' "$role" "" "$INGRESS_STUB" "$INGRESS_CANON" "$role" ".github/workflows/${role}.yml")${legacy_canon}"
    got="$(printf '%s\n' "$rows" | awk -F'\t' -v r="$role" '$5 == r' | awk -F'\t' 'BEGIN{OFS="\t"} {$2=""; print}')"
    [ "$got" = "$want" ]
    # The role is the job name exactly as in markets' agent-ingress.yml.
    [ -n "$(extract_job_block "$role" < "$MARKETS_INGRESS")" ]
  done
  # Labels are distinct: the drift alert step opens one issue per label.
  [ "$(printf '%s\n' "$rows" | cut -f2 | sort | uniq -d)" = "" ]
}

# ---------------------------------------------------------------------------
# The canonical template is not published yet: every role row must degrade like
# the per-job path does today (warn, skip, write nothing, stay green).
# ---------------------------------------------------------------------------

@test "fleet_monitor: a 404 canonical agent-ingress skips every role row with a warning and stays green" {
  put_file "petry-projects/markets" "$INGRESS_STUB" < "$MARKETS_INGRESS"
  printf 'name: legacy\n' | put_file "petry-projects/legacy" ".github/workflows/dev-lead.yml"

  run_monitor petry-projects/legacy petry-projects/markets
  [ "$status" -eq 0 ]
  local role label
  for role in "${ROLES[@]}"; do
    [[ "$output" == *"::warning::Canonical agent-ingress not found (petry-projects/.github/${INGRESS_CANON}) — skipping ${role} (${role}) stub drift detection."* ]]
  done
  [[ "$output" == *"=== Fleet monitor complete ==="* ]]

  # Nothing written: no drift rows, no report section, no consumer reads.
  [ "$(jq -c . "${WORK}/fleet_stub_drift.json")" = "[]" ]
  for label in Dev-lead Pr-auto-review Pr-review Pr-review-mention Ci-failure-analyst; do
    [ -z "$(role_counts "$label")" ]
  done
  run grep -E "repos/petry-projects/(markets|legacy)/contents/" "$CALLS"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# AC4 — the collapsed repo is classified by job block, and a deleted per-role
# stub is never read back or recreated.
# ---------------------------------------------------------------------------

@test "AC4(a): a repo whose agent-ingress job blocks byte-match the canonical blocks classifies ALIGNED" {
  publish_canonicals
  # Same job blocks, different header comment: the comparison is per block.
  sed '2s/.*/# Agent Ingress (repo-local header)/' "$MARKETS_INGRESS" \
    | put_file "petry-projects/markets" "$INGRESS_STUB"

  run_monitor petry-projects/markets
  [ "$status" -eq 0 ]
  local label
  for label in Dev-lead Pr-auto-review Pr-review Pr-review-mention Ci-failure-analyst; do
    [ "$(role_counts "$label")" = "$(counts_line 1 0 0)" ]
  done
  [ "$(jq -c . "${WORK}/fleet_stub_drift.json")" = "[]" ]
}

@test "AC4(b): a collapsed repo is never classified from a standalone <role>.yml" {
  publish_canonicals
  # Collapsed without pr-review; stale standalone files are still on disk and
  # differ from their legacy canonicals, so reading them would show DRIFTED.
  drop_job pr-review < "$MARKETS_INGRESS" | put_file "petry-projects/markets" "$INGRESS_STUB"
  printf 'name: stale\n' | put_file "petry-projects/markets" ".github/workflows/pr-review.yml"
  printf 'name: stale\n' | put_file "petry-projects/markets" ".github/workflows/dev-lead.yml"

  run_monitor petry-projects/markets
  [ "$status" -eq 0 ]
  [ "$(role_counts Pr-review)" = "$(counts_line 0 0 1)" ]
  [ "$(role_counts Dev-lead)" = "$(counts_line 1 0 0)" ]
  [ "$(jq -c . "${WORK}/fleet_stub_drift.json")" = "[]" ]
  local role
  for role in "${ROLES[@]}"; do
    run grep -F "repos/petry-projects/markets/contents/.github/workflows/${role}.yml" "$CALLS"
    [ "$status" -eq 1 ]
  done
}

@test "AC4(b): remediation of a collapsed repo never creates or restores .github/workflows/<role>.yml" {
  publish_canonicals
  drop_job pr-review < "$MARKETS_INGRESS" | put_file "petry-projects/markets" "$INGRESS_STUB"
  # Every role reported DRIFTED, including pr-review, whose block was removed.
  drift_json="${WORK}/drift.json"
  local role
  for role in "${ROLES[@]}"; do
    jq -n --arg r "$role" --arg sf "$INGRESS_STUB" \
      '{repo: "petry-projects/markets", status: "DRIFTED", repo_sha: "1", canonical_sha: "2",
        stub: $r, stub_file: $sf, role: $r}'
  done | jq -s . > "$drift_json"

  # The plan only ever targets agent-ingress.yml, never a per-role file.
  source "$REMEDIATE"
  plan="$(build_remediation_plan "$drift_json")"
  [ "$(printf '%s' "$plan" | jq 'length')" -eq 5 ]
  [ "$(printf '%s' "$plan" | jq -r '[.[].stub_file] | unique | join(",")')" = "$INGRESS_STUB" ]

  # A live run: the four present blocks already match canon; pr-review is refused.
  run env DRY_RUN=false REMEDIATE_PILOT_REPO=petry-projects/markets bash "$REMEDIATE" "$drift_json"
  [[ "$output" == *"has no 'pr-review' job block — refusing to recreate a removed stub"* ]]
  for role in "${ROLES[@]}"; do
    run grep -F "contents/.github/workflows/${role}.yml" "$CALLS"
    [ "$status" -eq 1 ]
  done
  # Every write went to agent-ingress.yml: one PUT per present block, none for
  # the removed pr-review block.
  puts="$(grep -F -- "--method PUT" "$CALLS")"
  [ "$(printf '%s\n' "$puts" | wc -l)" -eq 4 ]
  [ -z "$(printf '%s\n' "$puts" | grep -v -F "contents/${INGRESS_STUB}")" ]
  run grep -F "remediate drifted pr-review job block" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "AC4(c): a repo without agent-ingress.yml still classifies from its legacy <role>.yml" {
  publish_canonicals
  put_file "petry-projects/legacy" ".github/workflows/dev-lead.yml" \
    < "${FAKE_ROOT}/petry-projects/.github/standards/workflows/dev-lead.yml"
  printf 'name: drifted\n' | put_file "petry-projects/legacy" ".github/workflows/pr-auto-review.yml"
  # No published legacy canonical for pr-review: cannot be compared, so MISSING.
  printf 'name: anything\n' | put_file "petry-projects/legacy" ".github/workflows/pr-review.yml"

  run_monitor petry-projects/legacy
  [ "$status" -eq 0 ]
  [ "$(role_counts Dev-lead)" = "$(counts_line 1 0 0)" ]
  [ "$(role_counts Pr-auto-review)" = "$(counts_line 0 1 0)" ]
  [ "$(role_counts Pr-review)" = "$(counts_line 0 0 1)" ]
  [ "$(role_counts Pr-review-mention)" = "$(counts_line 0 0 1)" ]
  [ "$(role_counts Ci-failure-analyst)" = "$(counts_line 0 0 1)" ]
  grep -qF "repos/petry-projects/legacy/contents/.github/workflows/dev-lead.yml" "$CALLS"
}
