# shellcheck shell=bash
# scripts/lib/persona-runner.sh — Persona runtime core (dispatch side)
#
# The other half of the mention framework. The router
# (combsmith/.github scripts/lib/persona-mention.sh) resolves an
# `@combsmith/<role>` mention and fires a `persona-mention`
# repository_dispatch at this repo; this library backs the workflow that
# receives it and runs the addressed persona's advisory prompt.
#
# ONE runner serves EVERY persona — it is manifest/convention driven, not one
# workflow per persona (§4.1: per-agent workflows are the drift the framework
# exists to prevent). It resolves the persona's advisory prompt by convention
# (prompts/<id>/advisory.md) exactly as the router resolves the manifest by
# convention (personas/<id>/persona.yml).
#
# ----------------------------------------------------------------------------
# Caller contract
# ----------------------------------------------------------------------------
# `set -euo pipefail`-safe, sourced by a parent (# shellcheck
# source=scripts/lib/persona-runner.sh). Does NOT call `set` itself and runs
# nothing at source time.
#
# ----------------------------------------------------------------------------
# The recursion marker is shared with the router, on purpose
# ----------------------------------------------------------------------------
# Every comment a persona posts MUST begin with '<!-- persona:<id> -->'. The
# router's pm_is_agent_comment skips any comment carrying '<!-- persona:', so a
# persona's own advisory cannot re-summon it (or any persona named in the
# thread). This is axis 2 of the router's guard, closed from the writing side.
# .github-private#860 burned 1,481 acks in 4.5h without it.
PR_MARKER_PREFIX='<!-- persona:'

# Reuse the one credential-redaction helper rather than defining a second
# (#1775 AC #4). Sourced relative to this file so it resolves whether the
# workflow sources us from the repo root or a test sources us by absolute path.
# shellcheck source=scripts/lib/redact.sh
source "$(dirname "${BASH_SOURCE[0]}")/redact.sh"

# pr_agent_marker <persona-id> — the exact first line every advisory must carry.
pr_agent_marker() {
  printf '%s%s -->' "$PR_MARKER_PREFIX" "$1"
}

# pr_valid_persona_id <id> — 0 if id is a well-formed persona slug (kebab-case).
# The dispatch payload is attacker-influenced only through the mention body,
# which the router already constrained to this shape — but this runner is a
# separate trust boundary (a repository_dispatch can be sent by anything with a
# token), so it re-validates rather than trusting the payload. A bad id must
# never reach a path interpolation.
pr_valid_persona_id() {
  case "$1" in
    "" ) return 1 ;;
    *[!a-z0-9-]* ) return 1 ;;   # only lower kebab
    -* | *- ) return 1 ;;        # no leading/trailing hyphen
    *--* ) return 1 ;;           # no doubled hyphen
    * ) return 0 ;;
  esac
}

# pr_advisory_prompt_path <persona-id> — repo-relative path to the persona's
# advisory prompt. Convention, mirroring the router's manifest-by-convention.
pr_advisory_prompt_path() {
  printf 'prompts/%s/advisory.md' "$1"
}

# pr_require_advisory <persona-id> <repo-root> — echo the prompt path if it
# exists, else fail with a diagnostic. A missing prompt is a real answer
# ("this persona has no runtime wired yet"), not a crash: a persona can enable
# the mention surface and declare an address before its advisory prompt exists,
# and the runner must say so rather than invoke an empty prompt.
pr_require_advisory() {
  local id="$1" root="${2:-.}" path
  if ! pr_valid_persona_id "$id"; then
    echo "persona-runner: refusing malformed persona id '$id'" >&2
    return 2
  fi
  path="$(pr_advisory_prompt_path "$id")"
  if [ ! -f "$root/$path" ]; then
    echo "persona-runner: no advisory prompt at $path — persona '$id' has no runtime wired yet" >&2
    return 3
  fi
  printf '%s\n' "$path"
}

# pr_comment_has_marker <persona-id> <body> — 0 if the body's FIRST line is the
# persona's marker.
#
# CRLF: GitHub API/webhook bodies often use '\r\n', and `read` keeps the '\r',
# so the raw first line would be '<!-- persona:qa-lead -->\r' and never match.
# Strip it.
pr_comment_has_marker() {
  local id="$1" body="$2" first marker
  marker="$(pr_agent_marker "$id")"
  IFS= read -r first <<<"$body"
  first="${first%$'\r'}"
  [ "$first" = "$marker" ]
}

# pr_extract_advisory <agent-stdout> — emit the advisory body the agent placed
# between the sentinels, or nothing.
#
# The agent does NOT post its own comment (it has no token that can write to the
# source repo — see the reusable). It PRINTS the body between two sentinels, and
# the workflow posts it. That is what makes the marker MECHANICALLY enforced
# rather than merely prompt-requested: an agent that forgets the marker cannot
# post an unmarked comment, because it cannot post at all. Prompt-only
# enforcement is how #860 happened (1,481 acks in 4.5h).
PR_ADVISORY_BEGIN='===PERSONA-ADVISORY-BEGIN==='
PR_ADVISORY_END='===PERSONA-ADVISORY-END==='
pr_extract_advisory() {
  printf '%s' "$1" | awk -v b="$PR_ADVISORY_BEGIN" -v e="$PR_ADVISORY_END" '
    $0 == b { grab = 1; next }
    $0 == e { grab = 0 }
    grab    { print }
  '
}

