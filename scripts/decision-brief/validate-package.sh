#!/usr/bin/env bash
# validate-package.sh — structural + provenance gate for a drafted brief package.
#
# Runs over the `ideas/<slug>/` directory Mary wrote (brief.md,
# market-research.md, ost.md) BEFORE anything reaches the target repo. It is the
# deterministic half of the provenance guard (.github-private#1160,
# prompts/incubation/shared.md): the model is told the rules, and this script
# enforces them, so a brief that fabricates a market figure or leaves the
# riskiest-assumption table empty never becomes a PR. The decision-brief
# workflow runs it as its own step after the model step; Mary also runs it
# herself and fixes findings before finishing (the same pattern as
# initiative-planner's validate-plan.py).
#
# The rules mirror the incubator's gate (scripts/incubation-gate.sh in
# combsmith/incubator: frontmatter `status`, required section headers by
# case-insensitive prefix, no template placeholders) and add the stage's own
# decision-grade requirements from combsmith/incubator#3:
#
#   score        brief.md shows a RICE or ICE score line WITH the factor
#                arithmetic ("ICE = 3 × 1 × 2 = 6", not "ICE = 6"; Confidence
#                must be stated — the BA advisory ties it to how strong the
#                cited evidence is)
#   assumptions  the riskiest-assumptions table has a "Cheapest test" column
#                and at least one fully-filled row whose Cheapest-test cell is
#                not empty
#   decision     the visible Recommendation section (HTML comments stripped)
#                states exactly one bold position (**go** / **no-go** /
#                **park**) and names the human gate (`idea:approved`)
#   provenance   in the Problem / Target user / Market sections of brief.md and
#                every section of market-research.md except Sources, any line
#                that states a quantified market claim (a number with %, $,
#                million, users, customers, downloads, …) must carry a source
#                (http(s) URL or [^n] footnote), the literal
#                "unknown — needs discovery", or an explicit [ASSUMPTION] tag;
#                market-research.md must end with a `## Sources` section that
#                lists at least one URL or states that no external sources
#                were consulted
#
# Usage:
#   validate-package.sh <package-dir> [--slug <slug>] [--discussion <n>]
#                                      [--spec <package-spec.json>]
# Output: one `PASS|<file>|<rule>` or `FAIL|<file>|<rule>|<detail>` line per
# check; exit 1 when any FAIL. Helpers are sourceable for tests
# (tests/test_decision_brief.bats): strict mode is set only when executed.

# ── text helpers (pure) ──────────────────────────────────────────────────────

