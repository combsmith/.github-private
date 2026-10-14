#!/usr/bin/env bats
# Tests for personas/validate-personas.py — the persona manifest validator.
# Exercises the cross-invariants (id==dir==canary.agent, layer paths exist,
# eval splits present) hermetically against a minimal test-double schema, so no
# network and no copy of the canonical schema (which lives in petry-projects/.github)
# is needed. The live check against the real schema is the `validate-personas`
# CI job in lint.yml.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  VALIDATOR="$ROOT/personas/validate-personas.py"
  TMP="$(mktemp -d)"

  # Minimal test-double schema: enough shape for the validator to run, NOT a
  # copy of the canonical schema.
  cat >"$TMP/schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["id"],
  "properties": {
    "id": {"type": "string", "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$"}
  }
}
JSON

  # Framework-agent fixture for vendor_pin invariant tests.
  mkdir -p "$TMP/frameworks/demo-fw"
  printf '# Vendored framework\n\nPin: v1.2.3\n' >"$TMP/frameworks/demo-fw/VENDOR.md"

  # Local canary-rings registry for non-draft invariant tests.
  printf '{"agents": {"demo": {}}}\n' >"$TMP/registry.json"

  # A self-contained, valid fixture persona.
  mkdir -p "$TMP/personas/demo" "$TMP/agents" "$TMP/evals/demo/dev" "$TMP/evals/demo/holdout"
  printf -- '---\nname: demo\n---\n' >"$TMP/agents/demo.md"
  printf '{"id": "d1"}\n' >"$TMP/evals/demo/dev/cases.jsonl"
  printf '{"id": "h1"}\n' >"$TMP/evals/demo/holdout/cases.jsonl"
  cat >"$TMP/personas/demo/persona.yml" <<'YAML'
id: demo
name: Demo
title: Demo Persona
summary: A fixture persona for validator tests.
status: draft
owner: petry-projects/org-leads
definition:
  layers:
    - kind: copilot-profile
      path: agents/demo.md
triggers:
  default_mode: advisory
  opt_out_label: demo:hands-off
  surfaces: []
trust:
  author_association_floor: [OWNER]
runtime:
  identity:
    account: demo
    credential: GH_PAT_DEMO
evals:
  required_before: stable
  path: evals/demo/
  min_cases: 1
canary:
  registry: petry-projects/.github/standards/canary-rings.json
  agent: demo
YAML
}

teardown() { rm -rf "$TMP"; }

@test "validate-personas accepts a well-formed manifest" {
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "validate-personas rejects id that does not match its directory" {
  sed -i 's/^id: demo/id: other/' "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"directory name"* ]]
}

@test "validate-personas rejects canary.agent that does not match id" {
  sed -i 's/^  agent: demo/  agent: nope/' "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canary.agent"* ]]
}

@test "validate-personas rejects a missing definition layer path" {
  rm -f "$TMP/agents/demo.md"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "validate-personas rejects a missing eval split" {
  rm -rf "$TMP/evals/demo/holdout"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"holdout"* ]]
}

@test "validate-personas rejects an id that violates kebab-case" {
  sed -i 's/^id: demo/id: Demo_ID/' "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
}

@test "validate-personas is a no-op when there is no personas root" {
  run python3 "$VALIDATOR" "$TMP/nonexistent" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas rejects a framework-agent with mismatched vendor_pin" {
  cat >"$TMP/personas/demo/persona.yml" <<'YAML'
id: demo
name: Demo
title: Demo Persona
summary: A fixture persona for validator tests.
status: draft
owner: petry-projects/org-leads
definition:
  layers:
    - kind: framework-agent
      path: agents/demo.md
      framework:
        name: demo-fw
        vendor_pin: v9.9.9
        skill: demo
triggers:
  default_mode: advisory
  opt_out_label: demo:hands-off
  surfaces: []
trust:
  author_association_floor: [OWNER]
runtime:
  identity:
    account: demo
    credential: GH_PAT_DEMO
evals:
  required_before: stable
  path: evals/demo/
  min_cases: 1
canary:
  registry: petry-projects/.github/standards/canary-rings.json
  agent: demo
YAML
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"vendor_pin"* ]]
}

