#!/usr/bin/env bash
# slug.sh — derive the stable `ideas/<slug>/` folder name for an Ideas Discussion.
#
# The incubator convention (ideas/README.md): a short, kebab-case, stable slug
# that matches the source Discussion where practical. Mary never invents one at
# run time — the same title always yields the same slug, so a re-brief of the
# same idea lands in the same folder and on the same `incubate/<slug>` branch.
#
# Sourceable (pure functions, no network). Tests: tests/test_decision_brief.bats.

# db_slug_from_title <title> — print the slug.
#   1. strip a leading emoji / decoration and a trailing " — <subtitle>" (the
#      feature-ideation titles read "💡 Name — one-line pitch"; the Name is the
#      slug, the pitch is not);
#   2. lowercase; split CamelCase ("DemandRadar" → "demand-radar");
#   3. non-alphanumerics → "-", squeeze, trim;
#   4. cap at 48 characters on a word boundary.
db_slug_from_title() {
  local title="${1:-}" s
  s="$title"
  # "Idea: Name" / "RFC: Name" — a short label prefix, not the title: drop it
  # (otherwise every "Idea: …" would collapse to the slug "idea").
  if [[ "$s" =~ ^[[:alpha:][:space:]]{1,15}:[[:space:]]*(.+)$ ]]; then
    s="${BASH_REMATCH[1]}"
  fi
  # Keep only the part before an em-dash / en-dash / " - " / ":" subtitle separator.
  s="${s%%—*}"
  s="${s%%–*}"
  s="${s%% - *}"
  s="${s%%:*}"
  # Split CamelCase before lowercasing: a lower→Upper boundary ("DemandRadar"),
  # and an Upper-run followed by a capitalised word ("A2AProbe" → "A2A-Probe",
  # "MCPServerCard" → "MCP-Server-Card"). A digit→Upper boundary is NOT split,
  # so acronyms with digits stay whole.
  s="$(printf '%s' "$s" | sed -E 's/([a-z])([A-Z])/\1-\2/g; s/([A-Z0-9])([A-Z][a-z])/\1-\2/g')"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  # Everything that is not a-z0-9 becomes a hyphen (bytes of emoji/punctuation
  # included), then squeeze and trim.
  s="$(printf '%s' "$s" | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [ "${#s}" -gt 48 ]; then
    s="${s:0:48}"
    s="${s%-*}"
  fi
  printf '%s\n' "$s"
}

# db_slug_is_valid <slug> — 0 iff the slug is non-empty kebab-case
# ([a-z0-9] with single hyphens, no leading/trailing hyphen) and ≤ 48 chars.
db_slug_is_valid() {
  local s="${1:-}"
  [ -n "$s" ] || return 1
  [ "${#s}" -le 48 ] || return 1
  case "$s" in
    _template | _TEMPLATE) return 1 ;;
  esac
  printf '%s' "$s" | LC_ALL=C grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'
}
