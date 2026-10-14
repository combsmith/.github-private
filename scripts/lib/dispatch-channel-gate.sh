#!/usr/bin/env bash
# dispatch-channel-gate.sh — hold a retry payload back from a target repo whose
# pinned dev-lead harness does not read every field in it (#2086).
#
# WHY THIS EXISTS
#   dev-lead-retry.yml runs scripts/ at ONE release: the channel this repo's
#   dev-lead.yml pins via `agent_ref` (#2050). The sweep then sends
#   repository_dispatch events to every repo in the org, and each target parses
#   them with scripts/dev-lead-intent.sh at ITS OWN dev-lead.yml pin (the stub
#   contract allows a per-repo ring/channel pin). A target pinned older than the
#   sweep can be sent a client_payload field its parser drops — the #2017 / #2050
#   skew again, across repos instead of across time.
#
# WHAT THIS LIBRARY DECIDES
#   Per payload, not per repo: most retry payloads carry only fields every
#   release reads, so a target on an older channel (the fleet sits on stable)
#   keeps its retries; only a payload with a field the target's parser lacks is
#   held back. For each target:
#     pin       its dev-lead.yml `agent_ref` (the reusable's default, main, when
#               the stub passes none) — the ref its harness checks scripts/ out at
#     fields    the `.client_payload.<key>` reads in dev-lead-intent.sh and the
#               lib/*.sh files it names, at that pin (comments stripped; the
#               same reading scripts/check-retry-payload-fields.sh does in CI)
#   A payload goes out only when the target's parser reads all its fields
#   (INFORMATIONAL ones aside). Pin == the sweep's channel needs no lookup: the
#   sweep and that parser ship together, and CI checks them against each other.
#     no dev-lead.yml            nothing in that repo receives it → hold, no warning
#                                (a 404 counts only when the repo itself is readable)
#     pin or parser unreadable   compatibility unproven → hold, warn (fail closed)
#     a field not read           hold, warn once per repo and field set
#   A held payload leaves its markers in place, so the retry resumes once the
#   target is repinned to a channel that reads the field.
#
# The gate is OFF (every payload allowed, no API reads) until dcg_init runs with
# SWEEP_AGENT_REF set — dev-lead-retry.yml passes its resolved channel. Unit
# tests and scripts/check-retry-payload-fields.sh source the sweep without it.
#
# Env:
#   SWEEP_AGENT_REF  the channel tag the sweep's scripts/ run at; enables the gate
#   DCG_HOST_REPO    repo hosting the dev-lead scripts and channel tags (default:
#                    $GITHUB_REPOSITORY, else petry-projects/.github-private)

DCG_HOST_REPO="${DCG_HOST_REPO:-${GITHUB_REPOSITORY:-petry-projects/.github-private}}"
# Same channel-tag shape dev-lead-retry.yml accepts for the sweep's own pin.
DCG_CHANNEL_RE='^dev-lead/v[0-9]+-(next|ring0|ring1|stable)$'
DCG_PARSER="scripts/dev-lead-intent.sh"
# Sent for logs and audit only; no harness code reads them. Mirrors
# INFORMATIONAL_FIELDS in scripts/check-retry-payload-fields.sh.
DCG_INFORMATIONAL_FIELDS=(repo attempt)
DCG_SWEEP_REF=""
# Per-sweep cache. The sweep runs its scans and these lookups inside command
# substitutions (subshells), where a shell variable written is lost on return, so
# the cache lives in files: pin.<repo> = ref | "!<rc>", fields.<ref> = keys | "!",
# warned.<key>. dcg_init makes it; without it nothing is cached.
DCG_CACHE_DIR="${DCG_CACHE_DIR:-}"

_dcg_cache_file() {
  printf '%s/%s.%s' "$DCG_CACHE_DIR" "$1" "$(printf '%s' "$2" | sha256sum | cut -c1-32)"
}
# _dcg_cache_get <kind> <key>: prints the cached value; returns 1 on a miss.
_dcg_cache_get() {
  [ -n "$DCG_CACHE_DIR" ] || return 1
  local f
  f="$(_dcg_cache_file "$1" "$2")"
  [ -f "$f" ] || return 1
  cat -- "$f"
}
# _dcg_cache_put <kind> <key> <value>
_dcg_cache_put() {
  [ -n "$DCG_CACHE_DIR" ] || return 0
  printf '%s' "$3" >"$(_dcg_cache_file "$1" "$2")" 2>/dev/null || true
}

