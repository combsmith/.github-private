#!/usr/bin/env bash
set -euo pipefail
# verify-persona-teams.sh — LIVE persona addressing-team check (#1280).
#
# The persona standard (§4.1) requires a persona's `address.handle` to name an org
# TEAM with specific LIVE properties. The hermetic personas/validate-personas.py
# checks the handle SHAPE (team slug == id) but deliberately cannot reach the
# network. This script is the separate, network-touching half: for every
# personas/<id>/persona.yml that declares an `address` block, it verifies the live
# team named by `address.handle`:
#
#   1. the team EXISTS,
#   2. privacy == "closed"                         (secret teams are unmentionable),
#   3. notification_setting == "notifications_disabled" (routes a webhook, not a page).
#
# The slug==id invariant is already enforced hermetically by validate-personas.py
# and is NOT re-checked here — this check is about LIVE state only. A persona with
# no `address` block passes (address is optional unless the `mention` surface is on).
#
# FAIL CLOSED: any API/parse error is a failure, never a pass. Conflating "could
# not read the team" with "the team is fine" is the exact systemic bug this check
# exists to prevent (petry-projects/.github#755, finding 3). If the team cannot be
# read, the check fails.
#
# Requires: gh (authenticated with an ORG-scoped token — github.token cannot read
# teams; GH_PAT_WORKFLOWS is available in CI), jq, and python3 + PyYAML. Diagnostics
# use the `::error::persona manifest invalid: ...` style of validate-personas.py.
#
# Usage: verify-persona-teams.sh [personas_root]   (default: personas)
#   VPT_ORG — org whose teams are read (default: petry-projects)

export VPT_ORG="${VPT_ORG:-petry-projects}"

vpt_fail() {
  echo "::error::persona manifest invalid: $*" >&2
  return 1
}

