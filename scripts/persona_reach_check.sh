#!/usr/bin/env bash
set -euo pipefail
# persona_reach_check.sh — consumer-reached / no-new-trigger-surface verification
# for a mention-routed persona (#1631, epic #1627).
#
# Usage:
#   persona_reach_check.sh <role> [--registry FILE] [--personas-dir DIR] [--router FILE]
#
# Why this exists
# ---------------
# A ring label moving is NOT evidence that a promotion reached a consumer
# (Discussion #1360 learning 12; the #1592 propagation hazard). solution-architect
# carries no dedicated reusable blob — its advisory logic is a prompt file served by
# the SHARED persona-mention router (.github/workflows/persona-mention.yml), whose
# channel the router already owns and cuts. Autocut only cuts a new channel version
# when a REUSABLE's blob changes, so a status/ring move on a prompt-only persona can
# advance the scoreboard yet propagate to nobody. Promotion therefore has to be
# verified two ways this guard encodes, hermetically and re-runnably:
#
#   1. NO NEW TRIGGER SURFACE (AC #5). The persona's DEPLOYED interaction events must
#      stay a subset of the shared mention router's events — promotion must not add a
#      pull_request:synchronize, a cron, or any fan-out that would turn an advisor
#      into a queue (§7 of the story body, learning 11).
#   2. ROUTES-TO != PROMOTED (AC #4). The verdict separates "a mention would route to
#      this persona" (wiring) from "this persona is actually promoted" (status past
#      draft, with NO cross-repo canary-rings entry — see ADR-0006). The dangerous
#      state is now the INVERSE: a canary-rings entry for a persona that has no
#      dedicated reusable, which produces unconsumed tags and an unattributable
#      gate. That, or a widened trigger surface, is what this guard fails on.
#
# The truly-live confirmation (dispatch a real @petry-projects/solution-architect
# mention and confirm the resulting persona-runner run resolves to this persona,
# mirroring qa-lead's #1300 mention smoke test) is an operational step run against a
# real consumer; this guard is the hermetic, offline core that gates the wiring and
# catches the skew at PR time.
#
# Following ADR-0004 (pure-logic + bats), the predicates below are pure and
# unit-tested BEFORE the guard is relied on (tests/persona_reach_check.bats); main()
# confines all I/O (reading manifests, the router, an optional registry, printing).
#
# Exit codes:
#   0  safe state — either an honest still-draft persona, or a promoted persona
#      (past draft, UNREGISTERED per ADR-0006) whose surface stayed mention-only.
#   2  DEFECT / new surface — a canary-rings entry exists for this shared-runtime
#      persona at any status (ADR-0006 forbids it), or promotion added a trigger
#      surface beyond the shared mention router.
#   3  hard error — bad usage / missing inputs.

# The shared persona-mention router's MENTION events (persona-standards §4.1) — the
# set a mention-only persona may be served on. Anything a persona subscribes beyond
# this set is a NEW trigger surface introduced during promotion.
#
# This is deliberately NOT the router's whole `on:` block. Since #2187 the router
# (.github/workflows/persona-mention.yml) also subscribes `pull_request`, but that
# is an EVENT surface a persona must opt into by declaring a `pull_request` surface
# in its manifest — not a mention event. Deriving this set from `on:` would let a
# mention-only persona widen onto pull_request unnoticed, which is exactly the fan-out
# this guard exists to catch, so `pull_request` stays out of it.
# (prc_router_serves_events still reads the real `on:` block for wiring.)
PRC_ROUTER_EVENTS="issue_comment pull_request_review_comment discussion_comment"

PRC_RING_ORDER="draft canary next ring0 ring1 stable retired"

# ── Pure logic (unit-tested in tests/persona_reach_check.bats) ─────────────────

# prc_surface_is_mention_only <events_csv>
# Return 0 iff <events_csv> is a NON-EMPTY comma-separated list every member of which
# is one of the shared mention router's events. An empty surface (nothing routes) or
# any event outside the router's set (a new trigger surface) returns non-zero and
# names the offending event on stdout. Surrounding whitespace is ignored.
prc_surface_is_mention_only() {
  local csv="${1:-}" ev seen=0
  local -a events
  IFS=',' read -r -a events <<< "$csv"
  for ev in "${events[@]}"; do
    ev="${ev#"${ev%%[![:space:]]*}"}"   # ltrim
    ev="${ev%"${ev##*[![:space:]]}"}"   # rtrim
    [ -n "$ev" ] || continue
    seen=1
    case " $PRC_ROUTER_EVENTS " in
      *" $ev "*) : ;;
      *) echo "new trigger surface not served by the shared mention router: $ev"; return 1 ;;
    esac
  done
  [ "$seen" -eq 1 ] || { echo "empty trigger surface: nothing routes to this persona"; return 1; }
  return 0
}

