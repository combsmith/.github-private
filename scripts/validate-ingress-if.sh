#!/usr/bin/env bash
# validate-ingress-if.sh — the if:-as-event-filter-only guard for ADR-0007
# agent-ingress jobs (issue #1725 AC #3, epic #1723).
#
# WHY THIS EXISTS
#   ADR-0007 collapses the per-role Class-1 caller stubs into ONE agent-ingress
#   workflow with one thin-caller job per role. The single place it loosens
#   ADR-0001 is a job's `if:`: because the ingress fans one shared `on:` union out
#   to the right role, each job's `if:` selects the events that role answers.
#   That loosening is deliberately narrow — an `if:` is evaluated by the Actions
#   service BEFORE a runner exists, so it can only legitimately read the DELIVERED
#   EVENT (github.event_name / github.event.action / plain payload predicates).
#   The moment an `if:` reaches for repo state — org/repo config vars or secrets,
#   another job's computed outputs, the repo tree (hashFiles), repo identity, the
#   payload's standing default_branch, or the standing labels array — it is
#   script-in-disguise logic that belongs in the reusable as a permissioned step,
#   not in the thin caller. This guard fails such an ingress before merge.
#
# WHAT IT DOES
#   For an agent-ingress workflow it asserts, per job, that
#     (1) the job is a thin caller (it has a reusable `uses:` pin), and
#     (2) the job's `if:` is a PURE event filter (no forbidden repo-state reach),
#     (3) any job-level `concurrency:` is bounded per ADR-0010: its `group` reads
#         only that same event surface (checked by the same predicate), carries
#         the role (job) name as a prefix, and `cancel-in-progress` is a literal
#         boolean. The other half of ADR-0010's collision rule — no reuse of a
#         group the pinned reusable declares — needs the reusable at its pinned
#         ref, so validate-caller-inputs.sh enforces it with viif_group_stems.
#   The ALLOW/FORBID rulings are the FROZEN, machine-readable table at
#   tests/fixtures/agent-ingress/if-filter-rulings.tsv. This guard consumes THOSE
#   ROWS DIRECTLY (not the ADR prose), so guard and test cannot drift (QA #8).
#
# USAGE
#   validate-ingress-if.sh
#       Scan VIIF_ROOT (default: the repo containing this script) for
#       .github/workflows/agent-ingress.yml and validate it. A tree with no such
#       file is a clean pass (the ingress is a docs reference until the collapse
#       story lands) — never a silent skip that hides an absent guard.
#
# ENV
#   VIIF_ROOT      Repo root to scan (default: the repo containing this script).
#   VIIF_RULINGS   Path to the frozen rulings TSV (default: the repo's fixture).

# NOTE: strict mode is enabled only in the execute-directly guard at the bottom,
# so sourcing this file (the bats tests do) does not leak `set -euo pipefail`.

viif_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

viif_rulings_path() {
  if [[ -n "${VIIF_RULINGS:-}" ]]; then
    printf '%s\n' "$VIIF_RULINGS"
  else
    printf '%s/tests/fixtures/agent-ingress/if-filter-rulings.tsv\n' "$(viif_repo_root)"
  fi
}

# ── pure event-filter boundary detector ──────────────────────────────────────

# viif_normalize_expr <expr> — rewrite bracket/indexed context access to dot
# access so `x['y']` / `x["y"]` and `x.y` are ONE construct for matching. The
# detectors below (and the allowlist gate) match dot notation only; without this
# an indexed reach such as vars['DEV_LEAD_ENGINE'] or github['repository'] would
# slip past every dot-notation check (#1772). Applied globally so chained indices
# (needs['detect'].outputs['should_run']) collapse to a single dotted path.
viif_normalize_expr() {
  printf '%s' "$1" | sed -E "s/\[[[:space:]]*'([^']*)'[[:space:]]*\]/.\1/g; s/\[[[:space:]]*\"([^\"]*)\"[[:space:]]*\]/.\1/g"
}

