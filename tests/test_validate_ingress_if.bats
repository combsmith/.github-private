#!/usr/bin/env bats
# Tests for scripts/validate-ingress-if.sh — the if:-as-event-filter-only guard
# for ADR-0007 agent-ingress jobs (#1725 AC #3, epic #1723).
#
# An ingress job's `if:` is the ONE place ADR-0007 loosens ADR-0001: it may
# reference ONLY the delivered event (github.event_name / github.event.action /
# plain payload predicates) and MUST NOT reach for repo state (vars, secrets,
# another job's computed outputs, the repo tree via hashFiles, repo identity, the
# payload's standing default_branch, or the standing labels array).
#
# The frozen ALLOW/FORBID rulings live as a machine-readable table at
# tests/fixtures/agent-ingress/if-filter-rulings.tsv. This guard and this test
# BOTH consume that table directly (QA test-risk #8: one parameterised table, not
# two suites), so they cannot drift apart on an ambiguous construct.
#
# Run: bats tests/test_validate_ingress_if.bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/validate-ingress-if.sh"
  RULINGS="${REPO_ROOT}/tests/fixtures/agent-ingress/if-filter-rulings.tsv"
  SAMPLES="${REPO_ROOT}/tests/fixtures/agent-ingress/ingress-samples"
  # shellcheck source=scripts/validate-ingress-if.sh
  source "$SCRIPT"
}

# ---------------------------------------------------------------------------
# viif_forbidden — the pure event-filter boundary detector. Given an if:
# expression, print the FORBID construct name(s) it reaches for; empty + 0 if it
# is a pure event filter.
# ---------------------------------------------------------------------------

@test "viif_forbidden: a pure event-name predicate is allowed (no forbidden token)" {
  run viif_forbidden "github.event_name == 'issue_comment'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "viif_forbidden: an org/repo config variable is forbidden" {
  run viif_forbidden "github.event_name == 'pull_request' && vars.DEV_LEAD_ENGINE == 'claude'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vars"* ]]
}

@test "viif_forbidden: the singular label delta is allowed but the standing labels array is forbidden" {
  run viif_forbidden "github.event.label.name == 'agent-ready'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run viif_forbidden "contains(github.event.pull_request.labels.*.name, 'agent-ready')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"labels-array-contains"* ]]
}

@test "viif_forbidden: base.ref is allowed but repository.default_branch is forbidden" {
  run viif_forbidden "github.event.pull_request.base.ref == 'main'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run viif_forbidden "github.event.repository.default_branch == 'main'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"default-branch"* ]]
}

@test "viif_forbidden: repo identity reached via the event payload is forbidden too" {
  # github.repository is not the only path to repo identity — the same identity
  # rides in the delivered payload as github.event.repository.{name,full_name,
  # owner.login,...}. Gating a role on WHICH repo it is is enrollment/config
  # regardless of the spelling, so repo-identity must catch these too.
  run viif_forbidden "github.event.repository.name == 'some-repo'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo-identity"* ]]

  run viif_forbidden "github.event.repository.full_name == 'petry-projects/some-repo'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo-identity"* ]]

  run viif_forbidden "github.event.repository.owner.login == 'petry-projects'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo-identity"* ]]
}

@test "viif_forbidden: indexed context access reaches the same repo state as dot access (#1772)" {
  # A denylist that matches dot notation only lets x['y'] bypass it. The guard
  # normalizes bracket access first, so each indexed form must be rejected AND
  # name the same construct as its dot twin.
  run viif_forbidden "vars['DEV_LEAD_ENGINE'] == 'claude'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"vars"* ]]

  run viif_forbidden "secrets['CLAUDE_CODE_OAUTH_TOKEN'] != ''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"secrets"* ]]

  run viif_forbidden "needs['detect'].outputs['should_run'] == 'true'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs-outputs"* ]]

  run viif_forbidden "github['repository'] == 'petry-projects/some-repo'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo-identity"* ]]

  run viif_forbidden "contains(github.event.pull_request['labels'].*.name, 'agent-ready')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"labels-array-contains"* ]]
}

