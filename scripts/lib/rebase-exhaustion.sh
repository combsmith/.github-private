#!/usr/bin/env bash
# rebase-exhaustion.sh — pure decision helpers for the dev-lead rebase
# exhaustion / large-conflict guard (#865).
#
# The rebase handler (dev-lead-fix-reviews.sh, rebase intent) resolves an
# auto-rebase conflict by invoking the engine. On a hard/unresolvable conflict
# the engine call runs to the per-tier `timeout` and is SIGTERM-killed (exit 124)
# instead of aborting cleanly, and the `auto-rebase-conflict` sentinel can
# re-fire repeatedly — a burst of runs that each burn the full timeout (canary
# 2026-06-21 TalkTerm: 9 runs, all exit 124).
#
# These helpers are pure (no gh/git/network): they take already-fetched inputs
# (PR comment bodies, an exit code, a file count) and return a decision, so they
# are unit-testable in isolation (tests/dev-lead/unit/test_rebase_exhaustion.bats).
# The handler wires the gh-api reads/writes to them.

# rebase_exhaustion_marker <marker_prefix> <pr_number>
#   Emit the PR-level exhaustion marker string. Mirrors the fix-ci per-PR
#   exhaustion marker: it blocks ALL future rebase dispatches for this PR
#   (any SHA) until a human clears it.
rebase_exhaustion_marker() {
  printf '%s%s intent=rebase status=exhausted -->' "$1" "$2"
}

# rebase_is_exhausted <marker> <comment_bodies>
#   Return 0 (true) if the PR-level exhaustion marker is present in the given
#   newline-delimited comment bodies. Fixed-string match — the marker contains
#   no regex metacharacters, and matching it whole avoids the superset-PR-number
#   ambiguity a bare `pr=<n>` prefix would have.
rebase_is_exhausted() {
  local marker="$1" bodies="$2"
  printf '%s' "$bodies" | grep -qF "$marker"
}

# rebase_count_failures <marker_prefix> <pr_number> <comment_bodies>
#   Count terminal `intent=rebase status=failed` markers for this PR across all
#   SHAs. Excludes rate-limited markers (transient infra events, not evidence of
#   an unresolvable conflict) — they carry status=rate-limited, not status=failed.
#   The trailing space after the PR number keeps `pr=54` from matching `pr=549`.
rebase_count_failures() {
  local prefix="$1" pr="$2" bodies="$3" n
  n=$(printf '%s\n' "$bodies" \
    | grep -cE "${prefix}${pr} .*intent=rebase status=failed" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

# rebase_conflict_too_large <file_count> <max_files>
#   Return 0 (true) when the conflicting-file count exceeds the ceiling we will
#   hand to the engine. Above this the conflict is treated as too large to
#   resolve within the writer-tier timeout, so the handler aborts cleanly up
#   front instead of burning the full timeout to exit 124. A max of 0 disables
#   the guard (never true).
rebase_conflict_too_large() {
  local count="${1:-0}" max="${2:-0}"
  if [ "$max" -gt 0 ] && [ "$count" -gt "$max" ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
    return 0
  fi
  return 1
}

# rebase_should_exhaust <fail_count> <threshold>
#   Return 0 (true) when the number of recorded failures has reached the per-PR
#   exhaustion threshold. A threshold of 0 disables exhaustion (never true).
rebase_should_exhaust() {
  local fails="${1:-0}" threshold="${2:-0}"
  if [ "$threshold" -gt 0 ] && [ "$fails" -ge "$threshold" ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
    return 0
  fi
  return 1
}

# rebase_conflict_state <mergeable> <merge_state_status>
#   The authoritative post-condition decision for the rebase intent (#1890 AC #2).
#   The handler must NOT infer success from the engine exit code or a local
#   trial-merge — GitHub computes `mergeable` asynchronously and can disagree with
#   a locally-clean merge, which is how a run reported `status=applied` in seconds
#   while the PR stayed CONFLICTING. This pure helper maps the (mergeable,
#   mergeStateStatus) pair `gh pr view` returns into one of three verdicts:
#     conflicting   — mergeable == CONFLICTING OR mergeStateStatus == DIRTY.
#                     The rebase did NOT converge → the handler treats it as a
#                     failure (counts toward exhaustion), never as applied.
#     resolved      — mergeable == MERGEABLE (a positive no-conflict signal),
#                     and not otherwise conflicting. Safe to report applied.
#     indeterminate — anything else (mergeable UNKNOWN/empty and not DIRTY):
#                     GitHub has not finished computing mergeability. The handler
#                     must neither claim success nor record a failure; it re-checks
#                     later. Fail-safe default, so an unknown state is never read
#                     as "resolved".
rebase_conflict_state() {
  local mergeable="${1:-}" state="${2:-}"
  if [[ "$mergeable" = "CONFLICTING" ]] || [[ "$state" = "DIRTY" ]]; then
    printf 'conflicting'
    return 0
  fi
  if [[ "$mergeable" = "MERGEABLE" ]]; then
    printf 'resolved'
    return 0
  fi
  printf 'indeterminate'
}

# rebase_failure_reason <exit_code>
#   Human-readable reason for a rebase engine failure. Exit 124 is the GNU
#   `timeout` class (per-tier timeout) — the #865 defect — surfaced as its own
#   message so the terminal comment explains the abort rather than showing a bare
#   process-killed failure.
rebase_failure_reason() {
  case "${1:-1}" in
    124) printf 'Engine timed out resolving the rebase conflict (exit 124) — the conflict is likely unresolvable automatically.' ;;
    *)   printf 'Engine failed to resolve the rebase conflict (exit %s).' "${1:-1}" ;;
  esac
}