# viif_expr_matches_construct <expr> <construct-name> — return 0 if <expr>
# reaches for the FORBID construct <construct-name> (a rulings key). This is the
# ONLY place a construct name is mapped to its detection; the set of names comes
# from the frozen rulings table, so an unmapped new FORBID row is caught by the
# test (its expr would be wrongly permitted) rather than silently under-enforced.
# Expects a NORMALIZED and LITERAL-STRIPPED expr (see viif_normalize_expr and the
# stripping in viif_forbidden) so indexed and dot forms are treated identically
# and a policed name inside a quoted literal is not mistaken for a reference.
# Matches against a LOWERCASED copy of the expr because Actions expression context
# names are case-insensitive (vars.X == VARS.X == Vars.X); a case-sensitive match
# would let VARS.SECRET / Secrets.TOKEN bypass the check (#1867).
viif_expr_matches_construct() {
  local name="$2" lc="${1,,}"
  case "$name" in
    # vars/secrets/needs are ALWAYS a repo-state reach, whether accessed with a
    # property (vars.X, normalized from vars['X']) or used BARE as a whole value
    # (toJSON(vars), or the root passed as any function argument). Match the root
    # as an identifier TOKEN — bounded left and right, not requiring a trailing
    # dot — so the bare form no longer slips past the dotted-only pattern (#1781).
    vars)                  [[ "$lc" =~ (^|[^._[:alnum:]-])vars([^_[:alnum:]-]|$) ]] ;;
    secrets)               [[ "$lc" =~ (^|[^._[:alnum:]-])secrets([^_[:alnum:]-]|$) ]] ;;
    needs-outputs)         [[ "$lc" =~ (^|[^._[:alnum:]-])needs([^_[:alnum:]-]|$) ]] ;;
    hashfiles)             [[ "$lc" == *hashfiles* ]] ;;
    repo-identity)         [[ "$lc" == *"github.repository"* ]] || \
                           [[ "$lc" =~ github\.event\.repository\.(full_name|name|id|node_id|owner) ]] ;;
    default-branch)        [[ "$lc" == *default_branch* ]] ;;
    labels-array-contains) [[ "$lc" == *".labels"* ]] ;;
    *)                     return 1 ;;
  esac
}

# viif_reaches_unlisted_context <expr> — the ALLOWLIST backstop. ADR-0007 permits
# an ingress if: to reference ONLY the delivered event: github.event_name,
# github.event.action, and github.event.<payload>. The named FORBID rows above
# are a DENYLIST of known repo-state reaches, which passes anything unlisted by
# default — env.*, inputs.*, steps.*, job.*, runner.*, matrix.*, strategy.*, and
# non-event github.* (github.actor/ref/sha/token/…) all validate today. This gate
# closes that default: it returns 0 (reaches unlisted context) for any context
# root outside the event-only allowlist, so an unenumerated reach cannot pass
# silently (#1772). Expects a NORMALIZED and LITERAL-STRIPPED expr (see
# viif_forbidden). vars/secrets/needs and bare github.repository are owned by the
# named rows above and excluded here to avoid double-reporting them.
viif_reaches_unlisted_context() {
  # Lowercase the expr: Actions context names are case-insensitive, so GitHub.actor
  # / ENV.FOO must be judged the same as their lowercase twins (#1867).
  local stripped="${1,,}" sub

  # (a) a github.<x> reference outside the event allowlist (event_name / event.*).
  #     bare github.repository is the repo-identity construct's own concern.
  while IFS= read -r sub; do
    [[ -n "$sub" ]] || continue
    case "$sub" in
      event_name|event|repository) continue ;;
      *) return 0 ;;
    esac
  done < <(printf '%s\n' "$stripped" | grep -oE '(^|[^._[:alnum:]])github\.[A-Za-z_][A-Za-z0-9_-]*' | sed -E 's/.*github\.//')

  # (a2) BARE github used as a whole value (toJSON(github)) — no property to walk,
  #      so part (a)'s dotted grep never sees it. Serializing the whole context is
  #      the most severe reach: it is repo identity/actor/ref/… , not the event.
  #      Match github as a token NOT followed by a dot (the dotted forms are (a)'s
  #      concern; event.* stays allowed there) (#1781).
  if [[ "$stripped" =~ (^|[^._[:alnum:]-])github([^._[:alnum:]-]|$) ]]; then
    return 0
  fi

  # (b) any other policed context root that is never the delivered event, whether
  #     accessed with a property (env.FOO) or used BARE as a whole value
  #     (toJSON(env)). Match the root as an identifier TOKEN, not requiring a
  #     trailing dot, so the bare form is caught too (#1781).
  if [[ "$stripped" =~ (^|[^._[:alnum:]-])(env|inputs|steps|job|jobs|runner|matrix|strategy)([^_[:alnum:]-]|$) ]]; then
    return 0
  fi
  return 1
}

