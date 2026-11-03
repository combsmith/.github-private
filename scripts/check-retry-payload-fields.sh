#!/usr/bin/env bash
set -euo pipefail
# scripts/check-retry-payload-fields.sh (#2081) — fail when the dev-lead retry
# sweep sends a client_payload field that the intent parser at a dev-lead channel
# does not read.
#
# The sweep (scripts/dev-lead-retry.sh and the libs it sources) dispatches
# repository_dispatch events whose client_payload is parsed by
# scripts/dev-lead-intent.sh in the TARGET repo, at whatever channel that repo
# pins. Since #2083 the sweep itself runs at this repo's pinned channel, so here
# the sweep and the parser ship together — but a target repo pinned to an older
# channel still parses the sweep's dispatches with an older parser (#2086). A
# field that parser ignores is dropped, and the dispatched run fails or misroutes
# (#2050: comment_node_id broke every fix-bot-comment retry). So a field may be
# sent only once the parser at EVERY channel of the pinned major reads it — the
# AGENTS.md order "harness support reaches the channel first, the sweep change
# merges second".
#
# How the two sides are read (#2085 review: text patterns kept missing cases —
# comments read as fields, brackets inside strings, a stale tag on fetch failure):
#   sent — not scanned: every function in the sweep whose body POSTs to
#          `/dispatches` is EXECUTED with `gh` stubbed to capture the request, and
#          the payload's top-level `client_payload` keys are read with jq. Every
#          dispatch a function makes is kept, in all three request forms: `--input -`,
#          `--input <file>`, and `-f/-F/--field/--raw-field client_payload[key]=`
#          (separate or attached, e.g. `--field=client_payload[key]=v`). A dispatcher that sends
#          nothing (or an unreadable body) for the probe arguments is a setup error,
#          never a silent pass. Two conventions keep that complete: each dispatcher
#          spells the word `dispatches` in its own body (an endpoint held in a
#          global variable is a setup error), and each dispatcher sends ONE fixed set of fields — a
#          new payload shape gets a new function (as dispatch_bot_comment_retry
#          did), never a field added only on some arguments.
#   read — the intent parser (and the libs it sources) at each channel tag is
#          first parsed by bash (wrapped in a function and printed back with
#          `declare -f`), which drops shell comments and keeps strings and
#          heredocs verbatim; `client_payload.<key>` reads are then collected from
#          that text — only the jq path form `.client_payload.<key>` counts, so
#          prose such as an error message naming `client_payload.x` does not.
#          A `#` comment INSIDE a jq program string is not shell syntax
#          and survives, so a reference with a `#` before it on its line (other than
#          `$#`) is not counted — that can only under-count reads, which fails the
#          check loudly rather than certifying an ignored field. A lib the parser
#          sources that cannot be read at a tag is a setup error.
#
# Only top-level client_payload keys are compared; nested keys (e.g.
# checks[].details_url) are consumed downstream of the parser.
#
# Usage: check-retry-payload-fields.sh [root]   (root defaults to the repo root)
# Exit:  0 every sent field is read at every channel · 1 one or more unread fields
#        (each printed) · 2 setup error (agent_ref missing/malformed, the pinned
#        tag unresolvable, a channel tag unfetchable in CI, a dispatcher that sent
#        nothing, nothing parsed), so the sweep cannot be certified

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
STUB=".github/workflows/dev-lead.yml"
SWEEP="scripts/dev-lead-retry.sh"
PARSER="scripts/dev-lead-intent.sh"
CHANNELS=(next ring0 ring1 stable)

# Fields the sweep sends for logs and audit only; no harness code reads them, at
# any channel. Adding a field here asserts that nothing downstream needs it.
#   repo    — redundant with the dispatch target repository
#   attempt — retry counter carried for the run log (#781)
INFORMATIONAL_FIELDS=(repo attempt)

die() { echo "check-retry-payload-fields: $*" >&2; exit 2; }
warn() { echo "check-retry-payload-fields: warning: $*" >&2; }
in_ci() { [[ "${CI:-}" = "true" ]] || [[ "${GITHUB_ACTIONS:-}" = "true" ]]; }

