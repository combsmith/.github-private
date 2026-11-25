# shellcheck shell=bash
# scripts/lib/persona-authz-preflight.sh — persona authorization-preflight
# DECISION layer (#1776, split from #1734 AC #5).
#
# The gap this closes: a persona's declared posting credential can AUTHENTICATE
# correctly and still lack authorization to WRITE. Every prior check verifies
# authentication and naming (resolve-persona-identity.sh, verify-persona-identity.sh,
# the runner's wrong-identity guard); none verified authorization. That let a
# valid-but-unauthorized token reach `gh api .../comments` and return 403 only
# AFTER the paid engine call — the advisory was produced and then discarded
# (#1734, run 34183239687), and a pr-review approval silently never landed on
# PR #1788 while the surrounding code treated it as success.
#
# These are PURE functions: given the already-gathered facts of a non-destructive
# capability probe (`GET /repos/{owner}/{repo}` reading `.permissions` for the
# authenticated identity), decide one of three outcomes. They NEVER touch the
# network or write content — the gh probe and the ::error::/::warning:: side
# effects are the wrapper's job (scripts/persona-authz-preflight.sh).
#
# The three states are deliberately distinct (AC #1, #4):
#   AUTHORIZED    — the permission surface is readable AND a write bit is set:
#                   proceed silently.
#   UNAUTHORIZED  — the permission surface is readable AND no write bit is set:
#                   a DEFINITE negative. Fail loudly; the diagnostic names the
#                   account, the credential secret, and the missing capability.
#   INDETERMINATE — the surface could not be read (5xx, rate limit, 401, network,
#                   or absent `.permissions`): WARN and proceed. Fail OPEN — a
#                   transient blip must never be reported as "cannot write" nor
#                   gate a legitimate advisory (AC #4). This is the delicate rule:
#                   a preflight that blocks advisories on a hiccup is worse than
#                   the bug it prevents.
#
# A missing/invalid secret is NOT this layer's concern: it is handled earlier
# (the wrapper skips the probe when no PAT is present; the post step already fails
# closed on it). This layer answers only "authenticated — can it write?".
#
# Detection scope — what the `.permissions` proxy can and cannot detect (AC #2):
#   CAN:    a credential whose account has NO repository write (push/maintain/admin
#           are all false on a readable surface) — the #1734 / PR #1788 class, where
#           write access to a private org repo is exactly what commenting requires.
#           This is the authenticated-but-unauthorized break the issue targets.
#   CANNOT: finer-grained gaps below the repo-write bit (e.g. a fine-grained PAT
#           granted "Issues: read" but not "Issues: write", or org/branch
#           restrictions) — those do not always surface in `.permissions`. Such a
#           result reads as INDETERMINATE (unknown/unreadable) and fails OPEN, never
#           as a false negative. The probe is deliberately conservative: it only
#           gates on an unambiguous "no write" and treats everything else as
#           proceed. It is a cheap, non-destructive early warning, not a proof of
#           comment-write; the post step's own failure handling (#1775) remains the
#           backstop for anything the proxy cannot see.

# authz_write_capability <admin> <maintain> <push> [triage]
#   Map the comment-implying booleans from a repo's `.permissions` object to a
#   capability signal. Each argument is the string GitHub returns ("true"/"false")
#   or empty when the object was absent/unreadable.
#     yes     — at least one of admin/maintain/push/triage is "true". triage is
#               included because the triage role grants issue/PR comment access —
#               exactly what posting the advisory needs — so a triage-only identity
#               must not be rejected as a false negative (it can produce and post
#               its advisory).
#     no      — the object was present (>=1 arg non-empty) and no such bit is set
#     unknown — every argument is empty (no `.permissions` object to read)
#   Only a literal "true" counts as a capability; any other value is not-write, so
#   a garbled field can never be mistaken for a grant.
authz_write_capability() {
  local admin="${1:-}" maintain="${2:-}" push="${3:-}" triage="${4:-}"
  if [[ "$admin" = "true" ]] || [[ "$maintain" = "true" ]] || [[ "$push" = "true" ]] || [[ "$triage" = "true" ]]; then
    echo "yes"
  elif [[ -n "$admin" ]] || [[ -n "$maintain" ]] || [[ -n "$push" ]] || [[ -n "$triage" ]]; then
    echo "no"
  else
    echo "unknown"
  fi
}

# authz_preflight_decision <probe_ok> <capability>
#   The three-state classifier. <probe_ok> is "yes" only when the
#   `GET /repos/{owner}/{repo}` read itself succeeded; anything else (a 4xx/5xx,
#   rate limit, network error, empty) means the surface was NOT readable.
#   <capability> is the authz_write_capability output.
#     probe_ok != "yes"        -> INDETERMINATE  (unreadable surface; fail open)
#     capability == "yes"      -> AUTHORIZED
#     capability == "no"       -> UNAUTHORIZED    (the definite negative)
#     capability == "unknown"  -> INDETERMINATE  (readable but no perms; fail open)
#   Crucially, an unreadable surface is INDETERMINATE even if a stale capability
#   argument says "no" — a read failure is never a definite negative (AC #4).
authz_preflight_decision() {
  local probe_ok="${1:-}" capability="${2:-}"
  if [[ "$probe_ok" != "yes" ]]; then
    echo "INDETERMINATE"
    return 0
  fi
  case "$capability" in
    yes) echo "AUTHORIZED" ;;
    no)  echo "UNAUTHORIZED" ;;
    *)   echo "INDETERMINATE" ;;
  esac
}

# authz_preflight_should_fail <decision>
#   Exit 0 (the preflight SHOULD fail the run) ONLY for a definite negative.
#   AUTHORIZED and INDETERMINATE both proceed — the fail-open contract (AC #4).
authz_preflight_should_fail() {
  [[ "${1:-}" = "UNAUTHORIZED" ]]
}

# authz_preflight_diagnostic <decision> <account> <credential> <repo>
#   Build the human-readable line for a decision. The UNAUTHORIZED message is the
#   load-bearing one: it names the account, the credential SECRET, and the missing
#   capability (repository write), and states explicitly that the token
#   authenticated — so this is authorization, not a missing secret. A diagnostic
#   that said only "permission denied" is exactly what made #1734 take a human to
#   diagnose (AC #1). The wrapper prepends ::error:: / ::warning:: / notice.
authz_preflight_diagnostic() {
  local decision="${1:-}" account="${2:-}" credential="${3:-}" repo="${4:-}"
  case "$decision" in
    AUTHORIZED)
      printf "authorization preflight: '%s' (credential %s) can write to %s — proceeding" \
        "$account" "$credential" "$repo"
      ;;
    UNAUTHORIZED)
      printf "authorization preflight FAILED: '%s' (credential %s) authenticated but CANNOT write to %s. Missing capability: repository write (push/maintain/admin) — needed to post the advisory comment. This is an authorization failure, not a missing or expired secret: the token is valid but the account lacks write permission, so the advisory would be produced at cost and then discarded (the #1734 / PR #1788 failure class). Grant %s write access to %s or fix the credential mapping." \
        "$account" "$credential" "$repo" "$account" "$repo"
      ;;
    INDETERMINATE)
      printf "authorization preflight indeterminate for '%s' (credential %s) on %s: the permission surface could not be read (transient API error, rate limit, or absent permissions). Failing OPEN — proceeding without gating the advisory (a blip must not block a legitimate advisory)" \
        "$account" "$credential" "$repo"
      ;;
    *)
      printf "authorization preflight: unknown decision '%s' for '%s' (credential %s) on %s" \
        "$decision" "$account" "$credential" "$repo"
      ;;
  esac
}