# viif_forbidden <if-expr> — print the FORBID construct name(s) <if-expr> reaches
# for (space-separated) and return 1; print nothing and return 0 if it is a pure
# event filter. Enumerates the FORBID rows straight from the frozen rulings table,
# then applies the event-only allowlist backstop for any unlisted context root.
viif_forbidden() {
  local expr="$1" nexpr sexpr rulings hits="" name verdict row_expr row_rationale
  nexpr="$(viif_normalize_expr "$expr")"
  # Strip string literals AFTER normalizing (normalize rewrites x['y']→x.y using
  # the quotes, so stripping first would erase the index). Both the named FORBID
  # matching and the allowlist backstop then run on the literal-stripped expr, so
  # a policed name that appears only inside a quoted literal (e.g. an issue-comment
  # body 'set vars.X please') is not mistaken for a context reference (#1781 AC #2).
  sexpr="$(printf '%s' "$nexpr" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")"
  rulings="$(viif_rulings_path)"
  [[ -f "$rulings" ]] || { echo "::error::rulings table not found: $rulings" >&2; return 2; }

  # shellcheck disable=SC2034  # row_expr/row_rationale columns are consumed by the test, not here
  while IFS=$'\t' read -r name verdict row_expr row_rationale || [[ -n "$name" ]]; do
    case "$name" in ''|'#'*) continue ;; esac
    [[ "$verdict" = "FORBID" ]] || continue
    if viif_expr_matches_construct "$sexpr" "$name"; then
      case " $hits " in *" $name "*) : ;; *) hits+="${hits:+ }$name" ;; esac
    fi
  done < "$rulings"

  # Allowlist backstop: fail any context root the denylist above does not name.
  if viif_reaches_unlisted_context "$sexpr"; then
    case " $hits " in *" unlisted-context "*) : ;; *) hits+="${hits:+ }unlisted-context" ;; esac
  fi

  [[ -z "$hits" ]] && return 0
  printf '%s\n' "$hits"
  return 1
}

# ── job-level concurrency: (ADR-0010) ────────────────────────────────────────

# The literal Actions expression opener, matched as text (never expanded).
# shellcheck disable=SC2016
VIIF_EXPR_OPEN='${{'

