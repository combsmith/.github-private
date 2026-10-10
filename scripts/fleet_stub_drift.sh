#!/usr/bin/env bash
# fleet_stub_drift.sh — initiative-planner stub coverage & drift detection for
# the Actions Fleet Monitor (#822, AC#2 + AC#3). Sourced by fleet_monitor.sh.
#
# The initiative-planner is adopted by fleet repos via a per-repo thin-caller
# stub at .github/workflows/initiative-planner.yml (#820), deployed verbatim
# from the canonical org template standards/workflows/initiative-planner.yml.
# This module compares each enrolled repo's stub blob SHA against the canonical
# template SHA and classifies coverage so the monitor can alert on drift — the
# silent-revert class of failure #822 exists to catch (cf. #655).
#
# All functions are PURE: they take a canonical SHA + a per-repo stub blob SHA
# (or a drift TSV) and write to stdout. No network. The blob SHAs are the values
# GitHub's contents API returns in `.sha` (git blob object IDs), so equal SHAs
# mean byte-identical files. Network fetching lives in fleet_monitor.sh.
#
# Drift TSV format (4 fields, tab-separated):
#   1:repo  2:status  3:repo_sha  4:canonical_sha
# status ∈ { ALIGNED, DRIFTED, MISSING }
#   ALIGNED — stub present and byte-identical to the canonical template
#   DRIFTED — stub present but its blob SHA differs (the alertable set)
#   MISSING — no stub in the repo (not enrolled) — informational, not alerted

# classify_stub_drift <canonical_sha> <repo_sha>
# Classifies one repo's stub against the canonical template SHA.
classify_stub_drift() {
  local canonical="${1:-}" repo_sha="${2:-}"
  if [ -z "$repo_sha" ] || [ "$repo_sha" = "null" ]; then
    echo "MISSING"
  elif [ "$repo_sha" = "$canonical" ]; then
    echo "ALIGNED"
  else
    echo "DRIFTED"
  fi
}

# stub_drift_row <repo> <canonical_sha> <repo_sha>
# Emits one classified TSV row: repo<TAB>status<TAB>repo_sha<TAB>canonical_sha.
stub_drift_row() {
  local repo="${1:-}" canonical="${2:-}" repo_sha="${3:-}"
  local status
  status="$(classify_stub_drift "$canonical" "$repo_sha")"
  printf '%s\t%s\t%s\t%s\n' "$repo" "$status" "$repo_sha" "$canonical"
}

# ── Per-job (role-selector) extraction (#1726) ────────────────────────────────
# The per-role Class-1 caller stubs collapse into ONE agent-ingress.yml with
# EXACTLY ONE job per collapsed role (ADR-0007). A per-role file path 404s once
# collapsed, so whole-file blob-SHA detection reads every collapsed repo as
# MISSING ("not enrolled") and a whole-file compare against a single-role
# canonical is meaningless. These helpers move the comparison unit from the whole
# file to a single extracted job BLOCK, so drift and remediation understand the
# collapsed form. They are PURE: content in on stdin, text/SHA out on stdout.

# extract_job_block <job> — read a workflow YAML on stdin and print the lines of
# the `jobs.<job>:` block: the `  <job>:` key line (2-space indent) and every
# following line more deeply indented than the key (plus interior blank lines).
# The block ends at the first non-blank line indented ≤ 2 spaces (the next job
# key, a job's leading comment, or a top-level key), which is NOT printed. Empty
# output ⇒ the job is absent. Deterministic, so equal blocks ⇒ byte-identical.
extract_job_block() {
  local job="${1:-}"
  [ -n "$job" ] || return 0
  awk -v job="$job" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    BEGIN { injob = 0 }
    {
      if (!injob) {
        if ($0 ~ ("^  " job ":([ \t]|$)")) { injob = 1; print; next }
      } else {
        if ($0 ~ /^[ \t]*$/) { print; next }   # interior blank line — keep
        if (indent($0) <= 2) { exit }          # next job / top-level — stop
        print
      }
    }
  '
}

