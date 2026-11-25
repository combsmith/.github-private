#!/usr/bin/env bash
# holdout-guard.sh — held-out eval immutability guard (#692, epic #581).
#
# This is the *hard* CI enforcement that backs the advisory CODEOWNERS rule over
# evals/. CODEOWNERS only routes review (and only blocks merges when branch
# protection's "require review from code owners" is enabled — an unstated
# dependency). This guard is the immutability guarantee: it fails any PR whose
# author is the automated skill-proposer identity when that PR changes a
# held-out path, keyed purely on PR author + changed paths.
#
# It complements, does not replace, CODEOWNERS:
#   - CODEOWNERS routes review.
#   - this guard is the immutability guarantee — independent of whether
#     CODEOWNER review is enforced.
#
# Decision (hg_evaluate):
#   author NOT a proposer identity           -> PASS (humans/CODEOWNERS edit evals/)
#   author IS a proposer + no guarded path   -> PASS (e.g. prompts/triage.md)
#   author IS a proposer + a guarded path    -> FAIL (the held-out guarantee)
#
# Proposer identity (HOLDOUT_PROPOSER_IDENTITIES, default "github-actions[bot]"):
#   The proposer runs as GITHUB_TOKEN (see evals/README.md), whose PR author
#   login is github-actions[bot]. This is intentionally DISTINCT from the
#   dev-lead bot (donpetry-bot), which authors the eval *stories* (like #692
#   itself) and must keep passing. Override via repo variable when the Phase-3
#   proposer (#587) lands with its own bot account.
#
# Guarded prefixes (HOLDOUT_GUARDED_PREFIXES, default "evals/"):
#   Path prefixes (each should end with "/") that are held-out. The holdout
#   split lives under evals/<skill>/holdout/, so the evals/ prefix already
#   covers it; add a second prefix here if a holdout is ever separately rooted.

# hg_proposer_identities — emit the configured proposer logins, one per line.
# Accepts comma- and/or whitespace-separated values in the env var.
hg_proposer_identities() {
  local raw="${HOLDOUT_PROPOSER_IDENTITIES:-github-actions[bot]}" item
  # Replace commas with spaces (word splitting handles multiple whitespace)
  for item in ${raw//,/ }; do
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

# hg_guarded_prefixes — emit the configured guarded path prefixes, one per line.
hg_guarded_prefixes() {
  local raw="${HOLDOUT_GUARDED_PREFIXES:-evals/}" item
  # Replace commas with spaces (word splitting handles multiple whitespace)
  for item in ${raw//,/ }; do
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

# hg_is_proposer <login> — return 0 if the login is a configured proposer.
hg_is_proposer() {
  local login="${1:-}" want identity
  login="${login,,}"
  [[ -n "$login" ]] || return 1
  while IFS= read -r identity || [[ -n "$identity" ]]; do
    [[ -n "$identity" ]] || continue
    want="${identity,,}"
    [[ "$login" = "$want" ]] && return 0
  done < <(hg_proposer_identities)
  return 1
}

# hg_path_is_guarded <path> — return 0 if the path sits under a guarded prefix.
hg_path_is_guarded() {
  local path="${1:-}" prefix
  [[ -n "$path" ]] || return 1
  while IFS= read -r prefix || [[ -n "$prefix" ]]; do
    [[ -n "$prefix" ]] || continue
    case "$path" in
      "$prefix"*) return 0 ;;
    esac
  done < <(hg_guarded_prefixes)
  return 1
}

# hg_evaluate <author> — read newline-delimited changed paths on stdin and
# decide pass/fail. Prints a human-readable verdict. Exit 0 = pass, 1 = fail,
# 2 = usage error (missing author).
hg_evaluate() {
  local author="${1:-}"
  if [[ -z "$author" ]]; then
    echo "[holdout-guard] ERROR: no PR author supplied" >&2
    return 2
  fi

  if ! hg_is_proposer "$author"; then
    echo "[holdout-guard] author '$author' is not a proposer identity — pass"
    # Drain stdin so callers piping into us don't see a broken pipe.
    cat >/dev/null 2>&1 || true
    return 0
  fi

  local path offending=()
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    if hg_path_is_guarded "$path"; then
      offending+=("$path")
    fi
  done

  if [[ "${#offending[@]}" -gt 0 ]]; then
    echo "[holdout-guard] FAIL: proposer '$author' changed held-out path(s):"
    local p
    for p in "${offending[@]}"; do
      echo "  - $p"
    done
    echo "[holdout-guard] The proposer must never edit its own held-out eval set." >&2
    echo "[holdout-guard] This is the hard guarantee behind the CODEOWNERS rule over evals/." >&2
    return 1
  fi

  echo "[holdout-guard] proposer '$author' changed no held-out paths — pass"
  return 0
}
