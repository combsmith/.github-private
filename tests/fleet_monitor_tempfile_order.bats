#!/usr/bin/env bats
# Static regression guard for #2277: every temp file in scripts/fleet_monitor.sh
# must be created before it is first used. The script runs under `set -u`, so a
# `$NAME` reference that precedes `NAME=$(mktemp)` aborts the whole Fleet Monitor
# run with "NAME: unbound variable" (legacy_attr_file was appended to in the
# first per-repo loop but only created ~330 lines later).
#
# The script is NOT executed — it runs on source — so this is a line-order scan:
# for each `NAME=$(mktemp)` assignment, its first assignment line must be lower
# than the first non-comment line that references `$NAME` / `${NAME}`. Run:
#   bats tests/fleet_monitor_tempfile_order.bats

MONITOR="${BATS_TEST_DIRNAME}/../scripts/fleet_monitor.sh"

# Prints "NAME<TAB>first-assignment-line" for each distinct mktemp-assigned name.
mktemp_assignments() {
  grep -nE '^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*="?\$\(mktemp' "$MONITOR" \
    | sed -E 's/^([0-9]+):[[:space:]]*(local[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\3\t\1/' \
    | awk -F'\t' '!seen[$1]++'
}

# Prints the line number of the first non-comment line referencing $NAME, or nothing.
first_reference() {
  local name="$1"
  grep -nE "\\\$(${name}([^A-Za-z0-9_]|\$)|\\{${name}[}:#%/])" "$MONITOR" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | head -n1 | cut -d: -f1
}

@test "scan finds the mktemp temp files, including legacy_attr_file" {
  run mktemp_assignments
  [ "$status" -eq 0 ]
  [[ "$output" == *$'legacy_attr_file\t'* ]]
  [[ "$output" == *$'ingress_attr_file\t'* ]]
  [[ "$output" == *$'metrics_file\t'* ]]
}

@test "every NAME=\$(mktemp) is assigned before the first \$NAME reference" {
  local bad="" name line ref
  while IFS=$'\t' read -r name line; do
    ref="$(first_reference "$name")"
    if [ -n "$ref" ] && [ "$ref" -le "$line" ]; then
      bad+="${name}: created at line ${line} but referenced at line ${ref}"$'\n'
    fi
  done < <(mktemp_assignments)
  if [ -n "$bad" ]; then
    printf '%s' "$bad" >&2
    return 1
  fi
}
