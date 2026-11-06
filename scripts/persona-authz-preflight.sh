#!/usr/bin/env bash
# persona-authz-preflight.sh — non-destructive authorization preflight for the
# persona runner (#1776, split from #1734 AC #5).
#
# Runs in persona-runner-reusable.yml AFTER the posting identity is resolved and
# BEFORE the paid engine call, so an authenticated-but-unauthorized credential is
# caught before the model is invoked and the advisory is produced and lost — the
# strongest position (AC #3, option a). CI-only placement cannot catch runtime
# revocation and, lacking the cross-repo posting PATs, cannot run a live probe at
# all, so the runtime preflight is required regardless.
#
# The probe is NON-DESTRUCTIVE (AC #2): it never creates, edits, or deletes real
# content. It issues a single capability query — `GET /repos/{owner}/{repo}` — and
# reads `.permissions` (admin/maintain/push) for the authenticated posting
# identity. No throwaway comment/issue/branch is written anywhere.
#
# The DECISION is pure and unit-tested in scripts/lib/persona-authz-preflight.sh.
# This wrapper is the network + side-effect layer: gather the probe facts, map
# them to a decision, and act — fail CLOSED (exit 1, ::error::) only on a definite
# negative; fail OPEN (exit 0, ::warning::) on any indeterminate result (AC #4).
#
# Env vars consumed:
#   GH_TOKEN           — the posting PAT already selected from the manifest
#                        credential by the calling step (never a repo-wide
#                        default). EMPTY means the missing/invalid-secret case,
#                        which is handled earlier — the preflight skips (see below).
#   SOURCE_REPO        — owner/repo of the item the advisory would be posted to
#   POSTING_ACCOUNT    — the login GH_TOKEN authenticates as (from the manifest)
#   POSTING_CREDENTIAL — the secret name holding that PAT (from the manifest)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/persona-authz-preflight.sh
source "${SCRIPT_DIR}/lib/persona-authz-preflight.sh"

SOURCE_REPO="${SOURCE_REPO:-}"
POSTING_ACCOUNT="${POSTING_ACCOUNT:-<unknown>}"
POSTING_CREDENTIAL="${POSTING_CREDENTIAL:-<unknown>}"

# Missing/invalid secret is NOT this preflight's job (AC #1) — it is handled
# earlier: the post step fails closed on an unset PAT and on a wrong identity.
# Running the probe with no token would only produce a 401 we would (correctly)
# treat as indeterminate, so skip cleanly and let the existing path own it.
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "::notice::authz-preflight: no PAT for credential '${POSTING_CREDENTIAL}' — deferring to the existing missing-secret handling (not this preflight's concern)"
  exit 0
fi

if [[ -z "$SOURCE_REPO" ]]; then
  echo "::notice::authz-preflight: no source repo to probe — skipping"
  exit 0
fi

# --- Non-destructive capability probe --------------------------------------
# A single read of the repo's permission surface for the authenticated identity.
errfile="$(mktemp)" || { echo "::error::authz-preflight: failed to create temporary file" >&2; exit 1; }
trap 'rm -f "$errfile"' EXIT
probe_ok="yes"
resp=""
if ! resp="$(gh api "repos/${SOURCE_REPO}" 2>"$errfile")"; then
  probe_ok="no"   # 4xx/5xx/rate-limit/network — an unreadable surface (fail open)
fi

admin="" ; maintain="" ; push="" ; triage=""
if [[ "$probe_ok" = "yes" ]]; then
  # `.permissions` may be absent for some token/endpoint combinations; default it
  # to {} so a missing object yields empty fields (capability "unknown"), never a
  # jq error. A jq failure (malformed JSON) also degrades to an unreadable surface.
  if perms_tsv="$(printf '%s' "$resp" | jq -r '
        (.permissions // {}) as $p
        | [$p.admin, $p.maintain, $p.push, $p.triage]
        | map(if . == null then "" else tostring end)
        | @tsv' 2>/dev/null)"; then
    IFS=$'\t' read -r admin maintain push triage <<< "$perms_tsv"
  else
    probe_ok="no"
  fi
fi

capability="$(authz_write_capability "$admin" "$maintain" "$push" "$triage")"
decision="$(authz_preflight_decision "$probe_ok" "$capability")"
diag="$(authz_preflight_diagnostic "$decision" "$POSTING_ACCOUNT" "$POSTING_CREDENTIAL" "$SOURCE_REPO")"

case "$decision" in
  AUTHORIZED)
    echo "::notice::${diag}"
    ;;
  INDETERMINATE)
    # Fail OPEN (AC #4): a transient/unreadable result must not gate the advisory.
    if [[ "$probe_ok" != "yes" ]]; then
      echo "::warning::authz-preflight: permission surface for ${SOURCE_REPO} was unreadable: $(tr '\n' ' ' < "$errfile")"
    fi
    echo "::warning::${diag}"
    ;;
  *)
    # UNAUTHORIZED — the definite negative. Fail CLOSED, loudly (AC #1).
    echo "::error::${diag}"
    ;;
esac

if authz_preflight_should_fail "$decision"; then
  exit 1
fi
exit 0