@test "viif_forbidden: an unlisted context root is forbidden by the event-only allowlist (#1772)" {
  # The rulings are event-only: only github.event_name / github.event.* may
  # appear. A context root no FORBID row enumerates must still fail — a denylist
  # cannot enforce an "only" rule, so the allowlist backstop names it.
  run viif_forbidden "env.FOO == 'bar'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unlisted-context"* ]]

  run viif_forbidden "inputs.mode == 'apply'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unlisted-context"* ]]

  run viif_forbidden "steps.detect.outputs.run == 'true'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unlisted-context"* ]]

  # A non-event github.* reference (repo/runtime identity) is not the event.
  run viif_forbidden "github.actor == 'octocat'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unlisted-context"* ]]

  run viif_forbidden "github.ref == 'refs/heads/main'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unlisted-context"* ]]
}

@test "viif_forbidden: the event-only allowlist still permits the pure event predicates" {
  # Guard against the allowlist backstop over-blocking: the canonical event
  # references must remain clean passes.
  for ok in \
    "github.event_name == 'issue_comment'" \
    "github.event.action == 'review_requested'" \
    "github.event.label.name == 'agent-ready'" \
    "github.event.pull_request.base.ref == 'main'"; do
    run viif_forbidden "$ok"
    if [ "$status" -ne 0 ]; then
      echo "event predicate wrongly rejected: [$ok] output=[$output]"
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Bare context roots (#1781). A context referenced with no trailing dot —
# toJSON(secrets), fromJSON(toJSON(env)), or the root passed as any function
# argument — has no `.` for the dot-notation denylist or the allowlist backstop
# to bite, so it was ALLOWED. Detection must work on identifier TOKENS, and each
# bare root must fail AND name its construct in the message (AC #1, #4).
# ---------------------------------------------------------------------------

@test "viif_forbidden: a bare policed root serialized via toJSON is forbidden and names its construct (#1781)" {
  run viif_forbidden "toJSON(env) != ''"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unlisted-context"* ]]

  run viif_forbidden "contains(toJSON(vars), 'claude')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vars"* ]]

  run viif_forbidden "contains(toJSON(secrets), 'x')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"secrets"* ]]

  run viif_forbidden "contains(toJSON(needs), 'true')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs-outputs"* ]]

  run viif_forbidden "contains(toJSON(inputs), 'x')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unlisted-context"* ]]

  # Bare github serialized whole is the most severe reach — everything, not the
  # event. It is not the delivered event, so the allowlist backstop names it.
  run viif_forbidden "contains(toJSON(github), 'petry-projects/x')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unlisted-context"* ]]
}

@test "viif_forbidden: a bare root nested and passed as a function argument is still caught (#1781)" {
  run viif_forbidden "fromJSON(toJSON(secrets))"
  [ "$status" -eq 1 ]
  [[ "$output" == *"secrets"* ]]

  # The root as a plain right-hand value, no wrapping function at all.
  run viif_forbidden "steps != ''"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unlisted-context"* ]]
}

@test "viif_forbidden: named FORBID matching ignores policed names inside string literals (#1781, AC #2)" {
  # A quoted literal that merely mentions vars.X is NOT a repo-state reach — the
  # if: reads github.event.comment.body, an event field. Named matching runs on
  # the literal-stripped expression, the same way the allowlist backstop does.
  run viif_forbidden "contains(github.event.comment.body, 'set vars.X please')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # A bare policed name inside a literal must likewise not trip bare-root
  # detection (the whole point of stripping literals first).
  run viif_forbidden "contains(github.event.comment.body, 'please set env for me')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "viif_forbidden: context names are case-insensitive, so mixed/upper case roots stay FORBIDDEN" {
  # Actions expressions are case-insensitive, so VARS.X / Secrets.Y / GitHub.actor
  # reach the same repo state as their lowercase twins. A lowercase-only match
  # would let them bypass the guard — each must still be rejected and name its
  # construct.
  run viif_forbidden "VARS.DEV_LEAD_ENGINE == 'claude'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vars"* ]]

  run viif_forbidden "Secrets.CLAUDE_CODE_OAUTH_TOKEN != ''"
  [ "$status" -eq 1 ]
  [[ "$output" == *"secrets"* ]]

  run viif_forbidden "NEEDS.detect.outputs.should_run == 'true'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs-outputs"* ]]

  run viif_forbidden "contains(toJSON(Secrets), 'x')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"secrets"* ]]

  run viif_forbidden "GitHub.actor == 'octocat'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unlisted-context"* ]]

  run viif_forbidden "ENV.FOO == 'bar'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unlisted-context"* ]]
}

