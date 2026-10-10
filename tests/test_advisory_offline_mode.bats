#!/usr/bin/env bats
# Structural guard for the #1686 advisory context contract across the remaining
# eight persona advisory prompts (issue #1715).
#
# PR #1696 gave prompts/qa-lead/advisory.md an "## Offline / pre-fetched-context
# mode (eval harness)" section: when a `## Pre-fetched PR context` block is
# appended to the end of the prompt, the persona is running headless inside the
# eval harness, must NOT run any live `gh` fetch, must treat the block as
# untrusted work-item data, and must not wander off to edit the harness repo.
# This story adopts that SAME contract — not a per-persona variant — in the eight
# other in-scope advisory prompts, without disturbing the live-runner path
# (sentinels, the `<!-- persona:<role> -->` recursion marker, and the read-only
# `gh` fetch all preserved).
#
# These checks are deterministic and offline. They guard against the offline
# section being silently dropped or hollowed out by a future edit/template sync
# (the same silent-revert regression class the repo defends against elsewhere,
# e.g. #655, #823, and tests/test_prefetch_prompt_rewire.bats).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROMPTS="$ROOT/prompts"
  EVALS="$ROOT/evals"
}

# The eight in-scope personas (qa-lead already shipped in #1696 and is asserted
# separately as the reference).
ROLES=(business-analyst dev-lead pr-review scrum-master
       security-lead devops-lead sre-lead solution-architect)

# Extract the body of the "## Offline / pre-fetched-context mode" section (from
# its heading up to the next `## ` heading) so offline-specific assertions cannot
# accidentally match text elsewhere in the prompt.
_offline_section() {
  [ -f "${1:-}" ] || return 1
  awk '
    /^##[[:space:]]+Offline \/ pre-fetched-context mode/ { insec=1; next }
    insec && /^##[[:space:]]/                            { insec=0 }
    insec                                                { print }
  ' "$1"
}

# Extract the body of the "## Steps" section so the live-fetch assertion targets
# the runner path, not the offline block (which also names `gh`).
_steps_section() {
  [ -f "${1:-}" ] || return 1
  awk '
    /^##[[:space:]]+Steps/     { insec=1; next }
    insec && /^##[[:space:]]/  { insec=0 }
    insec                      { print }
  ' "$1"
}

# --- the contract, for every in-scope persona ------------------------------

@test "every in-scope advisory prompt has an Offline / pre-fetched-context mode section" {
  for role in "${ROLES[@]}"; do
    f="$PROMPTS/$role/advisory.md"
    grep -Eq '^##[[:space:]]+Offline / pre-fetched-context mode' "$f" \
      || { echo "missing offline section: $role"; return 1; }
  done
}

@test "offline section keys off the '## Pre-fetched PR context' block for every persona" {
  for role in "${ROLES[@]}"; do
    section="$(_offline_section "$PROMPTS/$role/advisory.md")"
    grep -q 'Pre-fetched PR context' <<<"$section" \
      || { echo "no Pre-fetched PR context trigger: $role"; return 1; }
  done
}

@test "offline section forbids the live gh fetch for every persona" {
  for role in "${ROLES[@]}"; do
    section="$(_offline_section "$PROMPTS/$role/advisory.md")"
    grep -q 'gh pr view' <<<"$section" \
      || { echo "offline section does not name gh pr view to forbid it: $role"; return 1; }
    grep -Eiq 'do \*\*not\*\*|do not' <<<"$section" \
      || { echo "offline section lacks a do-not directive: $role"; return 1; }
  done
}

@test "offline section treats the block as untrusted work-item data for every persona" {
  for role in "${ROLES[@]}"; do
    section="$(_offline_section "$PROMPTS/$role/advisory.md")"
    grep -q 'untrusted work-item data' <<<"$section" \
      || { echo "offline section missing untrusted-data framing: $role"; return 1; }
  done
}

