#!/usr/bin/env bash
set -euo pipefail
# dev-lead-lint.sh — runs repo-specific lint checks before committing.
# Mirrors the checks in lint.yml and ci.yml that are fast and tool-free.
# Run from the repo root. Exits 0 if all checks pass, non-zero on any failure.

fail=0

# ── 1. ShellCheck ─────────────────────────────────────────────────────────────
# Matches the ci.yml ShellCheck job: severity=warning, follow sources (-x),
# recurse scripts/**/*.sh.
if command -v shellcheck >/dev/null 2>&1; then
  shopt -s globstar nullglob
  shell_files=(scripts/**/*.sh)
  shopt -u globstar nullglob
  if [ "${#shell_files[@]}" -gt 0 ]; then
    echo "  [lint] shellcheck on ${#shell_files[@]} file(s)..."
    shellcheck --severity=warning -x "${shell_files[@]}" || fail=1
  else
    echo "  [lint] shellcheck: no .sh files found — skipping"
  fi
else
  echo "  [lint] shellcheck not found — skipping (install shellcheck to enable this check)"
fi

# ── 2. Agent profile frontmatter ──────────────────────────────────────────────
# Matches the lint.yml validate-agent-profiles job: checks frontmatter exists,
# is valid YAML, name field matches filename (kebab-case), description and
# tools fields are present.
shopt -s nullglob
agent_files=(agents/*.md)
shopt -u nullglob
if [ "${#agent_files[@]}" -gt 0 ]; then
  echo "  [lint] validating ${#agent_files[@]} agent profile(s)..."

  # Ensure PyYAML is available before validating profiles.
  pyyaml_ok=1
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  [lint] python3 not found — skipping agent profile validation (install python3 to enable)"
    pyyaml_ok=0
  elif ! python3 -c "import yaml" >/dev/null 2>&1; then
    echo "  [lint] PyYAML not available — skipping agent profile validation (install: pip3 install pyyaml)"
    pyyaml_ok=0
  fi

  if [ "$pyyaml_ok" -eq 1 ]; then
    profile_fail=0
    for f in "${agent_files[@]}"; do
      name_from_file=$(basename "$f" .md)

      if ! awk 'NR==1 && $0!="---"{exit 1} /^---/{n++; if(n==2) exit} END{exit (n<2)}' "$f" 2>/dev/null; then
        echo "FAIL: $f — frontmatter missing or does not begin on line 1"
        profile_fail=1
        continue
      fi

      frontmatter=$(awk 'BEGIN{found=0} /^---/{found++; if(found==2) exit; next} found==1{print}' "$f")

      if ! printf '%s\n' "$frontmatter" | python3 -c "import sys, yaml; yaml.safe_load(sys.stdin)" 2>/dev/null; then
        echo "FAIL: $f — invalid YAML in frontmatter"
        profile_fail=1
        continue
      fi

      name_from_front=$(printf '%s\n' "$frontmatter" \
        | sed -n 's/^name:[[:space:]]*//p' \
        | sed "s/^['\"]//;s/['\"]$//" \
        | head -1)

      if [ -z "$name_from_front" ]; then
        echo "FAIL: $f — missing 'name' field in frontmatter"
        profile_fail=1
      elif [ "$name_from_front" != "$name_from_file" ]; then
        echo "FAIL: $f — name '$name_from_front' does not match filename '$name_from_file'"
        profile_fail=1
      elif ! printf '%s\n' "$name_from_file" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$'; then
        echo "FAIL: $f — name '$name_from_file' is not kebab-case"
        profile_fail=1
      fi

      for field in description tools; do
        if ! printf '%s\n' "$frontmatter" | grep -q "^${field}:"; then
          echo "FAIL: $f — missing '${field}' field in frontmatter"
          profile_fail=1
        fi
      done

      [ "$profile_fail" -eq 0 ] && echo "OK: $f"
    done
    [ "$profile_fail" -eq 0 ] || fail=1
  fi
fi

# ── 3. CODEOWNERS validation ──────────────────────────────────────────────────
# Checks that every owner line lists @petry-projects/org-leads first.
# Standard: standards/codeowners-standard.md (codeowners-org-leads-not-first check)
codeowners_file=""
for candidate in ".github/CODEOWNERS" "CODEOWNERS" "docs/CODEOWNERS"; do
  if [ -f "$candidate" ]; then
    codeowners_file="$candidate"
    break
  fi
done

if [ -n "$codeowners_file" ]; then
  echo "  [lint] validating $codeowners_file..."
  codeowners_fail=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    clean_line="${line//\\ /}"
    read -r -a parts <<< "$clean_line"
    first_owner="${parts[1]:-}"
    if [ "$first_owner" != "@petry-projects/org-leads" ]; then
      echo "FAIL: $codeowners_file — @petry-projects/org-leads must be the first owner on line: $line"
      codeowners_fail=1
    fi
  done < "$codeowners_file"
  [ "$codeowners_fail" -eq 0 ] || fail=1
  [ "$codeowners_fail" -eq 0 ] && echo "OK: $codeowners_file"
fi

if [ "$fail" -eq 0 ]; then
  echo "  [lint] all checks passed"
fi
exit "$fail"