@test "validate-personas accepts a non-draft persona with a registry entry" {
  sed -i 's/^status: draft/status: stable/' "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json" --registry "$TMP/registry.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas rejects a non-draft persona without a registry entry" {
  sed -i 's/^status: draft/status: stable/' "$TMP/personas/demo/persona.yml"
  printf '{"agents": {}}\n' >"$TMP/empty-registry.json"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json" --registry "$TMP/empty-registry.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agents.demo"* ]]
}

# --- ADR-0006: registration is CONDITIONAL on the manifest's own `canary` block ---
#
# A persona WITH a canary block ships its own reusable — past draft it must be
# registered (the two tests above). A persona WITHOUT one rides the shared
# persona runtime: no caller pins a per-persona channel tag, so it is never
# registered. For it, "past draft and unregistered" is the NORMAL state and a
# registry entry is the defect. These two tests pin that inversion.

@test "validate-personas accepts a non-draft shared-runtime persona (no canary) that is unregistered" {
  python3 -c "from pathlib import Path; p = Path(\"$TMP/personas/demo/persona.yml\"); txt = p.read_text().replace('status: draft', 'status: stable'); p.write_text(''.join(l for l in txt.splitlines(True) if not any(l.strip().startswith(k) for k in ('canary:', 'registry:', 'agent:'))))"
  printf '{"agents": {}}\n' >"$TMP/empty-registry.json"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json" --registry "$TMP/empty-registry.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "validate-personas rejects a shared-runtime persona (no canary) that IS registered" {
  python3 -c "from pathlib import Path; p = Path(\"$TMP/personas/demo/persona.yml\"); txt = p.read_text().replace('status: draft', 'status: stable'); p.write_text(''.join(l for l in txt.splitlines(True) if not any(l.strip().startswith(k) for k in ('canary:', 'registry:', 'agent:'))))"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json" --registry "$TMP/registry.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"defect, not a promotion"* ]]
}

# The registry prohibition is UNCONDITIONAL of status (ADR-0006): a shared-runtime
# persona ID is a defect in the registry draft or not, so even a DRAFT persona
# with no canary block must be rejected when an agents.<id> entry exists.
@test "validate-personas rejects a DRAFT shared-runtime persona (no canary) that IS registered" {
  python3 -c "from pathlib import Path; p = Path(\"$TMP/personas/demo/persona.yml\"); p.write_text(''.join(l for l in p.read_text().splitlines(True) if not any(l.strip().startswith(k) for k in ('canary:', 'registry:', 'agent:'))))"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json" --registry "$TMP/registry.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"defect, not a promotion"* ]]
}

@test "validate-personas still checks canary.agent when the block IS present" {
  python3 -c "from pathlib import Path; p = Path(\"$TMP/personas/demo/persona.yml\"); p.write_text(p.read_text().replace('agent: demo', 'agent: nope'))"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canary.agent"* ]]
  [[ "$output" != *"Traceback"* ]]
}

# --- Addressing (§4.1): handle slug == id, and handles are unique fleet-wide ---
#
# The live team properties (exists / privacy: closed / notifications_disabled)
# are deliberately NOT covered here — they need the network, and this suite is
# hermetic. Those are the `verify-persona-teams` CI job's job.

# add_address <persona-dir> <handle> — append an address block.
add_address() {
  local dir="$1" handle="$2"
  printf 'address:\n  handle: %s\n' "$handle" >>"$TMP/personas/$dir/persona.yml"
}

# clone_persona <new-id> — a second, self-contained fixture persona.
clone_persona() {
  local id="$1"
  mkdir -p "$TMP/personas/$id" "$TMP/evals/$id/dev" "$TMP/evals/$id/holdout"
  printf '{"id": "d1"}\n' >"$TMP/evals/$id/dev/cases.jsonl"
  printf '{"id": "h1"}\n' >"$TMP/evals/$id/holdout/cases.jsonl"
  sed -e "s/^id: demo/id: $id/" \
      -e "s/^  opt_out_label: demo:hands-off/  opt_out_label: $id:hands-off/" \
      -e "s|^  path: evals/demo/|  path: evals/$id/|" \
      -e "s/^  agent: demo/  agent: $id/" \
      "$TMP/personas/demo/persona.yml" >"$TMP/personas/$id/persona.yml"
}

@test "validate-personas accepts a manifest whose address handle slug matches its id" {
  add_address demo petry-projects/demo
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas rejects an address handle whose team slug != id" {
  add_address demo petry-projects/something-else
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"!= id 'demo'"* ]]
}