# job_block_sha <job> — read a workflow YAML on stdin and print the git blob SHA
# of its extracted `<job>` block (via git hash-object). Empty output when the job
# block is absent, so the caller classifies it as MISSING (not resurrected).
job_block_sha() {
  local job="${1:-}" block
  block="$(extract_job_block "$job")"
  [ -n "$block" ] || return 0
  printf '%s' "$block" | git hash-object --stdin
}

# patch_job_block <job> <replacement_file> — read a workflow YAML on stdin and
# print it back with the `jobs.<job>:` block REPLACED by the verbatim contents of
# <replacement_file> (the canonical block). This is the read-modify-write that
# remediates ONE collapsed role in agent-ingress.yml without rewriting the file or
# touching sibling jobs (#1726 AC #3). The replaced span is exactly what
# extract_job_block would remove (key line + deeper-indented lines + interior
# blanks), so a canonical block produced by extract_job_block slots in cleanly and
# the post-patch block SHA equals canon. If the job is ABSENT, nothing is inserted
# and it returns 3 — a deliberately-removed stub is NEVER resurrected (AC #3);
# every other line is emitted verbatim so siblings are byte-preserved.
patch_job_block() {
  local job="${1:-}" repl="${2:-}"
  [ -n "$job" ] && [ -n "$repl" ] || return 2
  awk -v job="$job" -v repl="$repl" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    BEGIN { injob = 0; found = 0 }
    {
      if (!injob) {
        if ($0 ~ ("^  " job ":([ \t]|$)")) {
          while ((getline line < repl) > 0) print line   # canonical block verbatim
          close(repl)
          injob = 1; found = 1; next
        }
        print; next                                       # sibling / top-level — keep
      } else {
        if ($0 ~ /^[ \t]*$/) { next }        # consume old interior blank
        if (indent($0) <= 2) { injob = 0; print; next }   # old block ended — resume copy
        next                                 # consume old block body
      }
    }
    END { if (!found) exit 3 }                # job absent — never resurrect
  '
}

# classify_role_drift <ingress_present> <canon_block_sha> <ingress_block_sha> \
#                     <legacy_canon_sha> <legacy_repo_sha>
# Classify one repo's coverage for a single collapsed role, honoring the collapse
# so a deleted per-role stub is NEVER resurrected. Precedence:
#   • ingress_present == "yes" (the repo has agent-ingress.yml): classify on the
#     BLOCK SHAs and IGNORE the legacy per-role file entirely. An absent role
#     block ⇒ MISSING (the role was deliberately not collapsed here — do NOT fall
#     back to the legacy file, which would mask/resurrect a removed stub).
#   • otherwise (no ingress file — a legacy repo mid-rollout): classify on the
#     legacy whole-file SHAs, exactly as before (backward compatibility, AC #4).
#     With no legacy canonical SHA (the role has no published per-role template)
#     the legacy file cannot be compared, so it is MISSING, never DRIFTED (#1729).
classify_role_drift() {
  local ingress_present="${1:-}" canon_block="${2:-}" ingress_block="${3:-}"
  local legacy_canon="${4:-}" legacy_repo="${5:-}"
  if [ "$ingress_present" = "yes" ]; then
    classify_stub_drift "$canon_block" "$ingress_block"
  elif [ -z "$legacy_canon" ]; then
    echo "MISSING"
  else
    classify_stub_drift "$legacy_canon" "$legacy_repo"
  fi
}

# stub_drift_row_role <repo> <ingress_present> <canon_block_sha> \
#                     <ingress_block_sha> <legacy_canon_sha> <legacy_repo_sha>
# Emits ONE classified TSV row in the SAME 4-field shape stub_drift_row uses
# (repo<TAB>status<TAB>repo_sha<TAB>canonical_sha), so per-job (#1726) rows flow
# through the identical report/alert path as whole-file (#822/#886) rows. The
# emitted repo_sha/canonical_sha are the pair the classification was actually made
# on: the block SHAs when an agent-ingress.yml is present, else the legacy
# whole-file SHAs — so the rendered table stays meaningful either way.
stub_drift_row_role() {
  local repo="${1:-}" ingress_present="${2:-}" canon_block="${3:-}"
  local ingress_block="${4:-}" legacy_canon="${5:-}" legacy_repo="${6:-}"
  local status repo_sha canonical
  status="$(classify_role_drift "$ingress_present" "$canon_block" \
    "$ingress_block" "$legacy_canon" "$legacy_repo")"
  if [ "$ingress_present" = "yes" ]; then
    repo_sha="$ingress_block"; canonical="$canon_block"
  else
    repo_sha="$legacy_repo"; canonical="$legacy_canon"
  fi
  printf '%s\t%s\t%s\t%s\n' "$repo" "$status" "$repo_sha" "$canonical"
}

