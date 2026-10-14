#!/usr/bin/env bats
# Regression tests for .github/workflows/feature-ideation.yml compliance.
#
# Guards the invariants checked by the weekly org compliance audit
# (check: non-stub-feature-ideation.yml). The stub now pins the reusable to
# the feature-ideation/next channel tag (the sanctioned ring-release
# mechanism — see the mutable-ref exception in AGENTS.md and
# docs/release/versioning.md) rather than the former @v1 SHA (#629).
#
# Run with: bats tests/test_feature_ideation.bats

FEATURE_IDEATION_YML=".github/workflows/feature-ideation.yml"

# Canonical reusable + channel pin from
# petry-projects/.github/standards/workflows/feature-ideation.yml
REUSABLE="petry-projects/.github/.github/workflows/feature-ideation-reusable.yml"
# This repo pins the v1-next ring channel (major-scope repin #657).
CHANNEL="feature-ideation/v1-next"

setup() {
  # Run tests from repo root so relative paths resolve correctly.
  cd "$(dirname "$BATS_TEST_FILENAME")/.."
}

@test "feature-ideation.yml exists" {
  [ -f "$FEATURE_IDEATION_YML" ]
}

@test "feature-ideation.yml calls the org reusable workflow" {
  grep -qF "uses: ${REUSABLE}@" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml pins the reusable to the configured channel tag" {
  grep -F "uses: ${REUSABLE}@" "$FEATURE_IDEATION_YML"
  grep -qF "uses: ${REUSABLE}@${CHANNEL}" "$FEATURE_IDEATION_YML"
}

# ── #934: operator-triggered enhancement backfill ────────────────────────────
# The folded feature-ideation reusable gains a backlog-sweep mode (porting the
# legacy standalone enhancer sweep). The stub exposes it as a boolean workflow_dispatch input
# and forwards it, matching the canonical stub template so the sync is drift-free.