@test "validate-personas accepts distinct handles across personas" {
  add_address demo petry-projects/demo
  clone_persona rival
  add_address rival petry-projects/rival
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas ignores personas with no address block" {
  clone_persona rival
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

# Malformed-address diagnostics. Unreachable against the canonical schema (its
# pattern guarantees 'org/team-slug'), but the validator accepts --schema, so a
# test double or a stale local copy can let these through. The contract is a
# diagnostic, not a traceback.

@test "validate-personas reports a bare handle with no org prefix" {
  add_address demo demo
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"org/team-slug"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "validate-personas reports a non-string handle" {
  printf 'address:\n  handle: 42\n' >>"$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"org/team-slug"* ]]
  [[ "$output" != *"Traceback"* ]]
}



# --- eval gate: paths (multi-skill) + the min_cases count (principle 5) --------

@test "validate-personas accepts evals.paths with all splits present" {
  mkdir -p "$TMP/evals/skill-a/dev" "$TMP/evals/skill-a/holdout" \
           "$TMP/evals/skill-b/dev" "$TMP/evals/skill-b/holdout"
  printf '{"id":"a1"}\n' | tee "$TMP/evals/skill-a/dev/cases.jsonl" "$TMP/evals/skill-a/holdout/cases.jsonl" \
    "$TMP/evals/skill-b/dev/cases.jsonl" "$TMP/evals/skill-b/holdout/cases.jsonl" >/dev/null
  # swap path -> paths in the fixture manifest
  sed 's#^  path: evals/demo/#  paths: [evals/skill-a/, evals/skill-b/]#' "$TMP/personas/demo/persona.yml" > "$TMP/personas/demo/persona.yml.tmp" && mv "$TMP/personas/demo/persona.yml.tmp" "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas rejects evals.paths when ONE set is missing a split" {
  mkdir -p "$TMP/evals/skill-a/dev" "$TMP/evals/skill-a/holdout" "$TMP/evals/skill-b/dev"
  printf '{"id":"a1"}\n' | tee "$TMP/evals/skill-a/dev/cases.jsonl" "$TMP/evals/skill-a/holdout/cases.jsonl" \
    "$TMP/evals/skill-b/dev/cases.jsonl" >/dev/null  # skill-b has NO holdout
  sed 's#^  path: evals/demo/#  paths: [evals/skill-a/, evals/skill-b/]#' "$TMP/personas/demo/persona.yml" > "$TMP/personas/demo/persona.yml.tmp" && mv "$TMP/personas/demo/persona.yml.tmp" "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"skill-b"* ]]
  [[ "$output" == *"holdout"* ]]
}

@test "validate-personas does NOT enforce min_cases while draft (seed cases allowed)" {
  # holdout has 1 case; min_cases 5; status draft -> count NOT enforced.
  sed 's/^  min_cases: 1/  min_cases: 5/' "$TMP/personas/demo/persona.yml" > "$TMP/personas/demo/persona.yml.tmp" && mv "$TMP/personas/demo/persona.yml.tmp" "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas ENFORCES min_cases once status reaches required_before" {
  # required_before stable, status stable, holdout has 1 case < min_cases 5 -> FAIL.
  sed -e 's/^  min_cases: 1/  min_cases: 5/' \
      -e 's/^status: draft/status: stable/' "$TMP/personas/demo/persona.yml" > "$TMP/personas/demo/persona.yml.tmp" && mv "$TMP/personas/demo/persona.yml.tmp" "$TMP/personas/demo/persona.yml"
  printf '{"agents":{"demo":{}}}\n' >"$TMP/reg.json"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json" --registry "$TMP/reg.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"placeholder evals"* ]]
}

@test "validate-personas passes the count gate when enough held-out cases exist" {
  printf '{"id":"h1"}\n{"id":"h2"}\n{"id":"h3"}\n{"id":"h4"}\n{"id":"h5"}\n' > "$TMP/evals/demo/holdout/cases.jsonl"
  sed -e 's/^  min_cases: 1/  min_cases: 5/' \
      -e 's/^status: draft/status: stable/' "$TMP/personas/demo/persona.yml" > "$TMP/personas/demo/persona.yml.tmp" && mv "$TMP/personas/demo/persona.yml.tmp" "$TMP/personas/demo/persona.yml"
  printf '{"agents":{"demo":{}}}\n' >"$TMP/reg.json"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json" --registry "$TMP/reg.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas count gate ignores blank lines in holdout" {
  printf '{"id":"h1"}\n\n{"id":"h2"}\n' > "$TMP/evals/demo/holdout/cases.jsonl"  # 2 real, 1 blank
  sed -e 's/^  min_cases: 1/  min_cases: 3/' \
      -e 's/^status: draft/status: stable/' "$TMP/personas/demo/persona.yml" > "$TMP/personas/demo/persona.yml.tmp" && mv "$TMP/personas/demo/persona.yml.tmp" "$TMP/personas/demo/persona.yml"
  printf '{"agents":{"demo":{}}}\n' >"$TMP/reg.json"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json" --registry "$TMP/reg.json"
  [ "$status" -ne 0 ]  # only 2 real < 3
  [[ "$output" == *"2 held-out"* ]]
}

@test "validate-personas REQUIRES runtime.identity" {
  # Strip the runtime.identity block -> every persona must declare who it acts as.
  sed '/^runtime:$/,/^    credential:/d' "$TMP/personas/demo/persona.yml" > "$TMP/personas/demo/persona.yml.tmp" && mv "$TMP/personas/demo/persona.yml.tmp" "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing runtime.identity"* ]]
}