# prc_is_past_draft <status>
# Return 0 iff <status> is a ring strictly after 'draft' (the ring label has moved).
prc_is_past_draft() {
  # 'retired' is after draft too; a retired persona is intentionally treated as
  # "past draft" — it must have been registered to have ever shipped.
  local status="${1:-}" r i=0 draft_i=-1 status_i=-1
  for r in $PRC_RING_ORDER; do
    [ "$r" = "draft" ] && draft_i=$i
    [ "$r" = "$status" ] && status_i=$i
    i=$((i + 1))
  done
  [ "$status_i" -ge 0 ] || return 1
  if [ "$status_i" -gt "$draft_i" ]; then
    return 0
  fi
  return 1
}

# prc_promotion_verdict <status> <registered>
# The routes-to != promoted predicate (learning 12), INVERTED per ADR-0006
# (docs/architecture/adr/0006-shared-runtime-personas-are-not-ring-registered.md).
#
# This persona rides the SHARED persona runtime: persona-runner.yml consumes the
# reusable by local relative path with no agent_ref, so NO caller pins a
# per-persona channel tag. There is nothing for a ring promotion to advance, and
# ADR-0006 therefore forbids a per-persona canary-rings entry outright — "a
# registered persona ID is a defect, not a promotion."
#
# So the state this guard used to fail on is now the NORMAL one, and the state it
# used to treat as safe is now the defect:
#   draft      — status is draft and unregistered: not promoted (safe, 0)
#   promoted   — status past draft and NOT registered: the ADR-0006 shape (safe, 0)
#   registered — registered at ANY status: forbidden for a shared-runtime persona,
#                the inverted skew (2). Checked before the draft branch, because a
#                draft persona carrying a registry entry is equally a defect.
#
# Promotion evidence is this check plus an observed live mention — never a ring
# label. That was already true; ADR-0006 removes the label that was never evidence.
prc_promotion_verdict() {
  local status="${1:-}" registered="${2:-false}"
  if [ "$registered" = "true" ]; then
    echo "registered"
    return 2
  fi
  if ! prc_is_past_draft "$status"; then
    echo "draft"
    return 0
  fi
  echo "promoted"
  return 0
}

# ── I/O orchestration ─────────────────────────────────────────────────────────

prc_die() { echo "::error::persona reach check: $1"; exit 3; }