[[ -f "$ROOT/$STUB" ]] || die "$STUB not found under $ROOT"
[[ -f "$ROOT/$SWEEP" ]] || die "$SWEEP not found under $ROOT"
pinned=$(sed -n 's/^[[:space:]]*agent_ref:[[:space:]]*["'\'']\{0,1\}\([^"'\''[:space:]#]*\).*/\1/p' "$ROOT/$STUB" | head -n1)
[[ -n "$pinned" ]] || die "no agent_ref in $STUB"
[[ "$pinned" =~ ^dev-lead/(v[0-9]+)-(next|ring0|ring1|stable)$ ]] \
  || die "agent_ref '$pinned' in $STUB is not a dev-lead channel tag"
major="${BASH_REMATCH[1]}"

# ── sent: execute each dispatcher with gh stubbed ────────────────────────────
# Prints "<function> <field>" per top-level client_payload key, or
# "NOPAYLOAD <function>" when a dispatcher sent nothing.
sent_fields() {
  local capture
  capture=$(mktemp)
  # shellcheck disable=SC2016  # the inner script expands its own variables
  CAPTURE="$capture" SWEEP_PATH="$ROOT/$SWEEP" bash --noprofile --norc -c '
    set +e
    export DRY_RUN=false DISPATCH_DELAY_SEC=0
    # shellcheck source=/dev/null
    # Sourced with errexit ON and outside any `||`/`if` context, so a failure
    # partway through (a missing lib, a failing init) aborts here and the
    # SOURCED sentinel never prints; the caller treats its absence as a setup
    # error rather than certifying an incomplete set of dispatchers.
    set -e
    source "$SWEEP_PATH" >/dev/null 2>&1
    echo "SOURCED"
    set +e +u
    gh() {
      local a prev="" is_dispatch=false input=""
      local -a kv=()
      for a in "$@"; do
        case "$a" in */dispatches) is_dispatch=true ;; esac
        [ "$prev" = "--input" ] && input="$a"
        case "$a" in --input=*) input="${a#--input=}" ;; esac
        case "$prev" in
          -f|-F|--field|--raw-field) kv+=("$a") ;;
        esac
        # The attached forms gh also accepts: --field=k=v, --raw-field=k=v,
        # -f=k=v / -F=k=v, and -fk=v / -Fk=v.
        case "$a" in
          --field=*|--raw-field=*) kv+=("${a#*=}") ;;
          -f=*|-F=*) kv+=("${a:3}") ;;
          -f?*|-F?*) kv+=("${a:2}") ;;
        esac
        prev="$a"
      done
      if ! $is_dispatch; then echo "{}"; return 0; fi
      # One compact JSON line per dispatch (appended), so a function that
      # dispatches more than once has every request checked; an unreadable body
      # is recorded as such and fails the check.
      if [ -n "$input" ]; then
        local body
        if [ "$input" = "-" ]; then body=$(cat); else body=$(cat -- "$input" 2>/dev/null); fi
        jq -ce "if type == \"object\" then . else error end" <<<"$body" >>"$CAPTURE" 2>/dev/null \
          || echo "\"UNREADABLE\"" >>"$CAPTURE"
        return 0
      fi
      local pair keys="[]"
      for pair in "${kv[@]}"; do
        case "$pair" in
          client_payload\[*\]=*)
            pair="${pair#client_payload[}"
            keys=$(jq -c --arg k "${pair%%]=*}" ". + [\$k]" <<<"$keys") ;;
        esac
      done
      jq -cn --argjson keys "$keys" "{client_payload: (\$keys | map({(.): 1}) | add // {})}" >>"$CAPTURE"
    }
    # Dispatchers are found by the word `dispatches` in their own body, so an
    # endpoint assembled in a local (`ep="repos/$r/"; ep+="dispatches"`) is still
    # found. An endpoint held in a global would hide its dispatcher: setup error.
    for v in $(compgen -v); do
      case "$v" in BASH_*|FUNCNAME|_|CAPTURE|SWEEP_PATH) continue ;; esac
      case "${!v}" in *dispatches*) echo "INDIRECT"; break ;; esac
    done
    for fn in $(declare -F | awk "{print \$3}"); do
      [ "$fn" = gh ] && continue
      declare -f "$fn" | grep -q "dispatches" || continue
      : >"$CAPTURE"
      "$fn" 1 1 1 1 1 1 </dev/null >/dev/null 2>&1
      if [ ! -s "$CAPTURE" ] || grep -qx "\"UNREADABLE\"" "$CAPTURE"; then echo "NOPAYLOAD $fn"; continue; fi
      if keys=$(jq -r --arg fn "$fn" ".client_payload // {} | keys[] | \"\(\$fn) \(.)\"" "$CAPTURE" 2>/dev/null); then
        if [ -n "$keys" ]; then sort -u <<<"$keys"; else echo "NOPAYLOAD $fn"; fi
      else
        echo "NOPAYLOAD $fn"
      fi
    done
  '
  rm -f "$capture"
}

# ── read: bash-parse a script, then collect client_payload.<key> reads ───────
# parse_script <source-text> — print the script as bash re-emits it inside a
# function: comments dropped, code and string literals kept. Fails on a syntax
# error (so an unparseable parser is a setup error, not "reads nothing").
parse_script() {
  # shellcheck disable=SC2016
  bash --noprofile --norc -c 'eval "__check_retry_payload_parsed() {
$1
}" && declare -f __check_retry_payload_parsed' _ "$1"
}

