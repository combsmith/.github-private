#!/usr/bin/env bats
# Tests for the canonical agent-ingress.yml reference (issue #1724, epic #1723,
# ADR-0007). The reference is authored as a NON-executing artifact under docs/ and
# is made emittable via scripts/seed-repo-template.sh so it is a machine-consumable
# byte-identity baseline (template_stub_drift / downstream stories hash the
# emission) rather than existing only as prose (AC #3). These tests assert the
# canonical structure: union on:, one job per collapsed Class-1 role, per-job
# permissions + channel pin + agent_ref, role-bearing job names, and an
# event-filter-only if: on each job (AC #1, #2).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SEED="$SCRIPT_DIR/scripts/seed-repo-template.sh"
REF="$SCRIPT_DIR/docs/architecture/reference/agent-ingress.yml"

# Parse the emitted ingress into a stable, greppable projection of the PARSED job
# mapping so the contract assertions run against parsed structure, not a raw-text
# search — a substring match in raw output cannot prove it belongs to the expected
# job or to that job's if: expression, and cannot tell an if: value from a comment
# (coderabbit #1764). Emits one line per fact:
#   jobnames|<comma-joined, sorted job keys>
#   job|<name>|uses=<ref>|perms=<0|1>|if_present=<0|1>|agent_ref=<value|->
#   ifval|<name>|<that job's if: expression, whitespace-collapsed to one line>
# The ifval| lines let the if:-filter purity checks target ONLY extracted if:
# values — never comments or unrelated YAML.
_ingress_projection() {
  bash "$SEED" --emit-workflow agent-ingress.yml | python3 -c '
import sys, yaml
doc = yaml.safe_load(sys.stdin.read()) or {}
jobs = doc.get("jobs", {}) or {}
print("jobnames|" + ",".join(sorted(jobs)))
for name, spec in jobs.items():
    uses = spec.get("uses", "")
    perms = "1" if "permissions" in spec else "0"
    ifv = spec.get("if", "")
    aref = (spec.get("with") or {}).get("agent_ref", "-")
    print("job|%s|uses=%s|perms=%s|if_present=%s|agent_ref=%s" % (
        name, uses, perms, "1" if ifv else "0", aref))
    print("ifval|%s|%s" % (name, " ".join(str(ifv).split())))
'
}

@test "reference: the canonical agent-ingress.yml exists under docs/, NOT under .github/workflows" {
  [ -f "$REF" ]
  # A live workflow in .github/workflows/ would double-dispatch the per-role stubs
  # (behavior change forbidden by AC #5); the reference must not live there.
  [ ! -f "$SCRIPT_DIR/.github/workflows/agent-ingress.yml" ]
}

@test "emit-workflow: agent-ingress.yml emits the reference byte-for-byte" {
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$REF")" ]
}

@test "emit-workflow: unknown reference/stub name still fails loud" {
  run bash "$SEED" --emit-workflow no-such-ingress.yml
  # An unknown reference/stub name is a usage error → exit 2 specifically (the
  # `_emit_workflow` unknown-stub path), not just any non-zero, so a syntax or
  # command-not-found regression can't masquerade as the expected failure.
  [ "$status" -eq 2 ]
}

@test "reference: on: is the UNION of the collapsed roles' triggers (AC #1)" {
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  # dev-lead ∪ pr-review-mention subscriptions.
  [[ "$output" == *"pull_request:"* ]]
  [[ "$output" == *"pull_request_review:"* ]]
  [[ "$output" == *"pull_request_review_comment:"* ]]
  [[ "$output" == *"issue_comment:"* ]]
  [[ "$output" == *"issues:"* ]]
  [[ "$output" == *"check_run:"* ]]
  [[ "$output" == *"repository_dispatch:"* ]]
}

@test "reference: EXACTLY the dev-lead and pr-review-mention jobs, parsed from the mapping (AC #1)" {
  run _ingress_projection
  [ "$status" -eq 0 ]
  # Require EXACTLY these two collapsed roles from the parsed jobs mapping — no
  # more, no fewer — so a stray or missing job is caught, not just that the two
  # role tokens appear somewhere in raw text. Role-bearing keys keep runs
  # attributable by role (ADR-0007 consequence).
  [[ "$output" == *"jobnames|dev-lead,pr-review-mention"* ]]
}

