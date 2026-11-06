#!/usr/bin/env bash
set -euo pipefail
# Semantic symbol-context assembler for the PR-review cascade (issue #1090,
# epic #1088, Phase 2).
#
# Goal: give the deep-review (run_agentic deep) and rubber-duck (run_duck) tiers
# caller / callee / type-definition context for the SYMBOLS touched in the diff,
# not just the hunk — so the reviewer can reason about why a function exists and
# catch cross-file logic bugs the diff alone hides.
#
# Context source (Phase-1 audit + #839 status). The LSP pilot (#839) that would
# have exposed real LSP navigation tools (find_references, definitions) is NOT
# present in this repo, so per docs/initiatives/mcp-powered-review.md this uses
# the fallback: the **GitHub `search_code` path** (`gh search code`) to collect
# reference contexts for each touched symbol. This mirrors the `gh`-fetch
# structure of scripts/lib/downstream-impact.sh, keeping the assembler
# deterministic and unit-testable, and it lands the context into exactly the
# MCP-eligible deep + duck tiers that engine.sh's _mcp_review_flags already
# threads (triage — no tools — is untouched).
#
# Opt-in + inert by default (AC #4). The caller (review-one-pr.sh) only invokes
# assemble_symbol_context when SYMBOL_CONTEXT_ENABLED=true. When it is off,
# SYMBOL_CONTEXT_FILE is never set, the deep/duck prompts read no symbol block,
# and review behavior + cost are byte-identical to pre-feature. If the code
# search is unavailable, the assembler degrades with an MCP-style ::warning::
# (fail loud, never fake) and the review continues on the model's base
# capabilities — it never aborts (always exits 0).
#
# Measurability (AC #2). For every touched function the assembler emits one
# ::notice::[symbol-context] log line counting the attached contexts, plus a
# SYMBOL_CONTEXT_COUNTS summary line inside the written block.

