#!/usr/bin/env bash
# reviewer-sources.sh — sourced lookup helper for the reviewer-source registry (#1425).
#
# Owns reads of scripts/lib/reviewer-sources.tsv, the single source of truth for
# every third-party review bot the org recognizes. Three consumers project from it
# so their lists can never drift again (the 2026-08-02 graphite-app deadlock):
#   * dev-lead's trust check      — scripts/dev-lead-intent.sh (TRUSTED_BOTS)
#   * the advisory approval gate   — scripts/lib/advisory-review-gate.sh
#   * the reviewer scorecard       — scripts/reviewer_report.sh
#
# THE #1425 INVARIANT: (creates_threads=yes) ⇒ (dev_lead_trusted=yes). A bot that
# posts inline review comments creates a blocking review thread; if dev-lead may
# not act on it, no automation can clear it. reviewer_sources_assert_invariant
# enforces this; tests/test_reviewer_sources.bats runs it in CI.
#
# Usage: source this file, then call one of the reviewer_sources_* functions.
# Manifest path is resolved relative to this file; override with
# REVIEWER_SOURCES_MANIFEST for tests.

set -euo pipefail

# Resolve the manifest path once, relative to this file (works when sourced from
# anywhere). Honor an override so callers/tests can point elsewhere.
if [ -z "${REVIEWER_SOURCES_MANIFEST:-}" ]; then
  REVIEWER_SOURCES_MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reviewer-sources.tsv"
fi

# _reviewer_sources_manifest_or_die <caller>
#   Guards manifest existence; prints a diagnostic naming the caller.
_reviewer_sources_manifest_or_die() {
  if [ -f "$REVIEWER_SOURCES_MANIFEST" ]; then
    return 0
  fi
  echo "$1: manifest file not found at $REVIEWER_SOURCES_MANIFEST" >&2
  return 1
}

# reviewer_sources_version
#   Prints the manifest's schema_version (from its `# schema_version: N` comment).
#   Returns non-zero if absent so a malformed manifest is detected loudly.
reviewer_sources_version() {
  _reviewer_sources_manifest_or_die reviewer_sources_version || return 1
  local v
  v=$(awk '/^#[[:space:]]*schema_version:/ { gsub(/[^0-9]/, "", $0); print; exit }' \
        "$REVIEWER_SOURCES_MANIFEST") || true
  [ -n "$v" ] || { echo "reviewer_sources_version: no schema_version in $REVIEWER_SOURCES_MANIFEST" >&2; return 1; }
  printf '%s\n' "$v"
}