# vp_fm_value <file> <key> — the frontmatter value of <key> (empty if none).
vp_fm_value() {
  local f="$1" key="$2"
  [[ -f "$f" ]] || return 0
  awk -v key="$key" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && index($0, key ":")==1 { v=$0; sub("^" key ":[[:space:]]*", "", v); sub(/[[:space:]]*#.*$/, "", v); gsub(/["'\''` ]/, "", v); print v; exit }
  ' "$f"
  return 0
}

# vp_has_section <file> <needle> — 0 iff a markdown header line contains
# <needle> (case-insensitive, fixed string — same rule as the incubation gate).
vp_has_section() {
  local file="$1" needle="$2"
  grep -E '^#{1,6}[[:space:]]' "$file" 2>/dev/null | grep -qiF -- "$needle"
}

# vp_section_body <file> <needle> — the lines of the first section whose header
# contains <needle>, up to (not including) the next header of the SAME or a
# HIGHER level. Nested sub-headings (### under a ##) stay inside, so a claim
# under "### Market size" inside "## Market" is still scanned. The header line
# itself is excluded. Fenced code blocks are passed through.
vp_section_body() {
  local file="$1"
  awk -v needle="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" '
    /^#{1,6}[[:space:]]/ {
      lvl = match($0, /^#+/) ? RLENGTH : 0
      if (insec && lvl <= seclvl) exit
      if (!insec) {
        h = tolower($0)
        if (index(h, needle) > 0) { insec = 1; seclvl = lvl; next }
      }
    }
    insec { print }
  ' "$file"
}

# vp_has_sources <file> / vp_sources_body <file> — the `## Sources` section by
# EXACT heading text (any level, case-insensitive, trailing punctuation
# ignored). A heading such as "## Sources of demand" is prose that must be
# provenance-scanned, not the source list.
VP_SOURCES_HEADING_RE='^#{1,6}[[:space:]]+sources[[:space:]:.]*$'
vp_has_sources() { grep -qiE -- "$VP_SOURCES_HEADING_RE" "$1" 2>/dev/null; }
vp_sources_body() {
  awk -v re="$VP_SOURCES_HEADING_RE" '
    /^#{1,6}[[:space:]]/ {
      lvl = match($0, /^#+/) ? RLENGTH : 0
      if (insec && lvl <= seclvl) exit
      if (!insec && tolower($0) ~ re) { insec = 1; seclvl = lvl; next }
    }
    insec { print }
  ' "$1"
}
# vp_body_outside_sources <file> — every line except the exact Sources section.
vp_body_outside_sources() {
  awk -v re="$VP_SOURCES_HEADING_RE" '
    /^#{1,6}[[:space:]]/ {
      lvl = match($0, /^#+/) ? RLENGTH : 0
      if (insrc && lvl <= srclvl) insrc = 0
      if (!insrc && tolower($0) ~ re) { insrc = 1; srclvl = lvl }
    }
    !insrc { print }
  ' "$1"
}

# vp_strip_comments <file> — the file with HTML comments removed (multi-line).
vp_strip_comments() {
  perl -0pe 's/<!--.*?-->//gs' "$1"
}

# vp_placeholders <file> — print offending lines (template placeholders left
# behind, or an empty table row). Mirrors the gate's list and adds the generic
# `<angle-bracket placeholder>` the _TEMPLATE files use, minus real HTML tags,
# autolinks and e-mail addresses.
vp_placeholders() {
  local f="$1"
  vp_strip_comments "$f" \
    | grep -nE 'TODO — needs discovery|TODO: needs discovery|<Idea Title>|<slug>|<YYYY-MM-DD>|<who>|<link>|<fill[: ]|<[A-Za-z][^<>]*>|^\|([[:space:]]*\|)+[[:space:]]*$' \
    | grep -vE '<https?://[^>]*>' \
    | grep -vE '<[^<>@[:space:]]+@[^<>@[:space:]]+>' \
    | grep -vE '</?(br|hr|details|summary|sub|sup|kbd|code|b|i|em|strong|p|a|img|table|tr|td|th|thead|tbody|ul|ol|li|div|span|pre|blockquote|h[1-6])([[:space:]][^>]*)?/?>' \
    || true
}

# A quantified market claim: a number next to a unit that reads as market size,
# price, share, adoption or demand (compact forms such as 2.4bn / 300k / 5M too).
VP_QUANT_RE='([0-9][0-9,.]*[[:space:]]*(%|percent|million|billion|trillion|thousand|([kKMB]\+?|bn|mn|tn)([^A-Za-z]|$)|users|customers|companies|orgs|organizations|organisations|downloads|stars|installs|teams|developers|repos|subscribers|seats|businesses|nonprofits|non-profits|SMBs)|\$[[:space:]]*[0-9]|€[[:space:]]*[0-9]|£[[:space:]]*[0-9]|[0-9][0-9,.]*[[:space:]]*(USD|EUR|GBP)([^A-Za-z]|$))'
# What makes such a line honest on its own: a URL, the explicit unknown, or a
# tagged assumption. A [^n] footnote counts only when the file defines it with a
# URL (see vp_unsourced_claims).
VP_CITED_RE='(https?://|unknown — needs discovery|unknown - needs discovery|\[ASSUMPTION|\(assumption)'

# vp_unsourced_claims [defs-file] <text-on-stdin> — print each line that
# quantifies a market claim without a citation / unknown / assumption tag.
# Headings are scanned as text ("## $20B market opportunity" is a claim);
# table separator rows and fenced code are skipped. A line
# whose only citation is a [^n] footnote is accepted only when <defs-file>
# (the artifact itself) carries a `[^n]: … http(s)://…` definition — a dangling
# footnote is not a source.
vp_unsourced_claims() {
  local defs="${1:-}" line ref ok
  while IFS= read -r line; do
    ok=0
    if printf '%s\n' "$line" | grep -qiE -- "$VP_CITED_RE"; then ok=1
    else
      for ref in $(printf '%s\n' "$line" | grep -oE '\[\^[0-9]+\]' | tr -d '[]^' | sort -u); do
        if [[ -n "$defs" && -f "$defs" ]] && grep -qE "^\[\^${ref}\]:.*https?://" "$defs"; then ok=1; break; fi
      done
    fi
    [[ "$ok" == 1 ]] || printf '%s\n' "$line"
  done < <(awk '
    /^```/ { fence = !fence; next }
    fence { next }
    /^#{1,6}[[:space:]]/ { sub(/^#+[[:space:]]+/, ""); print; next }   # a claim in a heading is still a claim
    /^\|[[:space:]]*-+/ { next }
    { print }
  ' | grep -iE -- "$VP_QUANT_RE" || true)
}

# vp_table_data_rows <min-cells> [required-col-header] <text-on-stdin> — print
# table rows (not the header, not the separator) that have at least <min-cells>
# non-empty cells AND, when a column header is named, a non-empty cell in the
# column whose header contains it (case-insensitive).
vp_table_data_rows() {
  local min="${1:-4}" col
  col="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  awk -v min="$min" -v col="$col" '
    /^\|/ {
      if ($0 ~ /^\|[[:space:]]*-+/) { sep_seen = 1; next }   # separator row
      if (!sep_seen) {                                      # header row: find the column
        n = split($0, c, "|")
        for (i = 2; i < n; i++) { v = tolower(c[i]); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); if (col != "" && index(v, col) > 0 && colidx == 0) colidx = i }
        next
      }
      n = split($0, c, "|"); filled = 0; colok = (col == "") ? 1 : 0
      for (i = 2; i < n; i++) {
        v = c[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (v != "") { filled++; if (i == colidx) colok = 1 }
      }
      if (filled >= min && colok) print
    }
  '
}

# ── the checks ───────────────────────────────────────────────────────────────

VP_FAILS=0
vp_pass() { printf 'PASS|%s|%s\n' "$1" "$2"; }
vp_fail() { printf 'FAIL|%s|%s|%s\n' "$1" "$2" "$3"; VP_FAILS=$((VP_FAILS + 1)); }

# vp_check_frontmatter <dir> <file> <artifact> <allowed-status-regex>
vp_check_frontmatter() {
  local dir="$1" file="$2" artifact="$3" allowed="$4" path a s
  path="$dir/$file"
  if [[ ! -f "$path" ]]; then vp_fail "$file" present "missing"; return 0; fi
  vp_pass "$file" present
  a="$(vp_fm_value "$path" artifact)"
  s="$(vp_fm_value "$path" status)"
  if [[ "$a" != "$artifact" ]]; then vp_fail "$file" frontmatter "artifact='${a:-none}' (need '$artifact')"; else vp_pass "$file" frontmatter-artifact; fi
  if [[ ! "$s" =~ ^($allowed)$ ]]; then vp_fail "$file" frontmatter "status='${s:-none}' (need $allowed)"; else vp_pass "$file" frontmatter-status; fi
}

# vp_check_sections <dir> <file> <needle>...
vp_check_sections() {
  local dir="$1" file="$2"; shift 2
  local path="$dir/$file" needle missing=()
  [[ -f "$path" ]] || return 0
  for needle in "$@"; do
    vp_has_section "$path" "$needle" || missing+=("$needle")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then vp_fail "$file" sections "missing section(s): $(IFS=';'; echo "${missing[*]}")"; else vp_pass "$file" sections; fi
}

vp_check_placeholders() {
  local dir="$1" file="$2" hits
  local path="$dir/$file"
  [[ -f "$path" ]] || return 0
  hits="$(vp_placeholders "$path")"
  if [[ -n "$hits" ]]; then
    vp_fail "$file" placeholders "template placeholders or empty table rows remain: $(printf '%s' "$hits" | head -3 | tr '\n' ' ' | cut -c1-200)"
  else
    vp_pass "$file" placeholders
  fi
}

vp_check_score() {
  local dir="$1" body
  local path="$dir/brief.md"
  [[ -f "$path" ]] || return 0
  body="$(vp_section_body "$path" "value")"
  [[ -n "$body" ]] || body="$(vp_section_body "$path" "prioriti")"
  # The score line must SHOW the arithmetic — "ICE = 3 × 1 × 2 = 6", not
  # "ICE = 6": at least two factors combined with ×, *, x or / before the result.
  if ! printf '%s\n' "$body" | grep -qE '\b(RICE|ICE)\b[^=]*=[[:space:]]*\(?[[:space:]]*[0-9][0-9.]*([[:space:]]*(×|\*|x|/|÷)[[:space:]]*[0-9][0-9.]*)+[[:space:]]*\)?([[:space:]]*/[[:space:]]*[0-9][0-9.]*)?[[:space:]]*=[[:space:]]*[0-9]'; then
    vp_fail brief.md score "no RICE/ICE score line showing the factor arithmetic (expected e.g. 'ICE = 3 × 1 × 2 = 6') in the Value & feasibility section"
  elif ! printf '%s\n' "$body" | grep -qi 'confidence'; then
    vp_fail brief.md score "score shown without its Confidence factor (state it and tie it to the evidence strength)"
  else
    vp_pass brief.md score
  fi
}

vp_check_assumptions() {
  local dir="$1" body rows
  local path="$dir/brief.md"
  [[ -f "$path" ]] || return 0
  body="$(vp_section_body "$path" "riskiest assumption")"
  if ! printf '%s\n' "$body" | grep -qi 'cheapest test'; then
    vp_fail brief.md assumptions "riskiest-assumptions table has no 'Cheapest test' column"
    return 0
  fi
  rows="$(printf '%s\n' "$body" | vp_table_data_rows 4 "cheapest test")"
  if [[ -z "$rows" ]]; then
    vp_fail brief.md assumptions "riskiest-assumptions table has no fully-filled row with a concrete Cheapest test (assumption, if wrong, cheapest test)"
  else
    vp_pass brief.md assumptions
  fi
}

vp_check_decision() {
  local dir="$1" body
  local path="$dir/brief.md"
  [[ -f "$path" ]] || return 0
  # Scan the VISIBLE section only: a position hidden in an HTML comment is not
  # a recommendation. Comments are stripped before the section is cut.
  body="$(vp_strip_comments "$path" | vp_section_body /dev/stdin "recommendation")"
  # Exactly ONE bold position — `**go**`, `**no-go**`, `**park**` or
  # `**Recommendation: <position>**` — so an incidental "go or park" in prose
  # is not read as a decision.
  if [[ "$(printf '%s\n' "$body" | grep -oiE '\*\*(Recommendation:?[[:space:]]*)?(go|no-go|no go|park)\*\*' | wc -l | tr -d ' ')" -ne 1 ]]; then
    vp_fail brief.md decision "Recommendation section must state exactly one bold position: **go**, **no-go** or **park** (or **Recommendation: <position>**)"
  elif ! printf '%s\n' "$body" | grep -q 'idea:approved'; then
    vp_fail brief.md decision "Recommendation section must name the human gate: the decision is made by applying \`idea:approved\`"
  else
    vp_pass brief.md decision
  fi
}

vp_check_provenance() {
  local dir="$1" path hits
  # brief.md: the whole body after the frontmatter, whatever the target's
  # template names its sections (a Reach figure in §5, a number in §8 or in a
  # "## Proposed solution" is a market claim too). Footnotes resolve against
  # the brief itself.
  path="$dir/brief.md"
  if [[ -f "$path" ]]; then
    hits="$(awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {infm=0; next} !infm {print}' "$path" \
      | vp_unsourced_claims "$path")"
    if [[ -n "$hits" ]]; then
      vp_fail brief.md provenance "quantified market claim without a source / 'unknown — needs discovery' / [ASSUMPTION]: $(printf '%s' "$hits" | head -2 | tr '\n' ' ' | cut -c1-220)"
    else
      vp_pass brief.md provenance
    fi
  fi
  # ost.md: the Mermaid node labels are prose too — strip the fence markers so
  # the block is scanned instead of skipped.
  path="$dir/ost.md"
  if [[ -f "$path" ]]; then
    hits="$(sed '/^```/d' "$path" | vp_unsourced_claims "$path")"
    if [[ -n "$hits" ]]; then
      vp_fail ost.md provenance "quantified market claim without a source / 'unknown — needs discovery' / [ASSUMPTION]: $(printf '%s' "$hits" | head -2 | tr '\n' ' ' | cut -c1-220)"
    else
      vp_pass ost.md provenance
    fi
  fi
  # market-research.md: everything but Sources.
  path="$dir/market-research.md"
  if [[ -f "$path" ]]; then
    hits="$(vp_body_outside_sources "$path" | vp_unsourced_claims "$path")"
    if [[ -n "$hits" ]]; then
      vp_fail market-research.md provenance "quantified market claim without a source / 'unknown — needs discovery' / [ASSUMPTION]: $(printf '%s' "$hits" | head -2 | tr '\n' ' ' | cut -c1-220)"
    else
      vp_pass market-research.md provenance
    fi
    local src
    src="$(vp_sources_body "$path")"
    if ! vp_has_sources "$path"; then
      vp_fail market-research.md sources "no '## Sources' section (exact heading)"
    elif ! printf '%s\n' "$src" | grep -qE 'https?://' && ! printf '%s\n' "$src" | grep -qi 'no external sources were consulted'; then
      vp_fail market-research.md sources "Sources lists no URL and does not state 'No external sources were consulted'"
    else
      vp_pass market-research.md sources
    fi
  fi
}

vp_check_identity() {
  local dir="$1" slug="$2" discussion="$3" path f
  for f in brief.md market-research.md ost.md; do
    path="$dir/$f"
    [[ -f "$path" ]] || continue
    if [[ -n "$slug" ]] && ! grep -qE "\*\*Slug:\*\*[[:space:]]*\`${slug}\`" "$path"; then
      vp_fail "$f" identity "does not carry '**Slug:** \`${slug}\`'"
    else
      vp_pass "$f" identity-slug
    fi
  done
  path="$dir/brief.md"
  if [[ -f "$path" && -n "$discussion" ]]; then
    if grep -qE "/discussions/${discussion}([^0-9]|$)" "$path"; then vp_pass brief.md identity-discussion
    else vp_fail brief.md identity "Source Discussion link to /discussions/${discussion} missing"; fi
  fi
  if [[ -f "$path" ]]; then
    if grep -q 'market-research.md' "$path" && grep -q 'ost.md' "$path"; then vp_pass brief.md links
    else vp_fail brief.md links "brief must reference market-research.md and ost.md"; fi
  fi
}

vp_check_ost() {
  local dir="$1"
  local path="$dir/ost.md"
  [[ -f "$path" ]] || return 0
  if grep -q '^```mermaid' "$path"; then vp_pass ost.md mermaid
  else vp_fail ost.md mermaid "no \`\`\`mermaid block (the tree is rendered as Mermaid)"; fi
}

# vp_spec_sections <spec> <file> — the gate's required_sections for <file>, one per line.
vp_spec_sections() {
  local spec="$1" file="$2"
  [[ -n "$spec" && -f "$spec" ]] || return 0
  jq -r --arg f "$file" '.required_artifacts[]? | select(.file == $f) | .required_sections[]?' "$spec" 2>/dev/null || true
}

vp_main() {
  local dir="" slug="" discussion="" spec=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --slug) slug="${2:-}"; shift 2 ;;
      --discussion) discussion="${2:-}"; shift 2 ;;
      --spec) spec="${2:-}"; shift 2 ;;
      -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; return 0 ;;
      *) dir="$1"; shift ;;
    esac
  done
  [[ -n "$dir" ]] || { echo "usage: validate-package.sh <package-dir> [--slug s] [--discussion n] [--spec file]" >&2; return 2; }
  [[ -d "$dir" ]] || { echo "::error::package dir '$dir' does not exist" >&2; return 2; }

  local -a brief_secs mr_secs
  brief_secs=("Problem" "Target user" "Market" "Opportunity" "Value" "Riskiest assumption" "Recommendation" "Open questions")
  mr_secs=("How it's solved today" "The gap" "Market signal" "Risks" "Sources")
  local s
  while IFS= read -r s; do [[ -n "$s" ]] && brief_secs+=("$s"); done < <(vp_spec_sections "$spec" brief.md)
  while IFS= read -r s; do [[ -n "$s" ]] && mr_secs+=("$s"); done < <(vp_spec_sections "$spec" market-research.md)

  vp_check_frontmatter "$dir" brief.md brief 'final'
  vp_check_frontmatter "$dir" market-research.md market-research 'final|draft'
  vp_check_frontmatter "$dir" ost.md ost 'final|draft'
  vp_check_sections "$dir" brief.md "${brief_secs[@]}"
  vp_check_sections "$dir" market-research.md "${mr_secs[@]}"
  vp_check_placeholders "$dir" brief.md
  vp_check_placeholders "$dir" market-research.md
  vp_check_placeholders "$dir" ost.md
  vp_check_score "$dir"
  vp_check_assumptions "$dir"
  vp_check_decision "$dir"
  vp_check_provenance "$dir"
  vp_check_identity "$dir" "$slug" "$discussion"
  vp_check_ost "$dir"

  if [[ "$VP_FAILS" -gt 0 ]]; then
    echo "validate-package: ${VP_FAILS} finding(s) in ${dir} — fix them before the package can become a PR" >&2
    return 1
  fi
  echo "validate-package: ${dir} passes"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  set -euo pipefail
  vp_main "$@"
fi