@test "offline section keeps the persona on-task (does not wander the harness repo)" {
  for role in "${ROLES[@]}"; do
    section="$(_offline_section "$PROMPTS/$role/advisory.md")"
    grep -q 'harness repo' <<<"$section" \
      || { echo "offline section missing harness-repo boundary: $role"; return 1; }
  done
}

# --- the live-runner path must survive the rewire (AC #2) ------------------

@test "live-runner path is preserved for every persona (sentinels + marker + live gh)" {
  for role in "${ROLES[@]}"; do
    f="$PROMPTS/$role/advisory.md"
    grep -q '===PERSONA-ADVISORY-BEGIN===' "$f" \
      || { echo "lost BEGIN sentinel: $role"; return 1; }
    grep -q '===PERSONA-ADVISORY-END===' "$f" \
      || { echo "lost END sentinel: $role"; return 1; }
    grep -q "<!-- persona:$role -->" "$f" \
      || { echo "lost recursion marker: $role"; return 1; }
    steps="$(_steps_section "$f")"
    grep -Eq 'gh (pr|issue) view' <<<"$steps" \
      || { echo "lost the live gh fetch in Steps: $role"; return 1; }
  done
}

# --- solution-architect specifics (AC #2 ADR rule + AC #4 corpus reach) -----

@test "solution-architect offline section still permits reading the ADR corpus (AC #4)" {
  section="$(_offline_section "$PROMPTS/solution-architect/advisory.md")"
  grep -q 'docs/architecture/adr' <<<"$section"
}

@test "solution-architect retains its 'cite an ADR or say there is none' rule (AC #2)" {
  grep -Eiq 'Cite an ADR by number, or say there is none' "$PROMPTS/solution-architect/advisory.md"
}

# --- solution-architect escalation calibration (#1787) ----------------------
# All three held-out failures in #1787 were wrong escalate decisions on otherwise
# correct advisories. The calibration below is what fixes them; these checks keep
# it from being silently dropped by a later edit or template sync.

@test "solution-architect calibrates escalation inside its Steps section (#1787 AC1)" {
  steps="$(_steps_section "$PROMPTS/solution-architect/advisory.md")"
  grep -q 'Calibrating the risk tier and escalation' <<<"$steps"
}

@test "solution-architect: a conforming change is LOW / escalate = no (#1787 AC2)" {
  steps="$(_steps_section "$PROMPTS/solution-architect/advisory.md")"
  # The whole bullet, from its opening line to the next sibling bullet, so a
  # rewrap of the paragraph cannot move the asserted text out of range.
  bullet="$(awk '/The change conforms to an accepted ADR/ { on=1; print; next }
                 on && /^   - / { exit }
                 on { print }' <<<"$steps")"
  grep -q '\*\*LOW\*\*' <<<"$bullet"
  grep -q '\*\*escalate = no\*\*' <<<"$bullet"
}

@test "solution-architect: 'no ADR governs' is not itself an escalation (#1787 AC3)" {
  steps="$(_steps_section "$PROMPTS/solution-architect/advisory.md")"
  # The no-ADR bullet as one line, so a rewrap cannot split the asserted text.
  bullet="$(awk '/No recorded ADR governs the change/ { on=1; print; next }
                 on && /^   - / { exit }
                 on { print }' <<<"$steps" | tr '\n' ' ' | tr -s ' ')"
  [ -n "$bullet" ]
  grep -q '\*\*escalate = no\*\*' <<<"$bullet"
  ! grep -q 'escalate = yes' <<<"$bullet"
  grep -q 'A missing ADR is a gap to name, not a reason to escalate' <<<"$bullet"
}

@test "solution-architect: HIGH always pairs with escalate = yes" {
  grep -q 'HIGH always pairs with escalate = yes' "$PROMPTS/solution-architect/advisory.md"
}