# count_stub_drift <tsv_file> <status>
# Counts rows whose status column (field 2) equals <status>. 0 if file absent.
count_stub_drift() {
  local f="${1:-}" want="${2:-}"
  [ -n "$f" ] && [ -f "$f" ] || { echo 0; return 0; }
  awk -F'\t' -v w="$want" '$2 == w { n++ } END { print n + 0 }' "$f"
}

# stub_drift_alert_json <tsv_file> [stub_label] [stub_file] [role]
# Emits a JSON array of the DRIFTED rows (the alertable set — enrolled repos
# whose stub no longer matches canon). Empty/absent file → "[]".
# When <stub_label>/<stub_file> are given, each row is tagged with `stub` and
# `stub_file` so a multi-stub alert step can group/route per stub kind. When
# <role> is given (a collapsed agent-ingress.yml job, #1726), each row is also
# tagged with `role` so remediation patches the RIGHT job block — the stub_file
# alone is ambiguous once several roles share one agent-ingress.yml.
stub_drift_alert_json() {
  local f="${1:-}" stub_label="${2:-}" stub_file="${3:-}" role="${4:-}"
  if [ -z "$f" ] || [ ! -s "$f" ]; then
    echo "[]"
    return 0
  fi
  jq -Rn --arg stub "$stub_label" --arg stub_file "$stub_file" --arg role "$role" '
    [ inputs
      | select(length > 0)
      | split("\t")
      | select(length >= 4 and .[1] == "DRIFTED")
      | { repo: .[0], status: .[1], repo_sha: .[2], canonical_sha: .[3] }
      | if $stub != "" then . + { stub: $stub } else . end
      | if $stub_file != "" then . + { stub_file: $stub_file } else . end
      | if $role != "" then . + { role: $role } else . end
    ]' < "$f"
}

# generate_stub_drift_report <tsv_file> <canonical_sha> [stub_label]
# Prints a Markdown section: coverage counts plus a table of every non-ALIGNED
# repo. Pure: reads the TSV, writes stdout. <stub_label> headlines the section
# (default "Initiative-planner" preserves the #822 single-stub heading).
generate_stub_drift_report() {
  local f="${1:-}" canonical="${2:-}" stub_label="${3:-Initiative-planner}"
  local short_canon="${canonical:0:7}"
  local aligned drifted missing total
  aligned="$(count_stub_drift "$f" "ALIGNED")"
  drifted="$(count_stub_drift "$f" "DRIFTED")"
  missing="$(count_stub_drift "$f" "MISSING")"
  total=$(( aligned + drifted ))  # enrolled = repos that have the stub

  printf '## %s stub coverage & drift\n\n' "$stub_label"
  printf 'Canonical template SHA: `%s` · enrolled repos (stub present): **%s**\n\n' \
    "$short_canon" "$total"
  printf '✅ ALIGNED: %s  🔴 DRIFTED: %s  ⬜ MISSING (not enrolled): %s\n\n' \
    "$aligned" "$drifted" "$missing"

  if [ "$drifted" -eq 0 ]; then
    printf '_No stub drift detected — every enrolled repo matches the canonical template._\n'
    return 0
  fi

  printf 'These enrolled repos have drifted from the canonical stub — re-sync them:\n\n'
  printf '| Repo | Status | Stub SHA | Canonical SHA |\n'
  printf '|---|---|---|---|\n'
  awk -F'\t' '$2 == "DRIFTED" {
    printf "| `%s` | 🔴 %s | `%s` | `%s` |\n", $1, $2, substr($3,1,7), substr($4,1,7)
  }' "$f"
}