# vpt_list_addresses <root> — print a "<slug>\t<manifest>" line for every
# personas/<id>/persona.yml under <root> that declares an address.handle. Personas
# with no `address` block are omitted (they pass). A malformed handle (not an
# 'org/team-slug' string) is a hard error — printed as a `::error::` diagnostic and
# a non-zero exit, never a traceback.
vpt_list_addresses() {
  local root="$1"
  python3 - "$root" <<'PY'
import glob
import os
import sys

try:
    import yaml
except ImportError:
    print("::error::persona manifest invalid: PyYAML not installed (pip install pyyaml)",
          file=sys.stderr)
    sys.exit(1)

vpt_org = os.environ.get("VPT_ORG", "petry-projects")
root = sys.argv[1]
for manifest in sorted(glob.glob(os.path.join(root, "*", "persona.yml"))):
    try:
        with open(manifest, encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
    except (OSError, yaml.YAMLError) as exc:
        print(f"::error::persona manifest invalid: could not read/parse {manifest}: {exc}",
              file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        continue
    address = data.get("address")
    if address is None:
        continue
    if not isinstance(address, dict):
        print(f"::error::persona manifest invalid: {manifest}: address must be a mapping, "
              f"got {address!r}", file=sys.stderr)
        sys.exit(1)
    handle = address.get("handle")
    if not isinstance(handle, str) or "/" not in handle:
        print(f"::error::persona manifest invalid: {manifest}: address.handle must be an "
              f"'org/team-slug' string (e.g. 'petry-projects/qa-lead'), got {handle!r}",
              file=sys.stderr)
        sys.exit(1)
    org, slug = handle.split("/", 1)
    if org != vpt_org:
        print(f"::error::persona manifest invalid: {manifest}: address.handle org '{org}' "
              f"does not match expected org '{vpt_org}' — cross-org handles cannot be verified",
              file=sys.stderr)
        sys.exit(1)
    print(f"{slug}\t{manifest}")
PY
}

# vpt_have_credential — return 0 if gh has a usable GitHub credential to even
# attempt the live teams API, non-zero otherwise. Isolated so the hermetic tests
# can stub it. On Dependabot / fork PRs the org-scoped secret (GH_PAT_WORKFLOWS) is
# withheld, so GH_TOKEN is empty and gh is unauthenticated: the live check cannot
# run and must be SKIPPED (not failed) — see vpt_run. This is distinct from an API
# error while authenticated, which still fails closed.
vpt_have_credential() {
  gh auth status >/dev/null 2>&1
}

# vpt_team_api <slug> — echo the JSON for org team <slug>, or return non-zero on
# any API error (a nonexistent team returns HTTP 404, which is such an error).
# Isolated so the hermetic test suite can stub `gh`.
vpt_team_api() {
  local slug="$1"
  gh api "orgs/${VPT_ORG}/teams/${slug}"
}

# vpt_check_team <manifest> <slug> — fetch and verify the live team. Fails closed:
# a read/parse error, a secret team, or an enabled notification setting all fail.
vpt_check_team() {
  local manifest="$1" slug="$2" json privacy notif
  if ! json="$(vpt_team_api "$slug")"; then
    vpt_fail "$manifest: could not read team '${VPT_ORG}/${slug}' from the org teams API — failing closed (an API error is never treated as a valid team). The team may not exist, or the token may not be org-scoped (use GH_PAT_WORKFLOWS)." || return 1
  fi
  if ! privacy="$(jq -er '.privacy?' <<< "$json")"; then
    vpt_fail "$manifest: team '${VPT_ORG}/${slug}' API response has no 'privacy' field (or is not JSON) — failing closed." || return 1
  fi
  if ! notif="$(jq -er '.notification_setting?' <<< "$json")"; then
    vpt_fail "$manifest: team '${VPT_ORG}/${slug}' API response has no 'notification_setting' field (or is not JSON) — failing closed." || return 1
  fi
  if [ "$privacy" != "closed" ]; then
    vpt_fail "$manifest: team '${VPT_ORG}/${slug}' has privacy '${privacy}', expected 'closed' — a secret team is unmentionable, so every mention silently no-ops." || return 1
  fi
  if [ "$notif" != "notifications_disabled" ]; then
    vpt_fail "$manifest: team '${VPT_ORG}/${slug}' has notification_setting '${notif}', expected 'notifications_disabled' — the handle routes a webhook, it must not page the team's members." || return 1
  fi
  echo "verify-persona-teams: OK — ${manifest} → ${VPT_ORG}/${slug} (exists, closed, notifications disabled)."
}

vpt_run() {
  local root="${1:-personas}"
  command -v gh  >/dev/null 2>&1 || vpt_fail "gh is required but not installed"
  command -v jq  >/dev/null 2>&1 || vpt_fail "jq is required but not installed"
  command -v python3 >/dev/null 2>&1 || vpt_fail "python3 is required but not installed"

  if [ ! -d "$root" ]; then
    echo "verify-persona-teams: no personas root at '${root}' — nothing to verify."
    return 0
  fi

  local lines
  if ! lines="$(vpt_list_addresses "$root")"; then
    # vpt_list_addresses already printed a ::error:: diagnostic; fail closed.
    return 1
  fi

  if [ -z "$lines" ]; then
    echo "verify-persona-teams: no personas declare an address block — nothing to verify."
    return 0
  fi

  # Preflight: the LIVE team check needs a GitHub credential. On Dependabot / fork
  # PRs the org-scoped secret is withheld (GH_TOKEN empty), so gh is unauthenticated
  # and this check cannot run. Skip with a visible ::warning:: rather than failing —
  # the token-degradation posture used across this repo (e.g. fleet_monitor.sh) —
  # so those PRs stop reddening Lint (#1323). This is NOT a pass for a broken team:
  # the check simply did not run, and it runs in full (fail-closed) on every
  # credential-bearing PR and post-merge.
  if ! vpt_have_credential; then
    local msg
    msg="verify-persona-teams: no usable GitHub credential (gh is not authenticated) — "
    msg+="skipping the LIVE persona team check. Dependabot/fork PRs withhold the org-scoped "
    msg+="token, so this check cannot run there; it runs in full on every credential-bearing "
    msg+="PR and post-merge. Skipping is not a pass for a broken team."
    echo "::warning::${msg}" >&2
    return 0
  fi

  local count=0 slug manifest
  while IFS=$'\t' read -r slug manifest; do
    [ -n "$slug" ] || continue
    vpt_check_team "$manifest" "$slug" || return 1
    count=$((count + 1))
  done <<< "$lines"

  echo "verify-persona-teams: OK — ${count} persona team(s) verified live."
}

# Only run main when executed directly, so the hermetic tests can source the
# functions and stub `gh`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  vpt_run "$@"
fi