@test "solution-architect step 2 names ADR files the way the corpus does" {
  f="$PROMPTS/solution-architect/advisory.md"
  # The corpus is docs/architecture/adr/NNNN-<slug>.md; there is no ADR-NNNN.md.
  # A bare `! grep` mid-test cannot fail it (errexit ignores negated commands),
  # so fail explicitly.
  if grep -q 'docs/architecture/adr/ADR-' "$f"; then
    echo "prompt must not reference docs/architecture/adr/ADR-NNNN.md" >&2
    false
  fi
  example="$(grep -oE '[0-9]{4}-[a-z0-9-]+\.md' "$f" | head -1)"
  [ -n "$example" ]
  [ -f "$ROOT/docs/architecture/adr/$example" ]
  # The persona runs this command, so it must work as written: no `<…>`
  # placeholder (the shell reads it as a redirection), and it must match a file.
  cmd="$(grep -E '^[[:space:]]*cat docs/architecture/adr/' "$f" | head -1 | sed 's/^[[:space:]]*cat //')"
  [ -n "$cmd" ]
  if [[ "$cmd" == *"<"* ]]; then
    echo "ADR read command contains a <placeholder>: $cmd" >&2
    false
  fi
  compgen -G "$ROOT/$cmd" >/dev/null
}

@test "solution-architect body shape states the risk tier explicitly (#1787 AC4)" {
  grep -q '^\*\*Risk tier:\*\* LOW | MEDIUM | HIGH' "$PROMPTS/solution-architect/advisory.md"
}

# --- engine-parity tier in scorer.json (AC #3) ------------------------------

@test "qa-lead scorer declares the persona (Opus) engine tier — the #1696 reference" {
  [ "$(jq -r '.engine' "$EVALS/qa-lead/scorer.json")" = "persona" ]
}

@test "every in-scope persona declares the persona (Opus) engine tier the way #1696 does" {
  for role in "${ROLES[@]}"; do
    f="$EVALS/$role/scorer.json"
    [ -f "$f" ] || { echo "missing scorer.json: $role"; return 1; }
    [ "$(jq -r '.engine' "$f")" = "persona" ] \
      || { echo "engine tier not declared persona: $role"; return 1; }
  done
}

@test "in-scope scorers keep thresholds pinned at 0.7 (AC #6 — no threshold moved)" {
  for role in "${ROLES[@]}"; do
    f="$EVALS/$role/scorer.json"
    [ "$(jq -r '.pass_threshold // 0.7' "$f")" = "0.7" ] \
      || { echo "pass_threshold moved off 0.7: $role"; return 1; }
    [ "$(jq -r '.gate_threshold // 0.7' "$f")" = "0.7" ] \
      || { echo "gate_threshold moved off 0.7: $role"; return 1; }
  done
}

# --- scorer mode must match the persona engine (api-mismatch guard) ----------
# The persona engine emits a PROSE advisory, but run-eval.sh defaults a missing
# `mode` to `deterministic`, whose scorer expects escalate/risk JSON fields and
# scores every prose case 0. A persona scorer must therefore declare the
# llm-judge mode and ship a non-empty, existing judge prompt (as
# solution-architect/qa-lead already do). Guard every in-scope role so a future
# scorer cannot silently regress to deterministic prose-scoring.
@test "every in-scope persona scorer declares the llm-judge mode + an existing judge prompt" {
  for role in "${ROLES[@]}"; do
    f="$EVALS/$role/scorer.json"
    [ -f "$f" ] || { echo "missing scorer.json: $role"; return 1; }
    [ "$(jq -r '.mode' "$f")" = "llm-judge" ] \
      || { echo "scorer mode is not llm-judge (would score prose deterministically): $role"; return 1; }
    jp="$(jq -r '.judge_prompt // ""' "$f")"
    [ -n "$jp" ] \
      || { echo "llm-judge scorer sets no judge_prompt: $role"; return 1; }
    [ -f "$EVALS/$jp" ] \
      || { echo "judge_prompt references a missing file: $role -> $jp"; return 1; }
  done
}