@test "feature-ideation.yml exposes the enhance_backlog backfill-sweep input" {
  # Declared as a workflow_dispatch input…
  grep -qE '^[[:space:]]+enhance_backlog:' "$FEATURE_IDEATION_YML"
  # …and forwarded to the reusable via the prep job's output (not the `inputs`
  # context — see the #571 guard below).
  grep -qE 'enhance_backlog:[[:space:]]*\$\{\{[[:space:]]*fromJSON\(needs\.prep\.outputs\.enhance_backlog\)[[:space:]]*\}\}' "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml forwards enhance_backlog to the reusable workflow" {
  # Routed through the prep job's output; fromJSON casts the 'true'/'false' string
  # back to the boolean the reusable's typed input requires. Sourcing it from
  # ${{ inputs.enhance_backlog }} would fail at workflow setup on discussion (#571).
  grep -qE 'enhance_backlog:[[:space:]]*\$\{\{[[:space:]]*fromJSON\(needs\.prep\.outputs\.enhance_backlog\)[[:space:]]*\}\}' "$FEATURE_IDEATION_YML"
}

# ── #1827: tooling_ref must ride the same ring as the reusable ────────────────
# The reusable checks out its Python tooling (requirements file, collect/validate
# scripts) from petry-projects/.github at inputs.tooling_ref, which DEFAULTS to
# the `v1` release tag. This repo rides the `next` ring (the reusable is pinned at
# @feature-ideation/v1-next), but the stale `v1` tag predates
# scripts/feature-ideation-requirements.txt — so "Install Python jsonschema" dies
# with "Could not open requirements file", failing every schedule/dispatch run.
# The stub must forward tooling_ref pinned to the same channel as the reusable so
# workflow + tooling stay in lockstep. tooling_ref IS declared in the pinned
# channel's workflow_call.inputs, so this forward is not a channel-skew defect.

@test "feature-ideation.yml forwards tooling_ref pinned to the same ring as the reusable" {
  # Assert on the REACHABLE reusable invocation (jobs.ideate.with) — not a
  # grep-anywhere scan. A whole-file grep would still pass if tooling_ref were
  # moved out of ideate.with into some other mapping, silently letting the ideate
  # job fall back to the reusable's default `v1` tooling ref (which predates
  # scripts/feature-ideation-requirements.txt) and resurrecting the #1827 install
  # failure. Sourcing it structurally also makes the check robust to any YAML
  # quoting style around the value, since yq parses the document.
  yq -e ".jobs.ideate.with.tooling_ref == \"${CHANNEL}\"" "$FEATURE_IDEATION_YML" >/dev/null
}

# ── #963: discussion→dispatch redispatch bridge ──────────────────────────────
# claude-code-action aborts on `discussion` event contexts ("Unsupported event
# type: discussion"). So on `discussion: created` we must NOT call the reusable
# inline — instead a `redispatch` job re-invokes this stub via workflow_dispatch
# (which the action supports), mirroring initiative-planner.yml's #618 bridge.
# The `ideate` reusable call then runs only on workflow_dispatch/schedule.

@test "feature-ideation.yml declares a target_discussion workflow_dispatch input" {
  # The dispatched run carries the new Discussion number through this input so
  # single-idea enhancement runs under workflow_dispatch (where the action works).
  # The redispatch bridge forwards it (-f target_discussion=) and the prep job
  # surfaces it to the reusable's with: block.
  grep -qE '^[[:space:]]+target_discussion:' "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml has a redispatch job that runs only on the discussion event" {
  grep -qE '^[[:space:]]+redispatch:' "$FEATURE_IDEATION_YML"
  # The redispatch job is gated to the discussion event.
  grep -qE "github\.event_name[[:space:]]*==[[:space:]]*['\"]discussion['\"]" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml redispatch job keeps the ideas-category / non-bot guard" {
  grep -qE "github\.event\.discussion\.category\.slug[[:space:]]*==[[:space:]]*['\"]ideas['\"]" "$FEATURE_IDEATION_YML"
  grep -qE "github\.event\.discussion\.user\.type[[:space:]]*!=[[:space:]]*['\"]Bot['\"]" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml redispatch requires GH_PAT_WORKFLOWS (GITHUB_TOKEN won't start a run)" {
  # A workflow_dispatch fired with GITHUB_TOKEN is accepted but never starts a
  # run (loop prevention) — same constraint as the initiative-planner bridge.
  grep -qF "secrets.GH_PAT_WORKFLOWS" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml redispatch forwards target_discussion via workflow_dispatch" {
  grep -qF "gh workflow run feature-ideation.yml" "$FEATURE_IDEATION_YML"
  grep -qE -- '(-f|--field)[[:space:]]+"?target_discussion=' "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml ideate job no longer runs on the discussion event" {
  # The reusable call (single-idea/scan) must run under workflow_dispatch/schedule
  # only; the discussion event is handled by the redispatch bridge.
  grep -qE "github\.event_name[[:space:]]*!=[[:space:]]*['\"]discussion['\"]" "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml sources target_discussion from the prep job output" {
  # Routed via needs.prep.outputs (not ${{ inputs.target_discussion }}) so the
  # reusable with: compiles on the discussion event instead of failing at setup
  # with zero jobs (#571).
  grep -qE 'target_discussion:[[:space:]]*\$\{\{[[:space:]]*needs\.prep\.outputs\.target_discussion[[:space:]]*\}\}' "$FEATURE_IDEATION_YML"
}

@test "feature-ideation.yml routes every reusable input through prep — no inputs.* in with: (#571)" {
  # A reusable with: that references ${{ inputs.* }} is evaluated at workflow
  # setup regardless of the calling job's if:, so it fails the whole run (zero
  # jobs) on the discussion trigger. All dispatch inputs must be resolved in the
  # prep job and passed via needs.prep.outputs.*. Comments are excluded so this
  # guard does not trip on the explanatory notes in the stub.
  run bash -c "grep -vE '^[[:space:]]*#' '$FEATURE_IDEATION_YML' | grep -qE '\\\$\{\{[[:space:]]*inputs\\.'"
  [ "$status" -ne 0 ]
}

# ── #985: structural guard binding the off-discussion gate to the reusable call ──
# The grep-anywhere check above passes as long as the "!= 'discussion'" string
# exists *somewhere* in the file — it does NOT verify the gate sits on the job
# that actually invokes the reusable. A regression that moved the `uses:` call
# onto an unguarded (or discussion-handling) job would slip through it while
# resurrecting the exact "Unsupported event type: discussion" failure that
# degraded this workflow (#985). These yq-based tests pin the invariant
# structurally: every job that calls the reusable must be gated off the
# discussion event, and the discussion handler must not call it inline.

@test "feature-ideation.yml: every reusable-calling job is gated off the discussion event" {
  # At least one job must call the reusable (guard against a vacuous pass)…
  local total ungated
  total="$(yq '[.jobs[] | select((.uses // "") | test("feature-ideation-reusable.yml"))] | length' "$FEATURE_IDEATION_YML")"
  [ "$total" -ge 1 ]
  # …and none of them may run on a discussion event (claude-code-action aborts there).
  # A job is "ungated" if its if: lacks the event_name != 'discussion' guard, OR if it
  # contains || (which could let a second OR-branch re-enable execution on discussions).
  ungated="$(yq '[.jobs[] | select((.uses // "") | test("feature-ideation-reusable.yml")) | select(((.if // "") | test("event_name *!= *.discussion.") | not) or ((.if // "") | test("[|][|]")))] | length' "$FEATURE_IDEATION_YML")"
  [ "$ungated" -eq 0 ]
}

@test "feature-ideation.yml: the discussion handler reaches the reusable only via the dispatch bridge" {
  # The redispatch job handles the discussion event; it must NOT call the
  # reusable inline (which would re-introduce the abort) — it re-dispatches
  # under workflow_dispatch instead.
  [ "$(yq '.jobs.redispatch.uses' "$FEATURE_IDEATION_YML")" = "null" ]
}
