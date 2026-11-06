#!/usr/bin/env bash
# validate-workflow-schedules.sh — off-peak scheduling compliance check (#724, epic #722).
#
# Enforces the repo-local "Scheduled workflows" standard (AGENTS.md): no
# scheduled workflow may run at minute 0 (`0 * * * *`). Minute-0 crons cluster
# every repo's automation onto the top of the hour, contending for shared
# GitHub-hosted runner capacity; a staggered off-peak minute avoids that.
#
# The check scans this repo's own workflow/agentic sources for any schedule.cron
# whose minute (first whitespace-delimited) field is exactly 0, and fails
# reporting the offending file(s). It is deliberately a *minute-field* check, not
# a full cron validator (see the issue's Dev Notes).
#
# Scope (repo-local sources only — the frameworks/ subtrees are upstream-owned
# knowledge docs, not our schedules, and are intentionally excluded):
#   - .github/workflows/*.yml   (compiled workflows)
#   - .github/workflows/*.md    (gh-aw agentic sources)
#   - docs/aw/*.md              (agentic workflow docs that mirror the crons)
#
# Usage: validate-workflow-schedules.sh
#   SCHEDULE_LINT_ROOT — repo root to scan (default: the repo containing this
#                        script). Overridden by tests to point at fixture trees.

set -euo pipefail

# slint_extract_cron <line> — echo the cron string from a `cron:` source line,
# or nothing if the line carries no cron value. Handles single-quoted,
# double-quoted, and bare values, and strips trailing ` # comment`.
slint_extract_cron() {
  local line="$1" rest
  case "$line" in
    *cron:*) : ;;
    *) return 0 ;;
  esac
  rest="${line#*cron:}"
  # trim leading whitespace
  rest="${rest#"${rest%%[![:space:]]*}"}"
  case "$rest" in
    "'"*)
      rest="${rest#\'}"
      printf '%s\n' "${rest%%\'*}"
      ;;
    '"'*)
      rest="${rest#\"}"
      printf '%s\n' "${rest%%\"*}"
      ;;
    *)
      # bare value: take up to the first whitespace-then-comment or end of line
      rest="${rest%%#*}"
      # trim trailing whitespace
      rest="${rest%"${rest##*[![:space:]]}"}"
      printf '%s\n' "$rest"
      ;;
  esac
}

# slint_minute_field <cron> — echo the first whitespace-delimited token.
slint_minute_field() {
  local cron="$1"
  printf '%s\n' "${cron%%[[:space:]]*}"
}

# slint_minute_is_zero <cron> — return 0 when the minute field is 0 or 00 (including in lists).
slint_minute_is_zero() {
  local min
  min="$(slint_minute_field "$1")"
  case ",$min," in
    *,0,*|*,00,*) return 0 ;;
  esac
  return 1
}

# slint_scan_file <file> — print `file:lineno: <cron>` for every offending
# minute-0 schedule.cron in the file. Returns 1 if any were found.
slint_scan_file() {
  local file="$1" lineno=0 line cron found=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    cron="$(slint_extract_cron "$line")"
    [[ -n "$cron" ]] || continue
    if slint_minute_is_zero "$cron"; then
      printf '%s:%s: %s\n' "$file" "$lineno" "$cron"
      found=1
    fi
  done < "$file"
  return $found
}

# slint_scan_root <root> — scan the in-scope sources under <root>. Prints all
# offenders and returns 1 if any were found.
slint_scan_root() {
  local root="$1" file offenders=0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    slint_scan_file "$file" || offenders=1
  done < <(
    { [[ -d "$root/.github/workflows" ]] && find "$root/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.md' \) 2>/dev/null
      [[ -d "$root/docs/aw" ]] && find "$root/docs/aw" -maxdepth 1 -type f -name '*.md' 2>/dev/null
    } | sort 2>/dev/null
  )
  return $offenders
}

main() {
  local root="${SCHEDULE_LINT_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi

  if slint_scan_root "$root"; then
    echo "schedule-lint: OK — no minute-0 (top-of-hour) scheduled crons found."
    return 0
  fi

  echo "" >&2
  echo "schedule-lint: FAIL — scheduled workflows must not run at minute 0 (\`0 * * * *\`)." >&2
  echo "Use a staggered off-peak minute instead. See AGENTS.md § 'Scheduled workflows'." >&2
  return 1
}

# Only run main when executed directly, so tests can source the functions.
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
  main "$@"
fi
