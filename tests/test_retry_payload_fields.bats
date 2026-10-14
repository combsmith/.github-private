#!/usr/bin/env bats
# scripts/check-retry-payload-fields.sh (#2081) — fails when the dev-lead retry
# sweep sends a client_payload field that scripts/dev-lead-intent.sh at any
# channel of the pinned major does not read.
#
# The check EXECUTES the sweep's dispatchers with gh stubbed (sent side) and
# bash-parses the parser before collecting reads (read side), so these tests
# include the shapes the earlier text-pattern scanner got wrong (#2085 review):
# comments, punctuation inside quoted values, the gh -f form, sourced libs, and
# a stale tag when the fetch fails.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/check-retry-payload-fields.sh"

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$SANDBOX/.github/workflows" "$SANDBOX/scripts/lib"
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email t@example.com
  git -C "$SANDBOX" config user.name t
  unset CI GITHUB_ACTIONS
}

# write_stub <agent_ref>
write_stub() {
  cat > "$SANDBOX/.github/workflows/dev-lead.yml" <<EOF
jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@$1
    with:
      agent_ref: $1
EOF
}

# write_intent <field>... — an intent parser that reads each named field (and
# always `checks`, which every write_sweep dispatcher sends).
write_intent() {
  {
    echo '#!/usr/bin/env bash'
    echo 'route() {'
    for f in checks "$@"; do
      echo "  x=\$(jq -r '.client_payload.${f} // empty' \"\$EVENT_PATH\")"
    done
    echo '}'
  } > "$SANDBOX/scripts/dev-lead-intent.sh"
}

# write_sweep <field>... — a sweep with one jq-built dispatcher sending each field
# (plus a nested checks[] array that must not be compared).
write_sweep() {
  {
    echo '#!/usr/bin/env bash'
    echo 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
    echo 'source "$SCRIPT_DIR/lib/helper.sh"'
    echo 'dispatch_one() {'
    echo '  local repo="$1" n="$2"'
    echo '  local payload'
    echo "  payload=\$(jq -n --argjson n \"\$n\" '{"
    echo '    event_type: "dev-lead-reviews-retry",'
    echo '    client_payload: {'
    local f
    for f in "$@"; do echo "      ${f}: \$n,"; done
    echo '      checks: [{name: "x", nested_only: 1}]'
    echo '    }'
    echo "  }')"
    echo '  echo "$payload" | gh api --method POST "repos/${repo}/dispatches" --input - >/dev/null'
    echo '}'
  } > "$SANDBOX/scripts/dev-lead-retry.sh"
  [ -f "$SANDBOX/scripts/lib/helper.sh" ] || echo '#!/usr/bin/env bash' > "$SANDBOX/scripts/lib/helper.sh"
}

# tag_channels <tag>... — commit the tree and point each channel tag at it.
tag_channels() {
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit -qm "release" --allow-empty
  local t
  for t in "$@"; do git -C "$SANDBOX" tag -f "$t" >/dev/null; done
}

ALL=(dev-lead/v7-next dev-lead/v7-ring0 dev-lead/v7-ring1 dev-lead/v7-stable)

@test "passes when every channel reads every field the sweep sends" {
  write_stub dev-lead/v7-stable
  write_intent pr_number head_sha checks
  write_sweep pr_number head_sha
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"*"dev-lead/v7-stable"* ]]
}

# The #2050 / #2086 skew: the newer channels learned the field, stable did not.
@test "fails when an older channel's parser does not read a sent field" {
  write_stub dev-lead/v7-stable
  write_intent pr_number head_sha
  write_sweep pr_number head_sha
  tag_channels dev-lead/v7-ring1 dev-lead/v7-stable
  write_intent pr_number head_sha comment_node_id
  write_sweep pr_number head_sha comment_node_id
  tag_channels dev-lead/v7-next dev-lead/v7-ring0
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.comment_node_id (sent by dispatch_one) is not read by scripts/dev-lead-intent.sh at dev-lead/v7-ring1"* ]]
  [[ "$output" == *"at dev-lead/v7-stable"* ]]
  [[ "$output" != *"at dev-lead/v7-next"* ]]
  [[ "$output" != *"client_payload.pr_number"* ]]
}