@test "validate-personas enforces the GH_PAT_<ACCOUNT> credential convention" {
  # A non-grandfathered credential that isn't GH_PAT_* is rejected.
  sed 's/^    credential: GH_PAT_DEMO/    credential: DEMO_TOKEN/' "$TMP/personas/demo/persona.yml" > "$TMP/personas/demo/persona.yml.tmp" && mv "$TMP/personas/demo/persona.yml.tmp" "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GH_PAT_<ACCOUNT>"* ]]
}

@test "validate-personas rejects identity missing the 'credential' key" {
  # identity present but credential key omitted -> defensive check catches it cleanly.
  sed '/^    credential:/d' "$TMP/personas/demo/persona.yml" > "$TMP/personas/demo/persona.yml.tmp"
  mv "$TMP/personas/demo/persona.yml.tmp" "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime.identity must be a mapping"* ]]
}

@test "validate-personas rejects credential that does not match the declared account name" {
  # GH_PAT_OTHER starts with GH_PAT_ but account is 'demo' — expected GH_PAT_DEMO.
  sed 's/^    credential: GH_PAT_DEMO/    credential: GH_PAT_OTHER/' "$TMP/personas/demo/persona.yml" > "$TMP/personas/demo/persona.yml.tmp"
  mv "$TMP/personas/demo/persona.yml.tmp" "$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GH_PAT_<ACCOUNT>"* ]]
}

# --- skills[] validation: path existence + name<->directory agreement (#1649) ---
#
# skills[] is the persona's declarative skill inventory. Each entry's path must
# exist on disk (mirroring the definition.layers[].path check), and when it points
# at a `<name>/SKILL.md` the parent directory must equal the entry name — the
# vendored-skill convention every persona follows. This is hermetic (filesystem
# existence only, no network), like the rest of this suite.

# add_skill <persona-dir> <name> <path> — append a one-entry skills[] block.
add_skill() {
  local dir="$1" name="$2" path="$3"
  printf 'skills:\n  - name: %s\n    path: %s\n    source: vendored\n' "$name" "$path" >>"$TMP/personas/$dir/persona.yml"
}

@test "validate-personas accepts a skills[] entry whose path exists and name matches its directory" {
  mkdir -p "$TMP/frameworks/demo-fw/src/workflows/demo-skill"
  printf '# skill\n' >"$TMP/frameworks/demo-fw/src/workflows/demo-skill/SKILL.md"
  add_skill demo demo-skill frameworks/demo-fw/src/workflows/demo-skill/SKILL.md
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas rejects a skills[] path that does not exist" {
  add_skill demo demo-skill frameworks/demo-fw/src/workflows/demo-skill/SKILL.md
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"skills[0].path"* ]]
  [[ "$output" == *"does not exist"* ]]
}