@test "reference: each job carries its own permissions block, parsed per job (AC #1)" {
  run _ingress_projection
  [ "$status" -eq 0 ]
  # Per-job scopes asserted on the parsed mapping (a single dispatching job is
  # forbidden — it would need the union of every role's permissions).
  [[ "$output" == *"job|dev-lead|"*"perms=1"* ]]
  [[ "$output" == *"job|pr-review-mention|"*"perms=1"* ]]
  # Top-level least privilege is still a raw-text invariant of the emission.
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"permissions: {}"* ]]
}

@test "reference: each job's pinned first-party channel ref + agent_ref, asserted per parsed job (AC #1)" {
  run _ingress_projection
  [ "$status" -eq 0 ]
  # dev-lead: pinned to its v139-stable channel (ADR-0002; the pin moves from a
  # per-FILE tag to a per-JOB pin) with a MATCHING agent_ref forward.
  [[ "$output" == *"job|dev-lead|uses=petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v139-stable|"*"agent_ref=dev-lead/v139-stable"* ]]
  # pr-review-mention: pinned to its v2-next channel, and it forwards NO agent_ref.
  # The reference mirrors the real caller stub (.github/workflows/pr-review-mention.yml),
  # whose reusable declares no agent_ref input — forwarding one here would pass an
  # input the pinned pr-review-mention/v2-next channel does not declare (the
  # channel-skew defect, #1052), so agent_ref is asserted ABSENT (=-).
  [[ "$output" == *"job|pr-review-mention|uses=petry-projects/.github/.github/workflows/pr-review-mention-reusable.yml@pr-review-mention/v2-next|"*"agent_ref=-"* ]]
}

@test "reference: every job has an if: guard, parsed per job (AC #2)" {
  run _ingress_projection
  [ "$status" -eq 0 ]
  [[ "$output" == *"job|dev-lead|"*"if_present=1"* ]]
  [[ "$output" == *"job|pr-review-mention|"*"if_present=1"* ]]
}

@test "reference: the if: guards are PURE event filters — checks scoped to extracted if: values (AC #2)" {
  run _ingress_projection
  [ "$status" -eq 0 ]
  # Target ONLY the extracted if: expressions (ifval| lines). Scoping the
  # forbidden-construct checks to the parsed if: values — never comments or
  # unrelated YAML — means a word like "default_branch" in a doc comment cannot
  # trip the guard, and a secrets.* reach is caught where it matters (coderabbit #1764).
  ifvals="$(printf '%s\n' "$output" | grep '^ifval|')"
  [ -n "$ifvals" ]
  [[ "$ifvals" == *"github.event_name"* ]]
  # Forbidden repo-state / non-event reaches must NOT appear in any if: value.
  [[ "$ifvals" != *"vars."* ]]
  [[ "$ifvals" != *"secrets."* ]]
  [[ "$ifvals" != *"hashFiles("* ]]
  [[ "$ifvals" != *".outputs."* ]]
  [[ "$ifvals" != *"default_branch"* ]]
  [[ "$ifvals" != *"labels.*.name"* ]]
}

@test "reference: the ingress declares no steps/run — it stays a thin caller (ADR-0001)" {
  run bash "$SEED" --emit-workflow agent-ingress.yml
  [ "$status" -eq 0 ]
  [[ "$output" != *"steps:"* ]]
  # A step's `run:` directive is a key at the start of a (indented) line; match it
  # anchored so the `check_run:` union trigger does not read as a run step.
  run_steps="$(printf '%s\n' "$output" | grep -cE '^[[:space:]]*run:' || true)"
  [ "$run_steps" -eq 0 ]
}

@test "list-workflows: the ingress is NOT seeded into repo-template — still exactly 10 stubs (AC #5)" {
  run bash "$SEED" --list-workflows
  [ "$status" -eq 0 ]
  [[ "$output" != *"agent-ingress"* ]]
  n="$(printf '%s\n' "$output" | grep -c '\.yml$')"
  [ "$n" -eq 10 ]
}