@test "a parser COMMENT naming a field is not a read (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  printf '%s\n' '# TODO: read .client_payload.comment_node_id here' \
    'route2() { :; }  # client_payload.comment_node_id is not read yet' >> "$SANDBOX/scripts/dev-lead-intent.sh"
  write_sweep pr_number comment_node_id
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.comment_node_id"* ]]
}

@test "punctuation inside quoted payload values does not hide or invent fields (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number note
  write_sweep pr_number
  # A dispatcher whose string values contain commas, colons, braces and brackets.
  cat >> "$SANDBOX/scripts/dev-lead-retry.sh" <<'EOF'
dispatch_tricky() {
  jq -n '{event_type: "x", client_payload: {note: "a, fake: {b: [c]}, d", pr_number: 1, after: "]}"}}' \
    | gh api --method POST "repos/$1/dispatches" --input -
}
EOF
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.after (sent by dispatch_tricky)"* ]]
  [[ "$output" != *"client_payload.fake"* ]]
  [[ "$output" != *"client_payload.d "* ]]
}

@test "captures the gh -f client_payload[field]= form" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  cat >> "$SANDBOX/scripts/dev-lead-retry.sh" <<'EOF'
dispatch_fields() {
  gh api --method POST "repos/$1/dispatches" -f event_type=x -f "client_payload[pr_number]=$2" -F "client_payload[other_field]=1"
}
EOF
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.other_field (sent by dispatch_fields)"* ]]
  [[ "$output" != *"client_payload.pr_number"* ]]
}

@test "captures a named --input file request body (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  cat >> "$SANDBOX/scripts/dev-lead-retry.sh" <<'EOF2'
dispatch_file() {
  local f; f=$(mktemp)
  jq -n '{event_type: "x", client_payload: {pr_number: 1, file_field: 2}}' > "$f"
  gh api --method POST "repos/$1/dispatches" --input "$f"
  rm -f "$f"
}
EOF2
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.file_field (sent by dispatch_file)"* ]]
}

@test "every dispatch a function makes is checked, not only the last (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  cat >> "$SANDBOX/scripts/dev-lead-retry.sh" <<'EOF2'
dispatch_twice() {
  jq -n '{client_payload: {pr_number: 1, first_only: 1}}' | gh api --method POST "repos/$1/dispatches" --input -
  jq -n '{client_payload: {pr_number: 1}}' | gh api --method POST "repos/$1/dispatches" --input -
}
EOF2
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.first_only (sent by dispatch_twice)"* ]]
}

@test "a reference inside a jq comment is not a read (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  printf '%s\n' "route4() { jq -r '.client_payload.pr_number # .client_payload.jq_commented is not consumed' \"\$EVENT_PATH\"; }" \
    >> "$SANDBOX/scripts/dev-lead-intent.sh"
  write_sweep pr_number jq_commented
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.jq_commented"* ]]
}

@test "a lib the parser sources that is missing at a tag is a setup error (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  printf '%s\n' 'source "$(dirname "$0")/lib/not-there.sh"' >> "$SANDBOX/scripts/dev-lead-intent.sh"
  write_sweep pr_number
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read scripts/lib/not-there.sh"* ]]
}

@test "refreshing tags never makes a full clone shallow (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  tag_channels "${ALL[@]}"
  git -C "$SANDBOX" commit -qm second --allow-empty
  git clone -q "$SANDBOX" "$BATS_TEST_TMPDIR/clone"
  run bash "$CHECK" "$BATS_TEST_TMPDIR/clone"
  [ "$status" -eq 0 ]
  [ "$(git -C "$BATS_TEST_TMPDIR/clone" rev-parse --is-shallow-repository)" = false ]
}