# dcg_init: turn the gate on for the sweep's channel. Returns 1 when
# SWEEP_AGENT_REF is set but is not a channel tag (a configuration error).
dcg_init() {
  DCG_SWEEP_REF=""
  [ -n "${SWEEP_AGENT_REF:-}" ] || return 0
  if [[ ! "$SWEEP_AGENT_REF" =~ $DCG_CHANNEL_RE ]]; then
    echo "::error::[retry] SWEEP_AGENT_REF '${SWEEP_AGENT_REF}' is not a dev-lead channel tag (dev-lead/v<N>-next|ring0|ring1|stable)" >&2
    return 1
  fi
  DCG_SWEEP_REF="$SWEEP_AGENT_REF"
  if [ -z "$DCG_CACHE_DIR" ]; then
    DCG_CACHE_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dcg.XXXXXX")" || return 1
  fi
}

# dcg_parse_agent_ref: stdin = dev-lead.yml text; prints the ref its harness
# runs at — `agent_ref`, else the reusable's default `main`. Returns 1 when the
# value is not a plain ref (an expression, say), so it cannot be resolved here.
dcg_parse_agent_ref() {
  local text ref
  text="$(cat)"
  ref="$(sed -nE "s/^[[:space:]]*agent_ref:[[:space:]]*[\"']?([^\"'[:space:]#]*).*/\1/p" <<<"$text" | head -n 1)"
  if ! grep -qE "^[[:space:]]*agent_ref:" <<<"$text"; then
    ref="main"
  fi
  [[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
  printf '%s\n' "$ref"
}

# dcg_target_pin <repo>: prints the ref <repo>'s dev-lead harness runs at.
# Returns 2 when the (readable) repo has no dev-lead.yml, 1 when the pin is
# unreadable — the repo itself included.
# Cached per sweep.
dcg_target_pin() {
  local repo="$1" out rc=0
  if out="$(_dcg_cache_get pin "$repo")"; then
    if [[ "$out" == "!"* ]]; then return "${out#!}"; fi
    printf '%s\n' "$out"; return 0
  fi
  out="$(gh api "repos/${repo}/contents/.github/workflows/dev-lead.yml" \
      -H "Accept: application/vnd.github.raw" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rc=1
    # GitHub also answers 404 for a repo the token cannot read; only a readable
    # repo's 404 means the stub is absent.
    if [[ "$out" == *"HTTP 404"* ]] \
       && gh api "repos/${repo}" --jq '.full_name' >/dev/null 2>&1; then
      rc=2
    fi
  elif ! out="$(dcg_parse_agent_ref <<<"$out")"; then
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    _dcg_cache_put pin "$repo" "!${rc}"
    return "$rc"
  fi
  _dcg_cache_put pin "$repo" "$out"
  printf '%s\n' "$out"
}

# _dcg_fetch_at <path> <ref>: raw file content from the host repo at <ref>.
_dcg_fetch_at() {
  local path="$1" ref="$2" enc
  enc="$(jq -rn --arg r "$ref" '$r | @uri')" || return 1
  gh api "repos/${DCG_HOST_REPO}/contents/${path}?ref=${enc}" \
    -H "Accept: application/vnd.github.raw" 2>/dev/null
}

# dcg_fields_read_at <ref>: the top-level client_payload keys the intent parser
# (and the lib/*.sh files it names, transitively) reads at <ref>, one per line.
# Returns 1 when any of those files cannot be read. Cached per sweep.
dcg_fields_read_at() {
  local ref="$1" src all="" lib
  if all="$(_dcg_cache_get fields "$ref")"; then
    [ "$all" != "!" ] || return 1
    [ -z "$all" ] || printf '%s\n' "$all"
    return 0
  fi
  all=""
  local -a queue=("$DCG_PARSER") seen=()
  while [ "${#queue[@]}" -gt 0 ]; do
    lib="${queue[0]}"; queue=("${queue[@]:1}")
    case " ${seen[*]} " in *" $lib "*) continue ;; esac
    seen+=("$lib")
    if ! src="$(_dcg_fetch_at "$lib" "$ref")" || [ -z "$src" ]; then
      _dcg_cache_put fields "$ref" "!"
      return 1
    fi
    # Drop shell comments (not `$#`), so prose naming a field is not a read.
    src="$(sed -E 's/(^|[^$])#.*$/\1/' <<<"$src")"
    all+="$src"$'\n'
    mapfile -t -O "${#queue[@]}" queue < <(grep -oE '/lib/[A-Za-z0-9_.-]+\.sh' <<<"$src" | sed 's|^|scripts|' | sort -u)
  done
  all="$(grep -oE '\.client_payload\.[A-Za-z_][A-Za-z0-9_]*' <<<"$all" \
           | sed 's/^\.client_payload\.//' | sort -u || true)"
  [ -z "$all" ] || all+=$'\n'
  _dcg_cache_put fields "$ref" "$all"
  printf '%s' "$all"
}

# _dcg_warn_once <key> <message>: a ::warning:: per key per sweep, so a repo with
# many held PRs logs its reason once.
_dcg_warn_once() {
  ! _dcg_cache_get warned "$1" >/dev/null || return 0
  _dcg_cache_put warned "$1" 1
  echo "::warning::$2" >&2
}

# dcg_target_reads <repo> <field>...: 0 when <repo>'s pinned parser reads every
# field (informational ones aside), or the gate is off; 1 to hold the payload.
dcg_target_reads() {
  local repo="$1"; shift
  [ -n "$DCG_SWEEP_REF" ] || return 0
  local pin rc=0
  pin="$(dcg_target_pin "$repo")" || rc=$?
  case "$rc" in
    0) ;;
    2)
      echo "  [hold] ${repo}: no dev-lead.yml, so nothing there receives a retry (#2086)" >&2
      return 1 ;;
    *)
      _dcg_warn_once "pin:${repo}" "[retry] holding retries for ${repo}: cannot read the ref its dev-lead.yml runs the harness at (agent_ref), so the fields its parser reads are unproven (#2086)"
      return 1 ;;
  esac
  [ "$pin" != "$DCG_SWEEP_REF" ] || return 0

  local fields
  if ! fields="$(dcg_fields_read_at "$pin")"; then
    _dcg_warn_once "fields:${pin}" "[retry] holding retries for repos pinned to ${pin}: cannot read ${DCG_PARSER} and its libs there, so the fields it reads are unproven (#2086)"
    return 1
  fi
  local f info missing=()
  for f in "$@"; do
    [ -n "$f" ] || continue
    for info in "${DCG_INFORMATIONAL_FIELDS[@]}"; do
      [ "$f" != "$info" ] || continue 2
    done
    grep -qxF -- "$f" <<<"$fields" || missing+=("$f")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  _dcg_warn_once "miss:${repo}:${missing[*]}" "[retry] holding retries for ${repo}: it pins ${pin}, whose ${DCG_PARSER} does not read client_payload field(s) ${missing[*]} that the sweep at ${DCG_SWEEP_REF} sends (#2086). Repin it to a channel that reads them."
  echo "  [hold] ${repo} (${pin}) does not read: ${missing[*]}" >&2
  return 1
}

# dcg_payload_allowed <repo> <event_json>: dcg_target_reads over the top-level
# client_payload keys of a repository_dispatch body.
dcg_payload_allowed() {
  local repo="$1" body="$2" keys
  [ -n "$DCG_SWEEP_REF" ] || return 0
  if ! keys="$(jq -r '.client_payload | keys[]' <<<"$body" 2>/dev/null)"; then
    echo "  [hold] ${repo}: unreadable retry payload (#2086)" >&2
    return 1
  fi
  local -a fields=()
  mapfile -t fields <<<"$keys"
  dcg_target_reads "$repo" "${fields[@]}"
}