# fields_read_at <tag> — the client_payload keys the parser (and the libs it
# sources) read at <tag>, one per line.
fields_read_at() {
  local tag="$1" src parsed libs lib lib_src out=""
  src=$(git -C "$ROOT" show "${tag}:${PARSER}" 2>/dev/null) || die "cannot read ${PARSER} at ${tag}"
  parsed=$(parse_script "$src") || die "cannot parse ${PARSER} at ${tag}"
  out="$parsed"
  # Walk the source graph (a lib may source another lib), each lib once.
  local -a queue=() seen=()
  mapfile -t queue < <(grep -oE '/lib/[A-Za-z0-9_.-]+\.sh' <<<"$parsed" | sort -u)
  while [[ "${#queue[@]}" -gt 0 ]]; do
    lib="${queue[0]}"; queue=("${queue[@]:1}")
    case " ${seen[*]} " in *" $lib "*) continue ;; esac
    seen+=("$lib")
    lib_src=$(git -C "$ROOT" show "${tag}:scripts${lib}" 2>/dev/null) || die "cannot read scripts${lib} (sourced by ${PARSER}) at ${tag}"
    libs=$(parse_script "$lib_src") || die "cannot parse scripts${lib} at ${tag}"
    out+=$'\n'"$libs"
    mapfile -t -O "${#queue[@]}" queue < <(grep -oE '/lib/[A-Za-z0-9_.-]+\.sh' <<<"$libs" | sort -u)
  done
  sed -E 's/(^|[^$])#.*$/\1/' <<<"$out" \
    | grep -oE '\.client_payload\.[A-Za-z_][A-Za-z0-9_]*' | sed 's/^\.client_payload\.//' | sort -u || true
}

# ── channel tags ─────────────────────────────────────────────────────────────
# CI checkouts carry no tags and a local tag may be stale after a promote, so each
# channel tag is refreshed from origin. In CI a failed fetch is a setup error
# (never a stale pass); locally it falls back to the local tag with a warning.
have_origin=false
git -C "$ROOT" remote get-url origin >/dev/null 2>&1 && have_origin=true
tags=()
# --depth=1 only on a clone that is already shallow (a CI checkout): on a full
# local clone it would make the repository shallow.
depth=()
[[ "$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = true ]] && depth=(--depth=1)
for ch in "${CHANNELS[@]}"; do
  tag="dev-lead/${major}-${ch}"
  gone_upstream=false
  if $have_origin && ! git -C "$ROOT" fetch --quiet --force ${depth[@]+"${depth[@]}"} origin "refs/tags/${tag}:refs/tags/${tag}" 2>/dev/null; then
    # Tell "origin has no such tag" (ls-remote exit 2) apart from "origin could
    # not be reached / the fetch broke" — only the latter risks a stale tag.
    rc=0
    git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 2 ]]; then
      gone_upstream=true   # origin has no such tag: never trust a local copy
    else
      in_ci && die "could not fetch ${tag} from origin"
      warn "could not fetch ${tag} from origin; using the local tag"
    fi
  fi
  if ! $gone_upstream && git -C "$ROOT" rev-parse --verify --quiet "refs/tags/${tag}^{commit}" >/dev/null; then
    tags+=("$tag")
  elif [[ "$tag" = "$pinned" ]]; then
    die "the pinned channel ${tag} does not resolve"
  else
    warn "${tag} does not exist; skipping it"
  fi
done

# ── compare ──────────────────────────────────────────────────────────────────
sent=$(sent_fields)
grep -qx 'SOURCED' <<<"$sent" || die "sourcing ${SWEEP} failed (or aborted partway), so its dispatchers cannot be certified"
sent=$(grep -vx 'SOURCED' <<<"$sent" || true)
grep -q '^INDIRECT$' <<<"$sent" \
  && die "a variable in ${SWEEP} (or a lib it sources) holds a /dispatches endpoint; write the endpoint literally in each dispatcher so the check can find and run it"
if nopayload=$(grep '^NOPAYLOAD ' <<<"$sent"); then
  die "dispatcher(s) sent no client_payload for the probe call, so their fields cannot be certified: $(cut -d' ' -f2 <<<"$nopayload" | tr '\n' ' ')"
fi
[[ -n "$sent" ]] || die "no dispatcher in ${SWEEP} sent a client_payload; the check may need updating"

missing=0
for tag in "${tags[@]}"; do
  read_fields=$(fields_read_at "$tag")
  [[ -n "$read_fields" ]] || die "${PARSER} at ${tag} reads no client_payload fields; the check may need updating"
  while read -r fn field; do
    case " ${INFORMATIONAL_FIELDS[*]} " in *" $field "*) continue ;; esac
    if ! grep -qxF "$field" <<<"$read_fields"; then
      echo "client_payload.${field} (sent by ${fn}) is not read by ${PARSER} at ${tag}"
      missing=1
    fi
  done <<<"$sent"
done

if [[ "$missing" -ne 0 ]]; then
  echo "Land the parser change and promote it to every channel above before the sweep sends these fields (AGENTS.md \"Caller-stub input forwarding across channel pins\")."
  exit 1
fi
echo "OK: every client_payload field the sweep sends is read by ${PARSER} at ${tags[*]}"