# prc_manifest_status <persona.yml> — the manifest's top-level `status:` scalar,
# normalized: inline `# comment` stripped, surrounding quotes removed, trimmed. The
# caller (main) rejects any value not in PRC_RING_ORDER, so a malformed scalar such
# as `status: next # promoted` can no longer masquerade as an unknown ring and skip
# the registration gate.
prc_manifest_status() {
  local f="${1:-}" line status
  [ -f "$f" ] || prc_die "manifest not found: $f"
  line="$(grep -m1 '^status:' "$f" || true)"
  status="${line#status:}"
  status="${status%%#*}"                          # strip inline comment
  status="${status#"${status%%[![:space:]]*}"}"   # ltrim
  status="${status%"${status##*[![:space:]]}"}"   # rtrim
  status="${status%\"}"; status="${status#\"}"     # strip surrounding double quotes
  status="${status%\'}"; status="${status#\'}"     # strip surrounding single quotes
  printf '%s\n' "$status"
}

# prc_deployed_events <interaction.yml> — the DEPLOYED interaction.triggers.events as
# a comma-separated list. Reads only the `events:` list items under `triggers:`,
# which the contract keeps in sync with the router's `on:` block.
prc_deployed_events() {
  local f="${1:-}"
  [ -f "$f" ] || prc_die "interaction contract not found: $f"
  awk '
    /^[[:space:]]*triggers:[[:space:]]*$/ {intrig=1; next}
    # Inline flow-style list: events: [issue_comment, discussion_comment]
    intrig && /^[[:space:]]*events:[[:space:]]*\[.*\][[:space:]]*$/ {
      line=$0
      sub(/^[[:space:]]*events:[[:space:]]*\[/,"",line)
      sub(/\][[:space:]]*$/,"",line)
      n=split(line, arr, ",")
      for (i=1;i<=n;i++) { item=arr[i]; gsub(/[^A-Za-z0-9_]/,"",item); if (item != "") print item }
      next
    }
    # Block-style list under `events:`
    intrig && /^[[:space:]]*events:[[:space:]]*$/ {inev=1; next}
    inev {
      if ($0 ~ /^[[:space:]]*-[[:space:]]*/) { line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line); sub(/[[:space:]]*(#.*)?$/,"",line); print line; next }
      if ($0 ~ /[^[:space:]]/) { inev=0; intrig=0 }
    }
  ' "$f" | paste -sd, -
}

# prc_router_serves_events <router.yml> <events_csv> — return 0 iff every deployed
# event is present in the shared router workflow's `on:` block (the consumer path is
# actually wired, not just declared in the contract).
prc_router_serves_events() {
  local router="${1:-}" csv="${2:-}" ev
  [ -f "$router" ] || prc_die "router workflow not found: $router"
  local -a events
  IFS=',' read -r -a events <<< "$csv"
  for ev in "${events[@]}"; do
    ev="${ev#"${ev%%[![:space:]]*}"}"; ev="${ev%"${ev##*[![:space:]]}"}"
    [ -n "$ev" ] || continue
    grep -Eq "^[[:space:]]+${ev}:" "$router" || { echo "router does not subscribe event: $ev"; return 1; }
  done
  return 0
}

# prc_registry_has_agent <registry.json> <role> — return 0 iff the local registry
# file registers agents.<role>. Absent file / flag ⇒ non-zero (registration
# UNVERIFIED, hermetically treated as not-registered).
prc_registry_has_agent() {
  local reg="${1:-}" role="${2:-}"
  [ -n "$reg" ] && [ -f "$reg" ] || return 1
  command -v jq >/dev/null 2>&1 || prc_die "jq is required to read a registry"
  jq -e --arg a "$role" '.agents[$a] != null' "$reg" >/dev/null 2>&1
}

main() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "$script_dir/.." && pwd)"

  local role="" registry="" personas_dir="$repo_root/personas" router="$repo_root/.github/workflows/persona-mention.yml"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --registry)     [ "$#" -ge 2 ] || prc_die "--registry needs a file";      registry="$2"; shift 2 ;;
      --personas-dir) [ "$#" -ge 2 ] || prc_die "--personas-dir needs a dir";   personas_dir="$2"; shift 2 ;;
      --router)       [ "$#" -ge 2 ] || prc_die "--router needs a file";        router="$2"; shift 2 ;;
      -h|--help)      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      -*) prc_die "unknown option: $1" ;;
      *)  if [ -z "$role" ]; then role="$1"; else prc_die "unexpected argument: $1"; fi; shift ;;
    esac
  done
  [ -n "$role" ] || prc_die "usage: persona_reach_check.sh <role> [--registry FILE]"
  command -v jq >/dev/null 2>&1 || prc_die "jq is required to run this check"

  local manifest="$personas_dir/$role/persona.yml"
  local contract="$personas_dir/$role/interaction.yml"

  local status events registered="false" routes_via_router="false" surface_ok="true" surface_msg=""
  status="$(prc_manifest_status "$manifest")"
  [ -n "$status" ] || prc_die "could not read status from $manifest"
  case " $PRC_RING_ORDER " in
    *" $status "*) : ;;
    *) prc_die "unknown status '$status' in $manifest (must be one of: $PRC_RING_ORDER)" ;;
  esac
  events="$(prc_deployed_events "$contract")"

  if surface_msg="$(prc_surface_is_mention_only "$events")"; then
    surface_ok="true"
  else
    surface_ok="false"
  fi

  if prc_router_serves_events "$router" "$events" >/dev/null; then
    routes_via_router="true"
  fi

  if prc_registry_has_agent "$registry" "$role"; then
    registered="true"
  fi

  local verdict prom_rc=0
  verdict="$(prc_promotion_verdict "$status" "$registered")" || prom_rc=$?

  jq -cn \
    --arg role "$role" \
    --arg status "$status" \
    --arg events "$events" \
    --argjson surface_mention_only "$surface_ok" \
    --argjson routes_via_router "$routes_via_router" \
    --argjson registered "$registered" \
    --arg verdict "$verdict" \
    '{role:$role, status:$status, events:$events, surface_mention_only:$surface_mention_only, routes_via_router:$routes_via_router, registered:$registered, verdict:$verdict}'

  if [ "$surface_ok" != "true" ]; then
    echo "::error::persona reach check: $role added a trigger surface beyond the shared mention router ($surface_msg)" >&2
    return 2
  fi
  if [ "$prom_rc" -ne 0 ]; then
    echo "::error::persona reach check: $role has an agents.$role entry in canary-rings.json, but rides the SHARED persona runtime — no caller pins a per-persona channel tag, so the entry produces unconsumed tags and an unattributable gate. A registered shared-runtime persona is a defect, not a promotion (ADR-0006); remove the entry" >&2
    return 2
  fi
  if [ "$verdict" = "promoted" ] && [ "$routes_via_router" != "true" ]; then
    echo "::error::persona reach check: $role is promoted, but the shared mention router does not serve its deployed events — the promotion did not reach a consumer (routes_via_router=false)" >&2
    return 2
  fi
  if [ "$verdict" = "draft" ]; then
    echo "::notice::persona reach check: $role is still draft — routing wiring present ($routes_via_router), NOT promoted (routes-to != promoted; do not trust the ring label)" >&2
  else
    echo "::notice::persona reach check: $role is promoted (unregistered by design, ADR-0006); the shared router serves its events and the surface stayed mention-only" >&2
  fi
  return 0
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