# viif_group_exprs <group> — print the body of every ${{ … }} expression in a
# concurrency group, one per line (newlines inside a body folded to spaces).
viif_group_exprs() {
  local rest="${1//$'\n'/ }" i c expr_body in_quote quote_char closed
  while [[ "$rest" == *"$VIIF_EXPR_OPEN"* ]]; do
    rest="${rest#*"$VIIF_EXPR_OPEN"}"
    # Find the closing }} while respecting quoted strings inside the expression
    expr_body=""
    in_quote=0
    quote_char=""
    closed=0
    i=0
    while (( i < ${#rest} )); do
      c="${rest:$i:1}"
      if (( in_quote )); then
        expr_body+="$c"
        if [[ "$c" = "$quote_char" ]] && [[ "${rest:$((i-1)):1}" != "\\" ]]; then
          in_quote=0
        fi
      else
        if [[ "$c" = '"' ]] || [[ "$c" = "'" ]]; then
          expr_body+="$c"
          in_quote=1
          quote_char="$c"
        elif [[ "$c" = "}" ]] && [[ "${rest:$((i+1)):1}" = "}" ]]; then
          # Found closing }}
          printf '%s\n' "$expr_body"
          rest="${rest:$((i+2))}"
          closed=1
          break
        else
          expr_body+="$c"
        fi
      fi
      (( i++ ))
    done
    # Unclosed ${{ — validate the remaining tail rather than dropping it.
    if (( ! closed )); then
      printf '%s\n' "$expr_body"
      rest=""
    fi
  done
}

# viif_group_stems <group> — print the literal STEM(s) a concurrency group can
# begin with (sorted, de-duplicated): the text before any placeholder. A group
# with a literal head (`role-${{ … }}`) has that head as its one stem. A group
# that is one whole expression has as stems the literals in RESULT position of its
# first expression — the first argument of a top-level format() and bare string
# operands of ||/&& — cut at the first `{0}`-style placeholder. Comparison operands
# (`github.event_name == 'pull_request'`), nested format() arguments, and other
# function arguments are not group names and are skipped. Used for both the role
# prefix rule and the reusable-collision rule.
viif_group_stems() {
  local group="${1//$'\n'/ }" head
  head="${group%%"$VIIF_EXPR_OPEN"*}"
  head="${head#"${head%%[![:space:]]*}"}"
  [[ "$group" == *"$VIIF_EXPR_OPEN"* ]] || head="${head%"${head##*[![:space:]]}"}"
  if [[ -n "$head" ]]; then
    printf '%s\n' "$head"
    return 0
  fi
  viif_group_exprs "$group" | awk '
    function skipws() { while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++ }
    {
      s = $0; n = length(s); i = 1; sp = 0; prev = "START"; dead = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (c ~ /[ \t]/) { i++; continue }
        if (c == "\047") {
          lit = ""; j = i + 1
          while (j <= n) {
            d = substr(s, j, 1)
            if (d == "\047") { if (substr(s, j + 1, 1) == "\047") { lit = lit d; j += 2; continue } break }
            lit = lit d; j++
          }
          i = j + 1; skipws(); nx = substr(s, i, 2)
          calls = 0
          for (q = 1; q <= sp; q++) if (st[q] != "G") calls++
          cand = 0
          if (calls == 0) cand = (prev != "CMP" && nx !~ /^(==|!=|<|>)/)
          else if (calls == 1 && st[sp] == "F" && prev == "FOPEN") cand = 1
          if (cand && !dead) { p = index(lit, "{"); stem = p ? substr(lit, 1, p - 1) : lit; if (stem != "") print stem }
          # A non-empty top-level literal is truthy, so `lit || …` short-circuits:
          # everything to its right is unreachable as a group result.
          if (cand && lit != "" && nx ~ /^\|\|/) dead = 1
          prev = "LIT"; continue
        }
        two = substr(s, i, 2)
        if (two == "||" || two == "&&") { prev = "LOGIC"; i += 2; continue }
        if (two == "==" || two == "!=" || two == "<=" || two == ">=") { prev = "CMP"; i += 2; continue }
        if (c == "<" || c == ">") { prev = "CMP"; i++; continue }
        if (c == "(") { st[++sp] = "G"; prev = "GOPEN"; i++; continue }
        if (c == "[") { st[++sp] = "I"; prev = "IOPEN"; i++; continue }
        if (c == ")" || c == "]") { if (sp > 0) sp--; prev = "CLOSE"; i++; continue }
        if (c ~ /[A-Za-z0-9_]/) {
          j = i; while (j <= n && substr(s, j, 1) ~ /[A-Za-z0-9_.*-]/) j++
          id = substr(s, i, j - i); i = j; skipws()
          if (substr(s, i, 1) == "(") {
            st[++sp] = (tolower(id) == "format") ? "F" : "C"
            prev = (st[sp] == "F") ? "FOPEN" : "COPEN"; i++; continue
          }
          # A context reference in result position (not a comparison/&& operand, not
          # a function argument) can itself be the group — unprefixed. Emit a
          # sentinel stem so the role-prefix rule rejects it.
          calls = 0
          for (q = 1; q <= sp; q++) if (st[q] != "G") calls++
          nx = substr(s, i, 2)
          if (!dead && calls == 0 && prev != "CMP" && nx !~ /^(==|!=|<|>|&&)/ && id !~ /^(true|false|null)$/) print "<dynamic>"
          prev = "ID"; continue
        }
        prev = "OTHER"; i++
      }
    }' | LC_ALL=C sort -u
}

# viif_check_concurrency <role> <group> <cancel-in-progress> — the ADR-0010
# bounds on one job-level concurrency: block. Prints one reason per violation and
# returns 1; prints nothing and returns 0 if bounded. <cancel-in-progress> is the
# raw value ("" when absent). Checks:
#   (1) every ${{ }} in the group reads only the event surface a job-level if:
#       may read — the SAME viif_forbidden predicate, not a second one;
#   (2) cancel-in-progress, if set, is a literal boolean;
#   (3) every group stem carries the role name as a prefix (`<role>-…`).
# The other half of the collision rule (no reuse of a group the pinned reusable
# declares) needs the reusable at its pinned ref; validate-caller-inputs.sh owns it.
viif_check_concurrency() {
  local role="$1" group="$2" cancel="$3" rc=0 expr bad stem stems group_exprs
  if [[ -z "$group" ]]; then
    echo "concurrency: declares no group"
    return 1
  fi

  group_exprs="$(viif_group_exprs "$group")"
  while IFS= read -r expr; do
    [[ -n "$expr" ]] || continue
    if ! bad="$(viif_forbidden "$expr")"; then
      echo "concurrency.group reaches beyond the event payload — forbidden construct(s): ${bad}"
      rc=1
    fi
  done <<< "$group_exprs"

  case "$cancel" in
    ''|true|false) : ;;
    __NOT_BOOLEAN__) echo "concurrency.cancel-in-progress must be a literal boolean (true/false), not a string"; rc=1 ;;
    *) echo "concurrency.cancel-in-progress must be a literal boolean (true/false), got: ${cancel}"; rc=1 ;;
  esac

  stems="$(viif_group_stems "$group")"
  if [[ -z "$stems" ]]; then
    echo "concurrency.group carries no literal role prefix — it must begin with '${role}-'"
    rc=1
  fi
  while IFS= read -r stem; do
    [[ -n "$stem" ]] || continue
    case "$stem" in
      "$role"-*) : ;;
      "<dynamic>") echo "concurrency.group can resolve to a bare expression value without the role prefix — every possible leading result must begin with '${role}-'"; rc=1 ;;
      *) echo "concurrency.group '${stem}' does not carry the role name as a prefix — it must begin with '${role}-'"; rc=1 ;;
    esac
  done <<< "$stems"
  return "$rc"
}