@test "viif_forbidden: #1725 dotted and bracket-indexed forms stay FORBIDDEN (#1781 AC #5)" {
  run viif_forbidden "github.event_name == 'pull_request' && vars.DEV_LEAD_ENGINE == 'claude'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vars"* ]]

  run viif_forbidden "secrets['CLAUDE_CODE_OAUTH_TOKEN'] != ''"
  [ "$status" -eq 1 ]
  [[ "$output" == *"secrets"* ]]

  run viif_forbidden "needs['detect'].outputs['should_run'] == 'true'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs-outputs"* ]]
}

# ---------------------------------------------------------------------------
# Parameterised over the FROZEN rulings table: every ALLOW row's representative
# expression must be permitted; every FORBID row's must be rejected AND name the
# construct. A newly added row is thereby answered for free, and the guard cannot
# silently under-enforce a declared FORBID construct.
# ---------------------------------------------------------------------------

@test "rulings table: every ALLOW row is permitted by the guard" {
  local name verdict expr rationale
  while IFS=$'\t' read -r name verdict expr rationale; do
    case "$name" in ''|'#'*) continue ;; esac
    [ "$verdict" = "ALLOW" ] || continue
    run viif_forbidden "$expr"
    if [ "$status" -ne 0 ]; then
      echo "ALLOW row '$name' was wrongly rejected: expr=[$expr] output=[$output]"
      return 1
    fi
  done < "$RULINGS"
}

@test "rulings table: every FORBID row is rejected and names its construct" {
  local name verdict expr rationale
  while IFS=$'\t' read -r name verdict expr rationale; do
    case "$name" in ''|'#'*) continue ;; esac
    [ "$verdict" = "FORBID" ] || continue
    run viif_forbidden "$expr"
    if [ "$status" -eq 0 ]; then
      echo "FORBID row '$name' was wrongly permitted: expr=[$expr]"
      return 1
    fi
    if [[ "$output" != *"$name"* ]]; then
      echo "FORBID row '$name' rejected but the construct name was not reported: output=[$output]"
      return 1
    fi
  done < "$RULINGS"
}

# ---------------------------------------------------------------------------
# File-level validation over fixture ingress files.
# ---------------------------------------------------------------------------

@test "file: a pure event-filter ingress passes" {
  run viif_validate_ingress "${SAMPLES}/good.yml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "file: an ingress whose job if: reaches for repo state FAILS with a named message" {
  run viif_validate_ingress "${SAMPLES}/repo-state.yml"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error"* ]]
  [[ "$output" == *"dev-lead"* ]]
  [[ "$output" == *"vars"* ]]
}

@test "file: a malformed/schema-invalid ingress FAILS (job with no reusable uses:)" {
  run viif_validate_ingress "${SAMPLES}/malformed.yml"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error"* ]]
  [[ "$output" == *"dev-lead"* ]]
}

# ---------------------------------------------------------------------------
# Job-level concurrency: (ADR-0010, #2002). A group may read only the event
# surface a job-level if: may read (checked with the SAME viif_forbidden
# predicate), must carry the role name as a prefix, and cancel-in-progress must
# be a literal boolean. Collision with the pinned reusable's own groups needs the
# reusable at its pinned ref, so validate-caller-inputs owns that half.
# ---------------------------------------------------------------------------

@test "viif_group_stems: a literal head is the stem; expression groups yield result-position format()/fallback literals only" {
  run viif_group_stems 'ci-failure-analyst-${{ github.event.check_run.head_sha }}'
  [ "$status" -eq 0 ]
  [ "$output" = "ci-failure-analyst-" ]

  run viif_group_stems "\${{ (github.event_name == 'pull_request' && format('pr-auto-review-pr-{0}', github.event.pull_request.number)) || 'pr-auto-review-batch' }}"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'pr-auto-review-batch\npr-auto-review-pr-')" ]

  # Nested format() arguments and function-call arguments are not group names.
  run viif_group_stems "\${{ format('pr-review-pr-{0}{1}', format('{0}/pull/{1}', github.event.x, github.event.y), '-x') || contains(github.event.z, 'nope') }}"
  [ "$status" -eq 0 ]
  [ "$output" = "pr-review-pr-" ]
}

@test "viif_group_exprs: a quoted }} does not close the expression; an unclosed tail is still emitted" {
  run viif_group_exprs "x-\${{ format('}}') }}"
  [ "$status" -eq 0 ]
  [ "$output" = " format('}}') " ]

  run viif_group_exprs "x-\${{ github.event.a == '}}' && 'y' }}-\${{ github.event.b }}"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"'}}'"* ]]

  run viif_group_exprs 'pr-review-${{ vars.lane'
  [ "$status" -eq 0 ]
  [ "$output" = " vars.lane" ]
  run viif_check_concurrency pr-review 'pr-review-${{ vars.lane' ""
  [ "$status" -eq 1 ]
}