@test "a dispatcher that sends a payload with no fields is a setup error (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  cat >> "$SANDBOX/scripts/dev-lead-retry.sh" <<'EOF2'
dispatch_empty() {
  jq -n '{event_type: "x", client_payload: {}}' | gh api --method POST "repos/$1/dispatches" --input -
}
EOF2
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"dispatch_empty"* ]]
}

@test "an endpoint held in a variable is a setup error, never a silent pass (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  cat >> "$SANDBOX/scripts/dev-lead-retry.sh" <<'EOF2'
DISPATCH_PATH="dispatches"
DISPATCH_EP="repos/o/r/$DISPATCH_PATH"
dispatch_indirect() {
  jq -n '{client_payload: {pr_number: 1, hidden_field: 1}}' | gh api --method POST "$DISPATCH_EP" --input -
}
EOF2
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"holds a /dispatches endpoint"* ]]
}

@test "an endpoint assembled in a dispatcher-local variable is still found (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  cat >> "$SANDBOX/scripts/dev-lead-retry.sh" <<'EOF2'
dispatch_local() {
  local ep="repos/$1/"
  ep+="dispatches"
  jq -n '{client_payload: {pr_number: 1, local_field: 1}}' | gh api --method POST "$ep" --input -
}
EOF2
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.local_field (sent by dispatch_local)"* ]]
}

@test "a read in a lib sourced by another parser lib counts as read (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  printf '%s\n' 'source "$(dirname "$0")/lib/first.sh"' >> "$SANDBOX/scripts/dev-lead-intent.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'source "$(dirname "${BASH_SOURCE[0]}")/../lib/second.sh"' \
    'source "$(dirname "${BASH_SOURCE[0]}")/../lib/first.sh"' > "$SANDBOX/scripts/lib/first.sh"
  printf '%s\n' '#!/usr/bin/env bash' "deep() { jq -r '.client_payload.deep_field' \"\$EVENT_PATH\"; }" \
    > "$SANDBOX/scripts/lib/second.sh"
  write_sweep pr_number deep_field
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "captures the attached --field= / --raw-field= / -f=k=v / -fk=v / --input= forms (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  cat >> "$SANDBOX/scripts/dev-lead-retry.sh" <<'EOF2'
dispatch_attached() {
  gh api --method POST "repos/$1/dispatches" -f "client_payload[pr_number]=1" \
    --field='client_payload[eq_field]=1' --raw-field='client_payload[raw_eq]=1' -F'client_payload[short_eq]=1' \
    -f'client_payload[lower_eq]=1' -F='client_payload[flag_eq]=1'
}
dispatch_input_eq() {
  local f; f=$(mktemp)
  jq -n '{client_payload: {pr_number: 1, input_eq: 1}}' > "$f"
  gh api --method POST "repos/$1/dispatches" --input="$f"
  rm -f "$f"
}
EOF2
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.eq_field (sent by dispatch_attached)"* ]]
  [[ "$output" == *"client_payload.raw_eq (sent by dispatch_attached)"* ]]
  [[ "$output" == *"client_payload.short_eq (sent by dispatch_attached)"* ]]
  [[ "$output" == *"client_payload.lower_eq (sent by dispatch_attached)"* ]]
  [[ "$output" == *"client_payload.flag_eq (sent by dispatch_attached)"* ]]
  [[ "$output" == *"client_payload.input_eq (sent by dispatch_input_eq)"* ]]
}

@test "a field named in a plain string (not a jq path) is not a read (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  printf '%s\n' "route5() { diagnostic='client_payload.prose_only is not consumed'; echo \"\$diagnostic\"; }" \
    >> "$SANDBOX/scripts/dev-lead-intent.sh"
  write_sweep pr_number prose_only
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.prose_only"* ]]
}