# ---------------------------------------------------------------------------
# sc_touched_functions <diff>  (PURE — no network / gh I/O)
# ---------------------------------------------------------------------------
# Parses a unified diff and prints the set of function symbols the diff touches,
# one per line, sorted + unique. A definition on an added OR removed line counts
# as "touched" (a deleted function is as relevant to cross-file reasoning as an
# added one). Language coverage is heuristic but spans the stacks this org sees:
#   bash/sh : `name() {`            and `function name`
#   python  : `def name(`
#   js/ts   : `function name(`      and `const name = (`/`=>` arrow
#   go      : `func name(`          and `func (recv) name(`
sc_touched_functions() {
  local diff="${1:-}"
  [[ -n "$diff" ]] || return 0
  printf '%s\n' "$diff" | awk '
    # Only consider added/removed content lines and @@ hunk headers; skip diff
    # file headers (+++/---).
    /^\+\+\+/ || /^---/ { next }
    /^@@/ {
      # Extract the trailing context field after the second @@ (e.g.
      # "@@ -10,3 +10,3 @@ func ServeHTTP(...) {" -> "func ServeHTTP(...) {").
      # This is the only source of the touched function name when the diff is a
      # body-only change (signature line was not added or removed).
      line = $0
      if (match(line, /@@ [^@]* @@ /)) {
        s = substr(line, RSTART + RLENGTH)
        sub(/^[[:space:]]+/, "", s)
      } else if (match(line, /@@ [^@]* @@$/)) {
        next   # no context field on this hunk header
      } else {
        next
      }
      name = ""
      # go: func (recv) Name(  |  func Name(
      if (match(s, /^func[[:space:]]+(\([^)]*\)[[:space:]]*)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
        t = s
        sub(/^func[[:space:]]+/, "", t)
        sub(/^\([^)]*\)[[:space:]]*/, "", t)
        if (match(t, /^[A-Za-z_][A-Za-z0-9_]*/)) { name = substr(t, 1, RLENGTH) }
      }
      # python: def name(
      else if (match(s, /^def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
        t = s; sub(/^def[[:space:]]+/, "", t)
        match(t, /^[A-Za-z_][A-Za-z0-9_]*/); name = substr(t, 1, RLENGTH)
      }
      # js/ts: (export) function name(
      else if (match(s, /^(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*\(/)) {
        t = s
        sub(/^export[[:space:]]+/, "", t)
        sub(/^async[[:space:]]+/, "", t)
        sub(/^function[[:space:]]+/, "", t)
        match(t, /^[A-Za-z_$][A-Za-z0-9_$]*/); name = substr(t, 1, RLENGTH)
      }
      # bash: function name
      else if (match(s, /^function[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*/)) {
        t = s; sub(/^function[[:space:]]+/, "", t)
        match(t, /^[A-Za-z_][A-Za-z0-9_-]*/); name = substr(t, 1, RLENGTH)
      }
      # bash/generic: name() {
      else if (match(s, /^[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\(\)/)) {
        match(s, /^[A-Za-z_][A-Za-z0-9_-]*/); name = substr(s, 1, RLENGTH)
      }
      if (name != "") print name
      next
    }
    /^[+-]/ {
      line = substr($0, 2)          # strip the +/- marker
      s = line
      sub(/^[[:space:]]+/, "", s)   # left-trim

      name = ""
      # go: func (recv) Name(  |  func Name(
      if (match(s, /^func[[:space:]]+(\([^)]*\)[[:space:]]*)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
        t = s
        sub(/^func[[:space:]]+/, "", t)
        sub(/^\([^)]*\)[[:space:]]*/, "", t)   # drop optional receiver
        if (match(t, /^[A-Za-z_][A-Za-z0-9_]*/)) { name = substr(t, 1, RLENGTH) }
      }
      # python: def name(
      else if (match(s, /^def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
        t = s; sub(/^def[[:space:]]+/, "", t)
        match(t, /^[A-Za-z_][A-Za-z0-9_]*/); name = substr(t, 1, RLENGTH)
      }
      # js/ts: (export) function name(
      else if (match(s, /^(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*\(/)) {
        t = s
        sub(/^export[[:space:]]+/, "", t)
        sub(/^async[[:space:]]+/, "", t)
        sub(/^function[[:space:]]+/, "", t)
        match(t, /^[A-Za-z_$][A-Za-z0-9_$]*/); name = substr(t, 1, RLENGTH)
      }
      # bash: function name
      else if (match(s, /^function[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*/)) {
        t = s; sub(/^function[[:space:]]+/, "", t)
        match(t, /^[A-Za-z_][A-Za-z0-9_-]*/); name = substr(t, 1, RLENGTH)
      }
      # js/ts arrow: (export) const name = ( ... ) =>  |  const name = async
      else if (match(s, /^(export[[:space:]]+)?(const|let|var)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=[[:space:]]*(async[[:space:]]*)?(\(|[A-Za-z_$])/) && s ~ /=>/) {
        t = s
        sub(/^export[[:space:]]+/, "", t)
        sub(/^(const|let|var)[[:space:]]+/, "", t)
        match(t, /^[A-Za-z_$][A-Za-z0-9_$]*/); name = substr(t, 1, RLENGTH)
      }
      # bash/generic: name() {
      else if (match(s, /^[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\(\)/)) {
        match(s, /^[A-Za-z_][A-Za-z0-9_-]*/); name = substr(s, 1, RLENGTH)
      }

      if (name != "") print name
    }
  ' | sort -u
}

# ---------------------------------------------------------------------------
# _symbol_context_gh <gh args...>
# ---------------------------------------------------------------------------
# Run `gh` for code-search reads. Cross-repo / higher-rate reads prefer the bot
# PAT surfaced as GH_PAT (same convention as _downstream_gh in
# downstream-impact.sh); otherwise fall back to whatever auth gh already has.
_symbol_context_gh() {
  if [[ -n "${GH_PAT:-}" ]]; then
    GH_TOKEN="$GH_PAT" gh "$@"
  else
    gh "$@"
  fi
}

# ---------------------------------------------------------------------------
# sc_search_symbol_contexts <symbol> <repo> <max>
# ---------------------------------------------------------------------------
# Gathers up to <max> caller/callee/type-def reference contexts for <symbol> via
# the GitHub search_code path (`gh search code`). Prints one context per line as
# "<path>\t<snippet>". The GitHub code-search index covers both call sites
# (callers/callees) and the definition/type — the closest available proxy to LSP
# find_references given #839 is a no-go.
#
# Exit status: 0 on a successful search (even with zero results); 2 when the
# search itself fails (auth/scope/rate/unavailable) so the caller can emit the
# graceful-degradation warning and keep the review alive.
sc_search_symbol_contexts() {
  local symbol="$1" repo="$2" max="${3:-3}"
  [[ -n "$symbol" ]] || return 0

  local json_fields="path,textMatches"
  local args=(search code "$symbol" --limit "$max" --json "$json_fields")
  [[ -n "$repo" ]] && args+=(--repo "$repo")

  local raw rc=0
  raw=$(_symbol_context_gh "${args[@]}" 2>/dev/null) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    return 2
  fi
  # An empty/invalid payload is treated as "no results", not a failure.
  [[ -n "$raw" ]] || return 0

  printf '%s' "$raw" | jq -r '
    if type == "array" then .[] else empty end
    | (.path // "" | tostring) as $p
    | ((.textMatches // []) | (.[0]?.fragment // "")) as $frag
    | ($frag | gsub("[[:space:]]+"; " ") | gsub("^ +| +$"; "")) as $snip
    | "\($p)\t\($snip)"
  ' 2>/dev/null || return 0
  return 0
}

# ---------------------------------------------------------------------------
# assemble_symbol_context <diff> <repo> [out_file]
# ---------------------------------------------------------------------------
# For each function touched in <diff>, gather >= SYMBOL_CONTEXT_MIN (default 3)
# reference contexts from <repo> via the search_code path and write a
# human-readable SYMBOL_CONTEXT block to <out_file>, whose path is exported as
# SYMBOL_CONTEXT_FILE for the deep/audit tiers and run_duck (mirroring
# DOWNSTREAM_IMPACT_FILE). Emits a per-function context-count ::notice:: (AC #2).
#
# Bounds (AC #4 cost cap):
#   - at most SYMBOL_CONTEXT_MAX_FUNCS functions searched per PR (default 20),
#   - at most SYMBOL_CONTEXT_MIN contexts per function,
#   - the assembled block truncated to SYMBOL_CONTEXT_MAX_BYTES (default 8000).
#
# Graceful degradation (AC #4): a diff touching no functions -> literal "(none)"
# with zero searches; a search failure for a symbol -> a single MCP-style
# ::warning:: and that symbol is annotated "search unavailable". Always exits 0.
assemble_symbol_context() {
  local diff="${1:-}"
  local repo="${2:-}"
  local out_file="${3:-${SYMBOL_CONTEXT_FILE:-/tmp/cascade/symbol-context.txt}}"
  local min="${SYMBOL_CONTEXT_MIN:-3}"
  local max_funcs="${SYMBOL_CONTEXT_MAX_FUNCS:-10}"
  local max_bytes="${SYMBOL_CONTEXT_MAX_BYTES:-8000}"

  mkdir -p "$(dirname "$out_file")" 2>/dev/null || true
  rm -f "$out_file"

  local functions
  functions=$(sc_touched_functions "$diff")

  # No touched functions -> literal "(none)", zero searches (AC #4).
  if [[ -z "$functions" ]]; then
    printf '%s' "(none)" > "$out_file"
    export SYMBOL_CONTEXT_FILE="$out_file"
    return 0
  fi

  local block="Symbol context (caller/callee/type-def references for functions touched in this diff):"$'\n'
  local counts_csv="" total=0 fn_count=0 warned=0
  local fn
  while IFS= read -r fn; do
    [[ -n "$fn" ]] || continue
    if [ "$fn_count" -ge "$max_funcs" ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
      block+=$'\n'"(function cap reached: $max_funcs; remaining touched functions not searched)"$'\n'
      break
    fi
    fn_count=$((fn_count + 1))

    local ctx rc=0 n=0
    ctx=$(sc_search_symbol_contexts "$fn" "$repo" "$min") || rc=$?

    block+=$'\n'"- $fn"$'\n'
    if [[ "$rc" -ne 0 ]]; then
      block+="    search unavailable"$'\n'
      if [[ "$warned" -eq 0 ]]; then
        echo "::warning::[symbol-context] symbol navigation unavailable (code search failed) — review continues on the model's base capabilities (no symbol context)" >&2
        warned=1
      fi
      echo "::notice::[symbol-context] $fn: 0 contexts attached (search unavailable)" >&2
      counts_csv="${counts_csv:+$counts_csv,}$fn=0"
      continue
    fi

    if [[ -n "$ctx" ]]; then
      local l path snip
      while IFS= read -r l; do
        [[ -n "$l" ]] || continue
        path="${l%%$'\t'*}"
        snip="${l#*$'\t'}"
        block+="    $path: $snip"$'\n'
        n=$((n + 1))
      done <<< "$ctx"
    fi
    [[ "$n" -eq 0 ]] && block+="    (no references found)"$'\n'

    total=$((total + n))
    counts_csv="${counts_csv:+$counts_csv,}$fn=$n"
    echo "::notice::[symbol-context] $fn: $n context(s) attached" >&2
  done <<< "$functions"

  # Machine-readable summary inside the block (AC #2 — measurable in the output).
  block+=$'\n'"SYMBOL_CONTEXT_COUNTS: $counts_csv"$'\n'
  echo "::notice::[symbol-context] total: $total context(s) across $fn_count function(s)" >&2

  # Cap total size so a large touched-function set cannot blow up the prompt
  # (mirrors the 8 KB DOWNSTREAM_IMPACT cap).
  block="${block:0:max_bytes}"
  printf '%s' "$block" > "$out_file"
  export SYMBOL_CONTEXT_FILE="$out_file"
  return 0
}