# viif_job_concurrency <file> <job> — print the job's concurrency group and
# cancel-in-progress, separated by \x1f ("" for each when absent; a non-
# whitespace separator so an empty group cannot shift the fields on read). A scalar
# `concurrency: <group>` is the group with no cancel-in-progress. Deliberately
# avoids yq's `//` on cancel-in-progress: `false // ""` would drop a literal false.
# Requires cancel-in-progress to be a literal boolean (yq type "boolean", or the
# "!!bool" tag some yq versions print), not a quoted string.
viif_job_concurrency() {
  local file="$1" job="$2" type_val group cancel=""
  type_val="$(yq ".jobs[\"$job\"].concurrency | type" "$file" 2>/dev/null)"
  case "$type_val" in
    'object'|'!!map')
      group="$(yq ".jobs[\"$job\"].concurrency.group // \"\"" "$file" 2>/dev/null)"
      # Check that cancel-in-progress, if present, is a literal boolean (type "boolean" or "!!bool")
      local cancel_type
      cancel_type="$(yq ".jobs[\"$job\"].concurrency[\"cancel-in-progress\"] | type" "$file" 2>/dev/null)"
      if [[ "$cancel_type" = "boolean" ]] || [[ "$cancel_type" = "!!bool" ]]; then
        cancel="$(yq ".jobs[\"$job\"].concurrency[\"cancel-in-progress\"]" "$file" 2>/dev/null)"
      elif [[ "$(yq ".jobs[\"$job\"].concurrency | has(\"cancel-in-progress\")" "$file" 2>/dev/null)" = "true" ]]; then
        # cancel-in-progress is present but not a boolean — this is an error, mark with special value
        cancel="__NOT_BOOLEAN__"
      fi
      ;;
    'null'|'!!null'|'') group="" ;;
    *) group="$(yq ".jobs[\"$job\"].concurrency" "$file" 2>/dev/null)" ;;
  esac
  printf '%s\x1f%s\n' "${group//$'\n'/ }" "$cancel"
}