@test "a sweep that fails partway through sourcing is a setup error (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  # A missing lib sourced BEFORE a later dispatcher is defined: the function set is incomplete.
  printf '%s\n' 'source "$SCRIPT_DIR/lib/not-there.sh"' \
    'dispatch_late() { jq -n "{client_payload: {pr_number: 1, late_field: 1}}" | gh api --method POST "repos/$1/dispatches" --input -; }' \
    >> "$SANDBOX/scripts/dev-lead-retry.sh"
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"sourcing scripts/dev-lead-retry.sh failed"* ]]
}

@test "runs dispatchers defined in libs the sweep sources" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  cat > "$SANDBOX/scripts/lib/helper.sh" <<'EOF'
#!/usr/bin/env bash
dispatch_from_lib() {
  jq -n '{event_type: "x", client_payload: {pr_number: 1, lib_field: 2}}' \
    | gh api --method POST "repos/$1/dispatches" --input -
}
EOF
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.lib_field (sent by dispatch_from_lib)"* ]]
}

@test "a read in a lib the parser sources counts as read" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  printf '%s\n' 'source "$(dirname "$0")/lib/intent-extra.sh"' >> "$SANDBOX/scripts/dev-lead-intent.sh"
  printf '%s\n' '#!/usr/bin/env bash' "extra() { jq -r '.client_payload.extra_field' \"\$EVENT_PATH\"; }" \
    > "$SANDBOX/scripts/lib/intent-extra.sh"
  write_sweep pr_number extra_field
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

@test "nested keys and informational fields are not compared" {
  write_stub dev-lead/v7-stable
  write_intent pr_number checks
  write_sweep pr_number repo attempt
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
  [[ "$output" != *"nested_only"* ]]
}

@test "a dispatcher that sends nothing for the probe call is a setup error, never a pass" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  cat >> "$SANDBOX/scripts/dev-lead-retry.sh" <<'EOF'
dispatch_guarded() {
  [[ "$1" == */* ]] || return 0
  jq -n '{client_payload: {secret_field: 1}}' | gh api --method POST "repos/$1/dispatches" --input -
}
EOF
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"dispatch_guarded"* ]]
}

@test "the pinned channel must resolve; a missing other channel is skipped with a warning" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  tag_channels dev-lead/v7-next
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"the pinned channel dev-lead/v7-stable does not resolve"* ]]

  tag_channels dev-lead/v7-stable
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-lead/v7-ring0 does not exist; skipping it"* ]]
}

@test "in CI, an unfetchable channel tag fails closed instead of using a stale local tag (#2085 review)" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  write_sweep pr_number
  tag_channels "${ALL[@]}"
  git -C "$SANDBOX" remote add origin "$BATS_TEST_TMPDIR/no-such-remote"
  CI=true run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not fetch dev-lead/v7-"* ]]
}

@test "a malformed agent_ref or an unparseable parser is a setup error" {
  write_stub main
  write_intent pr_number
  write_sweep pr_number
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a dev-lead channel tag"* ]]

  write_stub dev-lead/v7-stable
  echo 'route3() { if then; }' >> "$SANDBOX/scripts/dev-lead-intent.sh"
  tag_channels "${ALL[@]}"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot parse scripts/dev-lead-intent.sh"* ]]
}

@test "the real sweep's dispatchers all produce a payload the check can read" {
  # Hermetic: only the sent side of the real repo (no tags, no network).
  run bash -c 'source <(sed -n "/^sent_fields() {/,/^}/p" "$1"); ROOT="$2"; SWEEP=scripts/dev-lead-retry.sh; sent_fields' \
    _ "$CHECK" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NOPAYLOAD"* ]]
  [[ "$output" == *"SOURCED"* ]]
  [[ "$output" == *"dispatch_bot_comment_retry comment_node_id"* ]]
  [[ "$output" == *"dispatch_reviews_retry intent_type"* ]]
}

@test "lint.yml runs the check" {
  grep -q 'bash scripts/check-retry-payload-fields.sh' "$REPO_ROOT/.github/workflows/lint.yml"
}

@test "AGENTS.md ordering rule points at the check" {
  grep -q 'check-retry-payload-fields.sh' "$REPO_ROOT/AGENTS.md"
}