@test "viif_group_stems: every expression of a multi-expression group is stem-checked" {
  run viif_group_stems "\${{ format('a-{0}', github.event.number) }}-\${{ format('b-{0}', github.event.number) }}"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a-\nb-')" ]
}

@test "concurrency: an explicit null cancel-in-progress fails" {
  run viif_validate_ingress "${SAMPLES}/concurrency-cancel-null.yml"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"literal boolean"* ]]
}

@test "concurrency: a bounded, role-prefixed group with a literal cancel-in-progress passes" {
  run viif_validate_ingress "${SAMPLES}/concurrency-good.yml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "concurrency: a group reaching repo state fails, via the same if: predicate" {
  run viif_validate_ingress "${SAMPLES}/concurrency-repo-state.yml"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error"* ]]
  [[ "$output" == *"'pr-review'"* ]]
  [[ "$output" == *"concurrency"* ]]
  [[ "$output" == *"vars"* ]]
}

@test "concurrency: a non-literal cancel-in-progress fails" {
  run viif_validate_ingress "${SAMPLES}/concurrency-cancel-expr.yml"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'pr-auto-review'"* ]]
  [[ "$output" == *"cancel-in-progress"* ]]
  [[ "$output" == *"literal boolean"* ]]
}

@test "concurrency: a group without the role-name prefix fails" {
  run viif_validate_ingress "${SAMPLES}/concurrency-no-prefix.yml"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'ci-failure-analyst'"* ]]
  [[ "$output" == *"role"* ]]
  [[ "$output" == *"ci-"* ]]
}

# ---------------------------------------------------------------------------
# Repo scan: no live agent-ingress.yml yet (it is a docs reference until the
# collapse story), so a scan of a tree without one is a clean pass — never a
# silent skip that hides an absent guard.
# ---------------------------------------------------------------------------

@test "scan: a tree with no agent-ingress.yml passes cleanly" {
  empty="$(mktemp -d "${BATS_TEST_TMPDIR}/root.XXXXXX")"
  mkdir -p "$empty/.github/workflows"
  run env VIIF_ROOT="$empty" bash "$SCRIPT"
  rm -rf "$empty"
  [ "$status" -eq 0 ]
}

@test "scan: a tree WITH a repo-state ingress fails" {
  root="$(mktemp -d "${BATS_TEST_TMPDIR}/root.XXXXXX")"
  mkdir -p "$root/.github/workflows"
  cp "${SAMPLES}/repo-state.yml" "$root/.github/workflows/agent-ingress.yml"
  run env VIIF_ROOT="$root" bash "$SCRIPT"
  rm -rf "$root"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vars"* ]]
}

@test "vci_job_for_uses: finds the job key for plain, commented, and quoted keys" {
  # shellcheck source=scripts/validate-caller-inputs.sh
  source "${REPO_ROOT}/scripts/validate-caller-inputs.sh"
  local f="${BATS_TEST_TMPDIR}/wf.yml"
  printf '%s\n' 'jobs:' '  plain: # note' '    uses: x/y/.github/workflows/a.yml@v1' \
    '  "dq":' '    uses: x/y/.github/workflows/b.yml@v1' \
    "  'sq':" '    uses: x/y/.github/workflows/c.yml@v1' > "$f"
  run vci_job_for_uses "$f" 3
  [ "$output" = "plain" ]
  run vci_job_for_uses "$f" 5
  [ "$output" = "dq" ]
  run vci_job_for_uses "$f" 7
  [ "$output" = "sq" ]
}

@test "viif_check_concurrency: an event-field branch beside a prefixed fallback is rejected (unprefixed leading result)" {
  run viif_check_concurrency pr-review "\${{ github.event.pull_request.title || 'pr-review-fallback' }}" "true"
  [ "$status" -eq 1 ]
  [[ "$output" == *"every possible leading result must begin with 'pr-review-'"* ]]
}

@test "viif_group_stems: an unreachable operand right of a truthy literal || is not a stem" {
  run viif_group_stems "\${{ 'pr-review-fixed' || github.event.action }}"
  [ "$status" -eq 0 ]
  [ "$output" = "pr-review-fixed" ]
}
