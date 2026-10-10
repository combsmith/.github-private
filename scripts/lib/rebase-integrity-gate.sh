# shellcheck shell=bash
# scripts/lib/rebase-integrity-gate.sh — the duplicate-declaration leg of the
# post-rebase integrity gate (#1890 AC #7), with a diagnosable outcome (#2184).
#
# The gate used to run check-duplicate-decls.sh with its output discarded, so a
# failure could not be told apart from a finding. On PR 2180 a clean resolution
# was escalated to a human as "possible #1485 corruption" and nobody could see
# why. This helper keeps the gate's own words and separates three outcomes.
#
# Sourced by scripts/dev-lead-fix-reviews.sh. Defines functions only; runs
# nothing at source time and does not call `set`.

# Bounds on the excerpt of the gate's output that is logged and handed to the
# caller's escalation comment.
RIG_DETAIL_MAX_LINES="${RIG_DETAIL_MAX_LINES:-15}"
RIG_DETAIL_MAX_BYTES="${RIG_DETAIL_MAX_BYTES:-1500}"

# The excerpt from the last rig_duplicate_decl_gate call ("" when it was clean).
RIG_DETAIL=""

# _rig_excerpt — stdin → stdout. Redacts FIRST (cutting first could split a
# token below its redaction pattern), then bounds the result.
_rig_excerpt() {
  local text
  text="$(cat)"
  if declare -F redact_secrets >/dev/null 2>&1; then
    text="$(printf '%s\n' "$text" | redact_secrets)"
  fi
  printf '%s\n' "$text" | head -n "$RIG_DETAIL_MAX_LINES" | head -c "$RIG_DETAIL_MAX_BYTES"
}

# rig_duplicate_decl_gate <gate_script> <work_root>
#   Runs <gate_script> (check-duplicate-decls.sh from the agent's own scripts)
#   against the resolved tree at <work_root>: its scripts/, prompts/ and
#   personas/. Returns:
#     0  clean — or the gate script is missing / not executable, which is noted
#        and skipped as before (not a finding)
#     1  the gate found duplicate declarations (possible #1485 corruption)
#     2  the gate could not be evaluated (it exited with any other status)
#   On 1 and 2 it prints one ::warning:: naming the outcome, then the excerpt,
#   and leaves the excerpt in RIG_DETAIL. A "could not be evaluated" outcome is
#   never worded as corruption.
rig_duplicate_decl_gate() {
  local gate="${1:-}" work_root="${2:-}" out="" rc=0
  RIG_DETAIL=""
  if [ ! -x "$gate" ]; then
    echo "::notice::integrity gate: the duplicate-declaration check could not be evaluated — ${gate} is missing or not executable; skipped (#2184)"
    return 0
  fi
  out="$(DUPLICATE_DECL_PROMPTS_DIR="${work_root}/prompts" \
         DUPLICATE_DECL_PERSONAS_DIR="${work_root}/personas" \
         "$gate" "${work_root}/scripts" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && return 0

  RIG_DETAIL="$(printf '%s\n' "$out" | _rig_excerpt)"
  if [ "$rc" -eq 1 ]; then
    echo "::warning::integrity gate: check-duplicate-decls.sh found duplicate declarations after rebase resolution — possible #1485 corruption (#1890 AC #7)"
  else
    echo "::warning::integrity gate: check-duplicate-decls.sh could not be evaluated after rebase resolution (exit ${rc}) — this is not a corruption finding (#2184)"
    rc=2
  fi
  # Indented so the gate's own ::error:: lines read as detail, not as new annotations.
  printf '%s\n' "$RIG_DETAIL" | sed 's/^/  integrity gate> /'
  return "$rc"
}
