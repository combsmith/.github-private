#!/usr/bin/env bash
# qa-lead-test-surface.sh — the pure test-surface heuristic for the qa-lead PR
# advisory (issue #1646 — [qa-lead S3]).
#
# S3 wires a Class 1 pull_request:[opened, ready_for_review] trigger for qa-lead
# (the 2026-09-07 ruling; synchronize deliberately NOT wired). This heuristic is
# the ONLY thing standing between "qa-lead becomes useful" and "qa-lead becomes
# noise" (AC #3): it decides, from the PR's changed-file set alone, whether the
# PR carries REAL test surface worth an advisory.
#
# The rule: qa-lead advises on a PR that either
#   * touches test surface (any changed path under tests/, a *.bats file, or a
#     conventional test filename), OR
#   * changes source code with NO accompanying test change.
# It stays silent on docs-only PRs and on verbatim stub-sync PRs (workflow /
# config yaml only) — a PR with nothing of test-relevance is noise even if each
# comment would be individually correct.
#
# Pure and sourced: no network, no gh, no PR context — just string classification
# so every case is pinned by tests/test_qa_lead_test_surface.bats.

# qa_lead_classify_path <path> -> prints one of TEST | DOCS | SOURCE | OTHER
#   TEST wins over everything (a *_test.go under docs/ is still a test), so it is
#   checked first. OTHER is the "no test surface" bucket: workflow/config yaml,
#   json manifests, anything not recognised as code, tests, or docs.
qa_lead_classify_path() {
  local path="$1"
  local base="${path##*/}"

  # --- TEST: the strongest signal, checked first ---
  case "$path" in
    tests/*|*/tests/*) echo "TEST"; return 0 ;;
    *.bats)            echo "TEST"; return 0 ;;
  esac
  case "$base" in
    test_*|*_test.*|*.test.*|*_spec.*|*.spec.*)
      # The bare test_* wildcard also matches prose whose name merely starts with
      # "test_" (e.g. docs/test_plan.md). Documentation/metadata extensions are
      # NOT test surface, so fall through to DOCS for them rather than firing.
      case "$base" in
        *.md|*.markdown|*.rst|*.txt|LICENSE|COPYING|CODEOWNERS) ;;
        *) echo "TEST"; return 0 ;;
      esac
      ;;
  esac

  # --- DOCS: prose / licence / ownership metadata ---
  case "$path" in
    docs/*) echo "DOCS"; return 0 ;;
  esac
  case "$base" in
    *.md|*.markdown|*.rst|*.txt|LICENSE|COPYING|CODEOWNERS) echo "DOCS"; return 0 ;;
  esac

  # --- SOURCE: executable code that can carry behaviour ---
  case "$base" in
    *.sh|*.bash|*.py|*.js|*.jsx|*.mjs|*.cjs|*.ts|*.tsx|*.go|*.rb|*.rs|*.java|*.c|*.h|*.cpp|*.cc|*.pl)
      echo "SOURCE"; return 0 ;;
  esac

  # --- OTHER: no test surface (workflow/config yaml, json, everything else) ---
  echo "OTHER"
}

# qa_lead_test_surface <changed_paths>  (newline-separated)
#   Exit 0 (FIRE) when the PR carries test surface: any TEST path, or any SOURCE
#   path (source change — with or without an accompanying test, qa-lead has
#   something to say). Exit 1 (SKIP) for a docs-only / config-only / empty PR.
#   Blank lines are ignored so a stray trailing newline never forces a fire.
qa_lead_test_surface() {
  local changed_paths="$1"
  local path kind
  local has_test=0 has_source=0

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    kind="$(qa_lead_classify_path "$path")"
    case "$kind" in
      TEST)   has_test=1 ;;
      SOURCE) has_source=1 ;;
    esac
  done <<< "$changed_paths"

  if [ "$has_test" -eq 1 ] || [ "$has_source" -eq 1 ]; then
    return 0
  fi
  return 1
}

# qa_lead_paths_have_control_char <json_array_of_paths>
#   Exit 0 iff any path in the JSON array contains a control character (NUL, LF,
#   CR, …). The changed-file list reaches qa_lead_test_surface as newline-delimited
#   text, so a filename that itself contains an LF would split into phantom
#   records — e.g. a lone `docs/a.md\nscripts/x.sh` doc would fabricate a SOURCE
#   path and trigger the advisory on a docs-only PR (#1697 review). The workflow
#   validates the raw JSON list with this predicate BEFORE flattening and fails
#   closed (skip) when it returns true, so a control character can never forge a
#   test/source record.
qa_lead_paths_have_control_char() {
  local json="${1:-[]}"
  # explode -> codepoints; any < 32 is a C0 control character. (jq's regex
  # engine does not honour \uXXXX escapes, so match on codepoints, not a class.)
  if jq -e 'any(.[]?; explode | any(.[]; . < 32))' \
      <<< "$json" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# qa_lead_file_list_complete <received_count> <declared_count>
#   Exit 0 iff the fetched changed-file list is complete (received >= declared).
#   GitHub's GET /pulls/{n}/files endpoint caps at 3000 files (including paginated
#   results), so a PR that changes more than that yields a truncated list. Deciding
#   the gate from a partial list could omit a test/source path and mislabel the PR;
#   the workflow fails closed (skip) on an incomplete list rather than advise off
#   partial data (#1697 review). Boundary: 3000/3000 is complete, 3000/3001 is not.
qa_lead_file_list_complete() {
  local received="${1:-0}" declared="${2:-0}"
  if [ "$received" -ge "$declared" ]; then
    return 0
  fi
  return 1
}
