#!/usr/bin/env bats
# Tests for personas/validate-personas.py — the persona manifest validator.
# Exercises the cross-invariants (id==dir==canary.agent, layer paths exist,
# eval splits present) hermetically against a minimal test-double schema, so no
# network and no copy of the canonical schema (which lives in combsmith/.github)
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
owner: combsmith/org-leads
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
  registry: combsmith/.github/standards/canary-rings.json
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
owner: combsmith/org-leads
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
  registry: combsmith/.github/standards/canary-rings.json
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
  add_address demo combsmith/demo
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -eq 0 ]
}

@test "validate-personas rejects an address handle whose team slug != id" {
  add_address demo combsmith/something-else
  run python3 "$VALIDATOR" "$TMP/personas" --schema "$TMP/schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"!= id 'demo'"* ]]
}



@test "validate-personas accepts distinct handles across personas" {
  add_address demo combsmith/demo
  clone_persona rival
  add_address rival combsmith/rival
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