# pr_ensure_marker <persona-id> <body> — echo the body guaranteed to start with
# the persona marker: unchanged if it already leads with it, otherwise the
# marker is prepended. The workflow calls this on the extracted advisory before
# posting, so the recursion guard holds even if the agent omitted the marker.
pr_ensure_marker() {
  local id="$1" body="$2" marker
  marker="$(pr_agent_marker "$id")"
  if pr_comment_has_marker "$id" "$body"; then
    printf '%s' "$body"
  else
    printf '%s\n%s' "$marker" "$body"
  fi
}

# ----------------------------------------------------------------------------
# Post-failure preservation (#1775)
# ----------------------------------------------------------------------------
# The advisory is produced once, at a cost, and is correct. Before #1775 a
# failing `gh api` post (a 403 on 2026-09-08, #1734) destroyed it: it lived only
# in $RUNNER_TEMP and the failed step's log. These helpers preserve the redacted,
# marker-complete body on failure — as an untruncated artifact-bound file AND a
# truncated job-summary mirror — while still failing the run (a green run would
# be worse than the loss). The read/write split is untouched: only the post step
# calls these.

# pr_artifact_name <persona> <source_repo> <item_number> — a deterministic
# artifact name so the right advisory is findable when several runs have failed.
# source_repo is owner/repo; any character an artifact name cannot carry (slash,
# space, and the reserved set) collapses to '-'.
pr_artifact_name() {
  local persona="$1" source_repo="$2" item_number="$3" slug
  slug="$(printf '%s' "$source_repo" | tr -c 'A-Za-z0-9._-' '-')"
  printf 'persona-advisory-%s-%s-%s' "$persona" "$slug" "$item_number"
}

# pr_summary_mirror <body> <artifact_name> [budget_bytes] — emit the body for
# the job summary. The summary is a convenience copy and may be truncated; the
# artifact holds the untruncated copy of record. A body within budget passes
# through verbatim; an oversized body is cut to the budget and gains an explicit
# notice naming the artifact that holds the full text. Default budget 8 KB (the
# summary cap is 1 MB, but the failure notice must stay readable).
PR_SUMMARY_BUDGET_BYTES=8192
pr_summary_mirror() {
  local body="$1" artifact="$2" budget="${3:-$PR_SUMMARY_BUDGET_BYTES}" size
  size="$(printf '%s' "$body" | wc -c)"
  if [ "$size" -le "$budget" ]; then
    printf '%s' "$body"
  else
    printf '%s' "${body:0:budget}"
    printf '\n\n_Truncated at 8 KB — full advisory in the "%s" run artifact._' "$artifact"
  fi
}

# pr_post_failure_message <gh_stderr> <account> <credential> — a diagnostic that
# names the account and credential in play and distinguishes authentication
# (401 — the token is missing/expired/malformed) from authorization (403 — the
# token is valid but the account lacks permission; NOT a missing secret), so the
# next occurrence is diagnosable from the run alone (#1775 AC #3).
pr_post_failure_message() {
  local err="$1" account="$2" credential="$3" code kind
  if [[ "$err" =~ [Hh][Tt][Tt][Pp][[:space:]]+([0-9]{3}) ]]; then
    code="${BASH_REMATCH[1]}"
  else
    code=""
  fi
  case "$code" in
    401) kind="authentication failed (HTTP 401) — the token in '${credential}' is missing, expired, or malformed" ;;
    403) kind="authorization failed (HTTP 403) — the token is valid but '${account}' lacks permission to comment (a valid token is not a missing secret)" ;;
    "")  kind="post failed (no HTTP status in the error)" ;;
    *)   kind="post failed (HTTP ${code})" ;;
  esac
  printf 'posting as %s (credential %s): %s' "$account" "$credential" "$kind"
}

# pr_post_advisory_or_preserve <persona> <source_repo> <item_number> <account>
#     <credential> <marked_body> <body_file> <summary_file>
# Post the marker-complete body via `gh api`. On success: print a confirmation
# and return 0 — nothing is preserved (AC #5). On failure: write the REDACTED
# body to <body_file> (the untruncated, byte-for-byte re-postable artifact copy,
# AC #1/#4), mirror a truncated copy plus a naming notice into <summary_file>
# (AC #1), emit the auth-vs-authz diagnostic (AC #3), and return the post's
# non-zero status so the run still fails (AC #2).
pr_post_advisory_or_preserve() {
  local persona="$1" source_repo="$2" item_number="$3" account="$4" credential="$5"
  local body="$6" body_file="$7" summary_file="$8"
  local redacted err rc=0
  # Redact BEFORE posting, not only on the failure path: a successful post
  # publishes the body to a PR comment, so credential-like text in agent output
  # must be scrubbed there too (redact.sh is defense-in-depth before publishing).
  redacted="$(printf '%s' "$body" | redact_secrets)"
  err="$(gh api "repos/${source_repo}/issues/${item_number}/comments" -f body="$redacted" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'Posted %s advisory on %s#%s.\n' "$persona" "$source_repo" "$item_number"
    return 0
  fi

  local artifact diag
  artifact="$(pr_artifact_name "$persona" "$source_repo" "$item_number")"
  diag="$(pr_post_failure_message "$err" "$account" "$credential")"

  printf '%s' "$redacted" > "$body_file"
  {
    printf '### Persona advisory not posted — preserved for retry\n\n'
    printf '**%s#%s** — %s\n\n' "$source_repo" "$item_number" "$diag"
    pr_summary_mirror "$redacted" "$artifact"
    printf '\n'
  } >> "$summary_file"

  printf '%s\n' "$err" >&2
  printf '::error::%s\n' "$diag" >&2
  return "$rc"
}