@test "validate-personas accepts a persona with no skills[]" {
  # base demo has no skills block; add an explicit empty list to be sure.
  printf 'skills: []\n' >>"$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas rejects a skills[] entry whose name disagrees with its SKILL.md directory" {
  mkdir -p "$TMP/frameworks/demo-fw/src/workflows/actual-dir"
  printf '# skill\n' >"$TMP/frameworks/demo-fw/src/workflows/actual-dir/SKILL.md"
  add_skill demo wrong-name frameworks/demo-fw/src/workflows/actual-dir/SKILL.md
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wrong-name"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "validate-personas rejects a skills[] absolute path that escapes the repo root" {
  add_skill demo passwd /etc/passwd
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"skills[0].path"* ]]
  [[ "$output" == *"inside the repository root"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "validate-personas rejects a skills[] path that traverses out with .." {
  add_skill demo escape ../../../../etc/passwd
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"skills[0].path"* ]]
  [[ "$output" == *"inside the repository root"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "validate-personas rejects a skills[] that is not a list" {
  printf 'skills: not-a-list\n' >>"$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'skills' must be a list"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "validate-personas rejects a skills[] entry with a non-string name or path" {
  printf 'skills:\n  - name: 123\n    path: 456\n' >>"$TMP/personas/demo/persona.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"string 'name' and 'path'"* ]]
  [[ "$output" != *"Traceback"* ]]
}

# --- surface liveness: every enabled surface is served by a deployed workflow (#1647) ---
#
# The derived surface<->workflow invariant (AC #2/#5): a persona may declare a
# surface `enabled: true` ONLY if its `interaction.yml` records an event that
# actually serves it. The mapping is derived from interaction.yml's
# `interaction.triggers.events[]`, never hand-maintained. A persona with no
# interaction.yml is SKIPPED (logged ::notice::, not failed) — interaction.yml is
# the derivation SOURCE, so its absence is a different defect with its own issue.
# These cases are hermetic (no network), like the rest of this suite.

# set_surfaces <persona-dir> — replace triggers.surfaces from a YAML snippet on stdin.
set_surfaces() {
  local dir="$1"
  # Use `-c` (not `python3 -`) so the heredoc YAML stays on stdin for the script
  # to read, rather than being consumed as the script source itself.
  python3 -c '
import sys, yaml
path = sys.argv[1]
m = yaml.safe_load(open(path))
m["triggers"]["surfaces"] = yaml.safe_load(sys.stdin.read())
yaml.safe_dump(m, open(path, "w"), sort_keys=False)
' "$TMP/personas/$dir/persona.yml"
}

# write_interaction <persona-dir> <event> [<event> ...] — write an interaction.yml
# declaring the given triggers.events.
write_interaction() {
  local dir="$1"; shift
  {
    printf 'schema_version: 1\nrole: %s\nkind: persona\n' "$dir"
    printf 'workflows:\n  - .github/workflows/persona-mention.yml\n'
    printf 'interaction:\n  triggers:\n    events:\n'
    local e
    for e in "$@"; do printf '      - %s\n' "$e"; done
    printf '    timers: []\n'
  } >"$TMP/personas/$dir/interaction.yml"
}

@test "validate-personas accepts an enabled surface served by interaction.yml events" {
  set_surfaces demo <<'YAML'
- surface: pull_request
  events: [opened]
  enabled: true
  mode: advisory
YAML
  write_interaction demo pull_request
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "validate-personas rejects an enabled surface that no deployed workflow serves" {
  set_surfaces demo <<'YAML'
- surface: check_run
  events: [completed]
  enabled: true
  mode: advisory
YAML
  write_interaction demo issue_comment pull_request_review_comment
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"check_run"* ]]
  [[ "$output" == *"no deployed workflow serves"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "validate-personas does NOT check a disabled unserved surface" {
  set_surfaces demo <<'YAML'
- surface: check_run
  events: [completed]
  enabled: false
  mode: advisory
YAML
  write_interaction demo issue_comment
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas SKIPS surface liveness when a persona has no interaction.yml" {
  set_surfaces demo <<'YAML'
- surface: check_run
  events: [completed]
  enabled: true
  mode: advisory
YAML
  # no interaction.yml written -> skip (notice), do NOT fail
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  [[ "$output" == *"no interaction.yml"* ]]
  [[ "$output" == *"demo"* ]]
}

@test "validate-personas serves the mention surface via comment events" {
  set_surfaces demo <<'YAML'
- surface: mention
  events: [created]
  enabled: true
  mode: advisory
YAML
  write_interaction demo issue_comment pull_request_review_comment discussion_comment
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas serves the mention surface via a repository_dispatch bridge" {
  set_surfaces demo <<'YAML'
- surface: mention
  events: [created]
  enabled: true
  mode: advisory
YAML
  write_interaction demo check_suite pull_request repository_dispatch:demo-mention
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

# AC #5 — manifest/contract agreement cannot silently diverge: re-enabling a
# surface the contract does not serve fails, even when other surfaces are served.
@test "validate-personas catches a manifest/contract divergence (one served, one not)" {
  set_surfaces demo <<'YAML'
- surface: mention
  events: [created]
  enabled: true
  mode: advisory
- surface: discussion
  events: [labeled, commented]
  enabled: true
  mode: advisory
  bridge: repository_dispatch
YAML
  # mention is served (issue_comment); discussion is NOT (no `discussion` event,
  # and the repository_dispatch bridge nothing sends).
  write_interaction demo issue_comment pull_request_review_comment discussion_comment
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"discussion"* ]]
  [[ "$output" == *"no deployed workflow serves"* ]]
  [[ "$output" != *"Traceback"* ]]
}

# check_run and check_suite are DISTINCT GitHub webhooks — a check_suite-only
# workflow does not serve a check_run surface (regression: they were once
# conflated, letting a check-suite-only persona pass a check_run surface).
@test "validate-personas rejects a check_run surface served only by check_suite" {
  set_surfaces demo <<'YAML'
- surface: check_run
  events: [completed]
  enabled: true
  mode: advisory
YAML
  write_interaction demo check_suite
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"check_run"* ]]
  [[ "$output" == *"no deployed workflow serves"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "validate-personas accepts a check_run surface served by check_run" {
  set_surfaces demo <<'YAML'
- surface: check_run
  events: [completed]
  enabled: true
  mode: advisory
YAML
  write_interaction demo check_run
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

# Only the router's mention-bridge dispatch (repository_dispatch:<role>-mention)
# serves the mention surface — an unrelated repository_dispatch (e.g. a persona's
# ci-failure/issue-retry bridge) must NOT falsely validate it.
@test "validate-personas rejects a mention surface served only by an unrelated repository_dispatch" {
  set_surfaces demo <<'YAML'
- surface: mention
  events: [created]
  enabled: true
  mode: advisory
YAML
  write_interaction demo repository_dispatch:demo-ci-failure
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mention"* ]]
  [[ "$output" == *"no deployed workflow serves"* ]]
  [[ "$output" != *"Traceback"* ]]
}

# A malformed interaction.yml must fail with a clean diagnostic, never an
# AttributeError traceback (interaction.yml is not schema-validated before parsing).
@test "validate-personas fails cleanly when interaction.interaction is not a mapping" {
  set_surfaces demo <<'YAML'
- surface: mention
  events: [created]
  enabled: true
  mode: advisory
YAML
  printf 'schema_version: 1\ninteraction: "not a mapping"\n' \
    >"$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'interaction' must be a mapping"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "validate-personas fails cleanly when interaction.triggers is not a mapping" {
  set_surfaces demo <<'YAML'
- surface: mention
  events: [created]
  enabled: true
  mode: advisory
YAML
  printf 'schema_version: 1\ninteraction:\n  triggers: "not a mapping"\n' \
    >"$TMP/personas/demo/interaction.yml"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'interaction.triggers' must be a mapping"* ]]
  [[ "$output" != *"Traceback"* ]]
}

# --- Standards pinning: channel default, N-1 acceptance, loud fallback (#1707) ---
#
# The schema + registry are read from the org standards repo the way any consumer
# reads a published standard. #1707: that read was pinned to the org repo's DEFAULT
# BRANCH, so a merge there flipped the pass/fail verdict of every open PR here (the
# 2026-09-07 outage red-lined the fleet 21 seconds after an org-repo schema tighten).
# The fix pins to a versioned moving channel, accepts N-1 for the schema during a
# promotion window, and makes an unreachable-ref fallback LOUD instead of silently
# widening back to the default branch. These cases exercise the pure resolution
# logic hermetically (ADR-0004) — no network.

@test "validate-personas default schema ref is the channel, not main (#1707 AC #2)" {
  VP="$VALIDATOR" run python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("vp", os.environ["VP"])
vp = importlib.util.module_from_spec(spec); spec.loader.exec_module(vp)
assert vp.STANDARDS_CHANNEL == "standards/v1-stable", vp.STANDARDS_CHANNEL
# The default plan must not reintroduce the default-branch coupling.
plan = vp.schema_ref_plan(None, vp.STANDARDS_CHANNEL, None)
assert plan == [("standards/v1-stable", "channel")], plan
assert all(ref != "main" for ref, _ in plan), plan
print("OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "validate-personas schema_ref_plan: env override short-circuits channel + N-1 (#1707 AC #5)" {
  VP="$VALIDATOR" run python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("vp", os.environ["VP"])
vp = importlib.util.module_from_spec(spec); spec.loader.exec_module(vp)
# An explicit PERSONA_SCHEMA_REF is explicit: exactly that ref, no channel/N-1 widening.
plan = vp.schema_ref_plan("feature/x", "standards/v1-stable", "standards/v1.0.0")
assert plan == [("feature/x", "PERSONA_SCHEMA_REF")], plan
print("OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "validate-personas schema_ref_plan: channel then N-1, in that order (#1707 AC #3/#5)" {
  VP="$VALIDATOR" run python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("vp", os.environ["VP"])
vp = importlib.util.module_from_spec(spec); spec.loader.exec_module(vp)
plan = vp.schema_ref_plan(None, "standards/v1-stable", "standards/v1.0.0")
assert plan == [("standards/v1-stable", "channel"),
                ("standards/v1.0.0", "N-1")], plan
print("OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "validate-personas current_and_previous picks the two highest semver releases (#1707 AC #3)" {
  VP="$VALIDATOR" run python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("vp", os.environ["VP"])
vp = importlib.util.module_from_spec(spec); spec.loader.exec_module(vp)
tags = ["standards/v1-stable", "standards/v1.0.0", "standards/v1.2.0", "standards/v1.10.0"]
cur, prev = vp.current_and_previous(tags)
assert cur == "standards/v1.10.0", cur   # numeric, not lexical (10 > 2)
assert prev == "standards/v1.2.0", prev
# With a single release there is no N-1.
cur1, prev1 = vp.current_and_previous(["standards/v1.0.0", "standards/v1-stable"])
assert cur1 == "standards/v1.0.0" and prev1 is None, (cur1, prev1)
# No releases at all -> (None, None), never raising.
assert vp.current_and_previous([]) == (None, None)
print("OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "validate-personas previous_in_channel scopes N-1 to the channel's major line (#1707 review)" {
  VP="$VALIDATOR" run python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("vp", os.environ["VP"])
vp = importlib.util.module_from_spec(spec); spec.loader.exec_module(vp)
# A repo carrying both a v1 and a v2 release line. Pinned to v1-stable, N-1 must be
# the v1 release below the newest v1 — NEVER a v2 release from an unrelated line.
tags = ["standards/v1.0.0", "standards/v1.2.0", "standards/v2.0.0", "standards/v2.1.0"]
assert vp.previous_in_channel(tags, "standards/v1-stable") == "standards/v1.0.0", \
    vp.previous_in_channel(tags, "standards/v1-stable")
# Pinned to v2-stable, N-1 is the v2 release below the newest v2.
assert vp.previous_in_channel(tags, "standards/v2-stable") == "standards/v2.0.0", \
    vp.previous_in_channel(tags, "standards/v2-stable")
# Only one release in the channel's line -> no N-1 (never crosses into v1's line).
assert vp.previous_in_channel(["standards/v1.0.0", "standards/v2.0.0"],
                              "standards/v2-stable") is None
# A channel with no v<MAJOR>- shape imposes no filter (global newest-below: v2.0.0).
assert vp.previous_in_channel(tags, "some-branch") == "standards/v2.0.0", \
    vp.previous_in_channel(tags, "some-branch")
# The major parser: standards/v1-stable -> 1, v2-next -> 2, non-channel -> None.
assert vp._channel_major("standards/v1-stable") == 1
assert vp._channel_major("standards/v2-next") == 2
assert vp._channel_major("main") is None
print("OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "validate-personas previous_relative_to_target takes N-1 below the channel's CURRENT target, not the newest tag (#1707 review)" {
  VP="$VALIDATOR" run python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("vp", os.environ["VP"])
vp = importlib.util.module_from_spec(spec); spec.loader.exec_module(vp)
tags = ["standards/v1.0.0", "standards/v1.1.0", "standards/v1.2.0"]
prt = vp.previous_relative_to_target
# v1.2.0 is cut but the channel still targets v1.1.0 -> N-1 is v1.0.0, NOT v1.1.0
# (the channel's own target must never masquerade as its N-1).
assert prt(tags, "standards/v1-stable", "standards/v1.1.0") == "standards/v1.0.0", \
    prt(tags, "standards/v1-stable", "standards/v1.1.0")
# Channel at the newest release -> N-1 is the one below it.
assert prt(tags, "standards/v1-stable", "standards/v1.2.0") == "standards/v1.1.0"
# Channel at the oldest release -> nothing below it.
assert prt(tags, "standards/v1-stable", "standards/v1.0.0") is None
# Unresolvable target -> degrade to newest-below (previous_in_channel semantics).
assert prt(tags, "standards/v1-stable", None) == "standards/v1.1.0"
# A target from an unrelated major is not in the channel's line -> degrade, never cross.
assert prt(tags, "standards/v1-stable", "standards/v2.0.0") == "standards/v1.1.0"
print("OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "validate-personas first_schema_error accepts a manifest valid under N-1 though it fails N (#1707 AC #3)" {
  VP="$VALIDATOR" run python3 - <<'PY'
import importlib.util, os
import jsonschema
spec = importlib.util.spec_from_file_location("vp", os.environ["VP"])
vp = importlib.util.module_from_spec(spec); spec.loader.exec_module(vp)
# N (current) tightened to require 'reusable'; N-1 (previous) did not.
schema_new = {"type": "object", "required": ["id", "reusable"]}
schema_old = {"type": "object", "required": ["id"]}
v_new = jsonschema.Draft202012Validator(schema_new)
v_old = jsonschema.Draft202012Validator(schema_old)
manifest = {"id": "demo"}  # lacks 'reusable' — the 2026-09-07 shape
# Accepted because it validates under N-1 (the propagation window).
assert vp.first_schema_error(manifest, [("channel", v_new), ("N-1", v_old)]) is None
# Without the N-1 tolerance it fails, and the reported failure is the FIRST (current) version.
res = vp.first_schema_error(manifest, [("channel", v_new)])
assert res is not None and res[0] == "channel", res
print("OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "validate-personas fallback warning is loud and names both refs, never a silent widen (#1707 AC #4)" {
  VP="$VALIDATOR" run python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("vp", os.environ["VP"])
vp = importlib.util.module_from_spec(spec); spec.loader.exec_module(vp)
msg = vp.fallback_warning("persona schema", "standards/v1-stable", "main")
assert msg.startswith("::warning::"), msg           # a visible annotation
assert "standards/v1-stable" in msg, msg            # the ref it WANTED
assert "main" in msg, msg                           # the ref it USED
print("OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "validate-personas an unreachable explicit PERSONA_SCHEMA_REF fails, never widens to main (#1707 review)" {
  VP="$VALIDATOR" run python3 - <<'PY'
import importlib.util, os
os.environ["PERSONA_SCHEMA_REF"] = "feature/does-not-exist"
spec = importlib.util.spec_from_file_location("vp", os.environ["VP"])
vp = importlib.util.module_from_spec(spec); spec.loader.exec_module(vp)
# Every ref unreachable — record which refs were attempted so we can prove no widen.
attempts = []
def fake_fetch(path, ref):
    attempts.append(ref)
    return None
vp._fetch_json_at = fake_fetch
failed = False
try:
    vp.load_schemas(None)
except SystemExit as e:                # fail() exits non-zero, never returns a schema
    failed = (e.code == 1)
assert failed, "an unreachable explicit pin must fail, not return a schema"
# The exact pin is honoured: only that ref is tried, never a widen to the 'main' fallback.
assert attempts == ["feature/does-not-exist"], attempts
assert "main" not in attempts, attempts
print("OK")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "validate-personas reports a malformed schema document as a diagnostic, not a traceback (#1707 review)" {
  # 'type' must be a string or array of strings — 12345 is not a valid JSON Schema.
  printf '{"type": 12345}\n' >"$TMP/bad-schema.json"
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/bad-schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema"* ]]
  [[ "$output" != *"Traceback"* ]]
}