# ── file-level validation ─────────────────────────────────────────────────────

# viif_validate_ingress <file> — validate one agent-ingress workflow file. Each
# job must be a thin caller (reusable `uses:` pin) whose `if:` is a pure event
# filter. Emits ::error:: naming the offending job (and, for an if: violation,
# the forbidden construct); returns 1 on any failure, 0 if clean.
viif_validate_ingress() {
  local file="$1" rc=0 job uses ifexpr bad group cancel reason concurrency_checks
  local -a jobs

  mapfile -t jobs < <(yq '.jobs | keys | .[]' "$file" 2>/dev/null)
  if [[ "${#jobs[@]}" -eq 0 ]]; then
    echo "::error::agent-ingress $(basename "$file") declares no jobs"
    return 1
  fi

  for job in "${jobs[@]}"; do
    [[ -n "$job" ]] || continue

    # (1) thin-caller structural check: the job MUST pin a reusable via uses:.
    uses="$(yq ".jobs[\"$job\"].uses // \"\"" "$file" 2>/dev/null)"
    if [[ -z "$uses" ]] || [[ "$uses" = "null" ]]; then
      echo "::error::agent-ingress job '$job' is not a thin caller — it has no reusable 'uses:' pin (an ingress job must be a thin caller)"
      rc=1
      continue
    fi

    # (2) if:-as-event-filter check.
    ifexpr="$(yq ".jobs[\"$job\"].if // \"\"" "$file" 2>/dev/null)"
    [[ "$ifexpr" = "null" ]] && ifexpr=""
    if [[ -n "$ifexpr" ]]; then
      if bad="$(viif_forbidden "$ifexpr")"; then
        : # pure event filter
      else
        echo "::error::agent-ingress job '$job' if: reaches for repo state, not the event — forbidden construct(s): ${bad} (an ingress if: may reference only the delivered event; move repo-state logic into the reusable)"
        rc=1
      fi
    fi

    # (3) job-level concurrency: bounds (ADR-0010).
    local has_concurrency
    has_concurrency="$(yq ".jobs[\"$job\"] | has(\"concurrency\")" "$file" 2>/dev/null)"
    if [[ "$has_concurrency" = "true" ]]; then
      IFS=$'\x1f' read -r group cancel < <(viif_job_concurrency "$file" "$job")
      concurrency_checks="$(viif_check_concurrency "$job" "$group" "$cancel" || true)"
      while IFS= read -r reason; do
        [[ -n "$reason" ]] || continue
        echo "::error::agent-ingress job '$job' ${reason} (ADR-0010: a job-level concurrency group may read only the event surface an if: may read, must carry the role name as a prefix, and cancel-in-progress must be a literal boolean)"
        rc=1
      done <<< "$concurrency_checks"
    fi
  done

  return "$rc"
}

# ── repo scan ────────────────────────────────────────────────────────────────

viif_scan() {
  local root="$1" ingress="$1/.github/workflows/agent-ingress.yml"
  if [[ ! -f "$ingress" ]]; then
    echo "ingress-if: no agent-ingress.yml under ${root}/.github/workflows — nothing to check (clean pass)."
    return 0
  fi
  if viif_validate_ingress "$ingress"; then
    echo "ingress-if: OK — every agent-ingress job is a thin caller with a pure event-filter if: and bounded concurrency."
    return 0
  fi
  echo "" >&2
  echo "ingress-if: FAIL — an agent-ingress job is not a thin caller, its if: reaches for repo state, or its concurrency: is unbounded." >&2
  echo "An ingress if: (and concurrency.group) may reference ONLY the delivered event. See tests/fixtures/agent-ingress/if-filter-rulings.tsv, ADR-0007 and ADR-0010." >&2
  return 1
}

main() {
  command -v yq >/dev/null 2>&1 || { echo "::error::yq is required but not installed." >&2; return 1; }
  local root="${VIIF_ROOT:-}"
  [[ -n "$root" ]] || root="$(viif_repo_root)"
  viif_scan "$root"
}

# Run only when executed directly, so tests can source the helpers.
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