# reviewer_sources_logins
#   Every registered source login (column 1), one per line.
reviewer_sources_logins() {
  _reviewer_sources_manifest_or_die reviewer_sources_logins || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" { print $1 }' "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_trusted_logins
#   Logins with dev_lead_trusted=yes (column 3), one per line.
reviewer_sources_trusted_logins() {
  _reviewer_sources_manifest_or_die reviewer_sources_trusted_logins || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" && $3 == "yes" { print $1 }' "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_thread_creator_logins
#   Logins with creates_threads=yes (column 2), one per line.
reviewer_sources_thread_creator_logins() {
  _reviewer_sources_manifest_or_die reviewer_sources_thread_creator_logins || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" && $2 == "yes" { print $1 }' "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_advisory_gate_logins
#   Logins with advisory_gate=yes (column 4), one per line.
reviewer_sources_advisory_gate_logins() {
  _reviewer_sources_manifest_or_die reviewer_sources_advisory_gate_logins || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" && $4 == "yes" { print $1 }' "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_check_run_reporters
#   Sources that report a review through a check run (column 5 != "-"), emitted as
#   "<login>\t<check_run_name>" one per line. A bot listed here posts each review as
#   a check run whose completed run counts as a real response even with zero PR
#   comments/reviews (the Graphite clean-pass case, #1908). Empty output means no
#   registered source reports via check runs. Data-driven: the scorecard and the
#   advisory gate (#2005) read this instead of hard-coding graphite-app.
reviewer_sources_check_run_reporters() {
  _reviewer_sources_manifest_or_die reviewer_sources_check_run_reporters || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" && $5 != "" && $5 != "-" { print $1 "\t" $5 }' \
    "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_info_status_patterns
#   Sources that declare a known clean *informational* status-comment pattern
#   (column 6 != "-"), emitted as "<login>\t<pattern>" one per line. A comment
#   authored by <login> whose body matches <pattern> is a clean status report
#   (e.g. SonarCloud's "Quality Gate passed") that carries no finding and needs no
#   disposition — maintainer-comment-gate.sh reads this to auto-clear it (#1918).
#   Empty output means no registered source declares an info-status pattern.
#   Data-driven: the gate reads this instead of hard-coding logins.
reviewer_sources_info_status_patterns() {
  _reviewer_sources_manifest_or_die reviewer_sources_info_status_patterns || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" && $6 != "" && $6 != "-" { print $1 "\t" $6 }' \
    "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_finding_section_pattern
#   The case-sensitive regex (jq test()) that recognizes a FINDING-BEARING section
#   inside a reviewer bot's comment (#2008). CodeRabbit posts ONE summary comment,
#   edited in place, carrying independently throttled outputs: a rate-limited code
#   review can sit next to a Security Architecture Review that still reports real
#   findings (PR #2000). A body this matches carries a finding, so:
#     * no info_status_pattern may clear it (maintainer-comment-gate.sh and the
#       maintainer-resolve-comment.sh bot path refuse it), and
#     * an `informational` disposition never covers it (the gate and the
#       dev-lead harness refuse it) — each finding needs a real disposition.
#   Matched sections:
#     * an `architecture_review` section (terminated or not) carrying Retained
#       concerns, Hardening Proposals, a severity-labelled item, or a non-minimal
#       risk rating. A "Minimal" section with none of those is clean.
#     * a non-zero "Actionable comments posted: N".
#     * "Outside diff range comments" or "Nitpick comments" with any count but 0.
#     * a CodeAnt summary (#2178) carrying a "**Suggestion:**" marker or a
#       "PR Risk:" level other than "Low Risk". Only the clean Low Risk form is neutral.
#   Fail closed: it errs toward matching. A false match only costs a real
#   disposition; a missed one lets a finding be waved away.
reviewer_sources_finding_section_pattern() {
  printf '%s\n' '<!-- architecture_review_start -->(?:(?!<!-- architecture_review_end -->)[\s\S])*?(?:Retained concerns|Hardening Proposals|\*\*(?:Critical|High|Medium|Moderate|Low|Major|Minor)\s*·|Security architecture risk:\*\*\s*_[^_]*?(?:Low|Moderate|Medium|Elevated|High|Critical|Severe))|Actionable comments posted:\s*[1-9]|Outside diff range comments(?!\s*\(\s*0\s*\))|Nitpick comments(?!\s*\(\s*0\s*\))|\*\*Suggestion:\*\*|PR Risk:\s*(?!\**Low Risk\b(?:\*\*)?)\S'
}

# reviewer_sources_trusted_bots_csv
#   dev-lead's webhook-facing trusted set: each trusted login with a "[bot]"
#   suffix, joined by commas. This is exactly the TRUSTED_BOTS default.
reviewer_sources_trusted_bots_csv() {
  local login csv="" logins
  logins="$(reviewer_sources_trusted_logins)" || return 1
  while IFS= read -r login; do
    [ -n "$login" ] || continue
    csv="${csv:+$csv,}${login}[bot]"
  done <<< "$logins"
  printf '%s\n' "$csv"
}

# reviewer_sources_invariant_violations
#   Prints each login that violates the #1425 invariant
#   (creates_threads=yes but dev_lead_trusted=no), one per line. Empty output
#   means the registry is sound.
reviewer_sources_invariant_violations() {
  _reviewer_sources_manifest_or_die reviewer_sources_invariant_violations || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" && $2 == "yes" && $3 != "yes" { print $1 }' \
    "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_assert_invariant
#   Exits 0 if the registry satisfies the #1425 invariant; otherwise prints the
#   offending logins and returns non-zero. This is the CI guard.
reviewer_sources_assert_invariant() {
  local violations
  violations="$(reviewer_sources_invariant_violations)" || return 1
  if [ -z "$violations" ]; then
    return 0
  fi
  echo "reviewer_sources: #1425 invariant violated — thread-creating sources that are not dev-lead-trusted:" >&2
  printf '%s\n' "$violations" >&2
  return 1
}
