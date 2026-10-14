#!/usr/bin/env bash
#
# cut-release.sh — cut an immutable agent release tag and (optionally) advance a
# channel tag to it. The GitHub-native primitive behind the Release Strategy
# initiative (epic #495): immutable `<agent>/vX.Y.Z` tags are audit/rollback
# targets; moving `<agent>/v<MAJOR>-<tier>` channel tags are what callers pin to.
#
# Channels are major-scoped (#1184, epic #657): a breaking (major) release gets
# its own channel line, so it cannot silently reach a consumer that has not
# opted into that major. See docs/initiatives/agentic-release-strategy.md §5.2.
#
# Usage:
#   cut-release.sh <agent> <version> [--ref <ref>] [--channel <name>]
#                                    [--push] [--dry-run]
#
#   <agent>      this repo: pr-review | dev-lead | ci-failure-analyst
#                cross-repo (reusable in petry-projects/.github): feature-ideation | idea-enhancer | add-to-project | pr-auto-review |
#                  agent-shield | auto-rebase | dependency-audit |
#                  dependabot-automerge | dependabot-rebase | pr-review-mention | persona-mention
#   <version>    semantic version without the leading v, e.g. 1.2.0
#   --ref        commit/ref to tag (default: main). Resolved against the agent's
#                HOST repo via the API for EVERY agent (an `origin/` prefix is
#                stripped — `origin/main` means the host's `main`).
#   --channel    also move the major-scoped channel to the new release. Accepts a
#                bare tier (stable | next | ring0 | ring1) — resolved to
#                <agent>/v<MAJOR-of-version>-<tier> — OR a fully-qualified
#                v<M>-<tier> (e.g. v1-ring0), which pins that major as-is.
#   --promote    move the channel to the EXISTING <agent>/vX.Y.Z release instead
#                of cutting a new one (ring-to-ring promotion within the release's
#                major). Requires --channel; errors if the release tag does not
#                already exist; --ref is ignored (the release's own commit is
#                authoritative).
#   --push       publish the created/moved tags (default: print only).
#   --dry-run    print what would happen; touch nothing
#
# Examples:
#   cut-release.sh pr-review 1.1.0 --push
#   cut-release.sh pr-review 1.1.0 --channel stable --push    # moves pr-review/v1-stable
#   cut-release.sh dev-lead  2.0.0 --channel stable --dry-run # plans dev-lead/v2-stable
#   cut-release.sh dev-lead  1.4.0 --channel v1-ring0 --push  # explicit v1-ring0 (pins v1)
#   cut-release.sh agent-shield 2.1.0 --channel next --push   # cross-repo → .github; agent-shield/v2-next
#
# ONE consistent path for every agent (#1076). All tag operations — resolve,
# create, and channel-move — go through `gh api` against the agent's HOST repo
# (this-repo agents included). This matters because a local `git push --force`
# is NOT granted the release-manager App's ruleset bypass for a tag UPDATE, so it
# GH013s ("Cannot update this protected ref") when moving a protected channel tag
# such as `dev-lead/next`; the API path, authenticated with the same App token,
# IS honored as a bypass actor. Requires GH_TOKEN with contents:write on the host
# repo. The host is petry-projects/.github for cross-repo agents (#872) and the
# current repo (GITHUB_REPOSITORY / origin) otherwise. See
# docs/release/versioning.md "Cross-repo reusables".
#
# The pure helpers (valid_agent, cross_repo_agent, agent_host_repo, this_repo,
# validate_version, release_ref, major_of, channel_ref, strip_origin) are defined
# at the top level so tests can `source` this file without executing it (see the
# source-guard at the bottom and tests/test_cut_release.bats).
#
set -euo pipefail

# The repo whose git refs hold cross-repo agents' release/channel tags.
CROSS_REPO_TARGET="petry-projects/.github"

# ── pure helpers (sourced by tests; no side effects) ─────────────────────────

# valid_agent <agent> — return 0 iff agent is a known agent name. Covers the
# agents hosted in this repo (pr-review, dev-lead, ci-failure-analyst) plus the
# cross-repo reusables hosted in petry-projects/.github (feature-ideation and the
# six #482 reusables brought under the ring model in #870).
valid_agent() {
  case "$1" in
    pr-review | dev-lead | ci-failure-analyst) return 0 ;;
    *) cross_repo_agent "$1" ;;
  esac
}

# cross_repo_agent <agent> — return 0 iff the agent's reusable workflow lives in
# petry-projects/.github (this repo holds only the thin caller stub). For these,
# a "release" is a commit on that public repo, so its release/channel tags are
# resolved and cut against THAT repo (CROSS_REPO_TARGET). See
# docs/release/versioning.md "Cross-repo reusables".
cross_repo_agent() {
  case "$1" in
    feature-ideation | idea-enhancer | add-to-project | pr-auto-review) return 0 ;;
    agent-shield | auto-rebase | dependency-audit) return 0 ;;
    dependabot-automerge | dependabot-rebase | pr-review-mention | persona-mention) return 0 ;;
    *) return 1 ;;
  esac
}

# this_repo — echo the owner/repo of the repository this script runs against.
# Prefers GITHUB_REPOSITORY (always set on a runner); falls back to the `origin`
# remote for local use. Both git@ and https:// remote URL forms are normalized.
this_repo() {
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    printf '%s\n' "$GITHUB_REPOSITORY"; return 0
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null)" || {
    echo "::error::cannot determine the current repo (GITHUB_REPOSITORY unset and no 'origin' remote)" >&2
    return 1
  }
  url="${url%.git}"; url="${url#*github.com[:/]}"
  printf '%s\n' "$url"
}

# agent_host_repo <agent> — echo the owner/repo whose refs hold this agent's tags:
# petry-projects/.github for cross-repo agents (#872), else the current repo.
agent_host_repo() {
  if cross_repo_agent "$1"; then printf '%s\n' "$CROSS_REPO_TARGET"; else this_repo; fi
}

# validate_version <version> — return 0 iff strictly MAJOR.MINOR.PATCH numerics.
validate_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# release_ref <agent> <version> — echo the immutable release tag name.
release_ref() { printf '%s/v%s\n' "$1" "$2"; }

# major_of <version> — echo the MAJOR component of a MAJOR.MINOR.PATCH version.
major_of() { printf '%s\n' "${1%%.*}"; }

# channel_ref <agent> <version> <channel> — echo the major-scoped channel tag
# name (#1184, epic #657). Channels are scoped by major so a breaking (major)
# release cannot silently reach a consumer that has not opted into that major:
#   - a bare tier (stable | next | ring0 | ring1) is prefixed with the version's
#     major → channel_ref dev-lead 2.0.0 stable  = dev-lead/v2-stable
#   - a fully-qualified v<M>-<tier> passes through unchanged; its OWN major wins,
#     so an explicit --channel v1-ring0 pins v1 regardless of <version> →
#     channel_ref dev-lead 2.0.0 v1-ring0 = dev-lead/v1-ring0
channel_ref() {
  local agent="$1" version="$2" channel="$3"
  if [[ "$channel" =~ ^v[0-9]+- ]]; then
    printf '%s/%s\n' "$agent" "$channel"
  else
    printf '%s/v%s-%s\n' "$agent" "$(major_of "$version")" "$channel"
  fi
}

# strip_origin <ref> — normalize a local-style ref to a remote-repo ref name for
# the API path: `origin/main` → `main`, a bare ref/SHA passes through.
# (`git rev-parse` understands `origin/main`; the GitHub API does not.)
strip_origin() { printf '%s\n' "${1#origin/}"; }

# ── tag operations (gh api; require GH_TOKEN with contents:write on the host) ──
# Thin wrappers kept separate from the pure helpers so the network surface is
# explicit. Each targets an arbitrary <repo> so tests can mock `gh`.

# gh_resolve_sha <repo> <ref> — echo the commit SHA <ref> resolves to on <repo>.
gh_resolve_sha() { gh api "repos/$1/commits/$2" --jq '.sha'; }

# gh_tag_exists <repo> <tag> — return 0 iff refs/tags/<tag> exists on <repo>.
gh_tag_exists() { gh api "repos/$1/git/ref/tags/$2" >/dev/null 2>&1; }

# gh_create_annotated_tag <repo> <tag> <sha> <message> — create an annotated tag
# object and the ref pointing at it (mirrors `git tag -a`). Fails if the ref
# exists (the API refuses to create a duplicate ref — immutability is enforced).
gh_create_annotated_tag() {
  local obj
  obj=$(gh api -X POST "repos/$1/git/tags" \
        -f "tag=$2" -f "message=$4" -f "object=$3" -f "type=commit" --jq '.sha')
  gh api -X POST "repos/$1/git/refs" -f "ref=refs/tags/$2" -f "sha=$obj" >/dev/null
}

# gh_release_commit <repo> <tag> — echo the COMMIT sha a release tag points to,
# dereferencing an annotated tag object. Empty + non-zero if the tag is absent.
gh_release_commit() {
  local ref_info obj type
  ref_info=$(gh api "repos/$1/git/ref/tags/$2" --jq '.object?.sha + " " + .object?.type' 2>/dev/null) || return 1
  [ -z "$ref_info" ] && return 1
  read -r obj type <<< "$ref_info"
  if [ "$type" = "tag" ]; then
    gh api "repos/$1/git/tags/$obj" --jq '.object?.sha' 2>/dev/null
  else
    printf '%s\n' "$obj"
  fi
}

# gh_move_tag <repo> <tag> <sha> — point refs/tags/<tag> at <sha> (force-move if
# it exists, create if not). Lightweight ref, matching `git tag -f` for channels.
gh_move_tag() {
  if gh_tag_exists "$1" "$2"; then
    gh api -X PATCH "repos/$1/git/refs/tags/$2" -f "sha=$3" -F "force=true" >/dev/null
  else
    gh api -X POST "repos/$1/git/refs" -f "ref=refs/tags/$2" -f "sha=$3" >/dev/null
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  local agent="" version="" ref="origin/main" channel="" do_push=false dry=false promote=false

  if [ "$#" -lt 2 ]; then
    echo "::error::usage: cut-release.sh <agent> <version> [--ref <ref>] [--channel <name>] [--push] [--dry-run]" >&2
    return 2
  fi
  agent="$1"
  version="$2"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ref)
        [ "$#" -lt 2 ] && { echo "::error::--ref requires an argument" >&2; return 2; }
        ref="$2"; shift 2 ;;
      --channel)
        [ "$#" -lt 2 ] && { echo "::error::--channel requires an argument" >&2; return 2; }
        channel="$2"; shift 2 ;;
      --push) do_push=true; shift ;;
      --promote) promote=true; shift ;;
      --dry-run) dry=true; shift ;;
      *) echo "::error::unknown argument: $1" >&2; return 2 ;;
    esac
  done

  if ! valid_agent "$agent"; then
    echo "::error::unknown agent '$agent' (expected: pr-review | dev-lead | ci-failure-analyst | feature-ideation | idea-enhancer | add-to-project | pr-auto-review | agent-shield | auto-rebase | dependency-audit | dependabot-automerge | dependabot-rebase | pr-review-mention | persona-mention)" >&2
    return 2
  fi
  if ! validate_version "$version"; then
    echo "::error::invalid version '$version' (expected MAJOR.MINOR.PATCH, e.g. 1.2.0)" >&2
    return 2
  fi

  # Every agent's tags live on its HOST repo; ALL writes go through `gh api` with
  # the App token so the release-channel-tags ruleset bypass is applied uniformly
  # (a local `git push` is not granted the App's bypass for a tag UPDATE → GH013
  # on protected channel moves, #1076). One path, this-repo and cross-repo alike.
  command -v gh >/dev/null 2>&1 || {
    echo "::error::'gh' CLI is required (all tag operations go through the GitHub API) but was not found in PATH" >&2
    return 1
  }
  local host; host="$(agent_host_repo "$agent")" || return 1

  local rel chan sha pushrefs
  rel="$(release_ref "$agent" "$version")"
  pushrefs=("$rel")
  if [ -n "$channel" ]; then chan="$(channel_ref "$agent" "$version" "$channel")"; pushrefs+=("$chan"); fi

  # ── --promote: move an existing release's channel; never cut a new tag ──
  # A ring-to-ring promotion (e.g. ring0 → ring1 of an already-cut vX.Y.Z). The
  # release commit is read from the existing tag, so --ref is irrelevant and the
  # immutable release tag is left untouched (and MUST exist).
  if [ "$promote" = true ]; then
    [ -z "$channel" ] && { echo "::error::--promote requires --channel <name> (the ring to advance to the existing release)" >&2; return 2; }
    gh_tag_exists "$host" "$rel" || { echo "::error::cannot promote: release tag '$rel' does not exist on $host — cut it first." >&2; return 1; }
    local pcommit
    if ! pcommit="$(gh_release_commit "$host" "$rel")" || [ -z "$pcommit" ]; then
      echo "::error::failed to resolve commit for release tag '$rel' on $host" >&2
      return 1
    fi
    echo "promote $chan -> $rel ($pcommit) on $host"
    [ "$dry" = true ] && { echo "(dry-run) channel not moved."; return 0; }
    [ "$do_push" != true ] && { echo "print only — re-run with --push to move $chan on $host"; return 0; }
    gh_move_tag "$host" "$chan" "$pcommit"
    echo "moved $chan -> $pcommit on $host"
    return 0
  fi

  # Resolve the target SHA against the host repo via the API (`origin/` stripped).
  local rref; rref="$(strip_origin "$ref")"
  if ! sha="$(gh_resolve_sha "$host" "$rref")" || [ -z "$sha" ]; then
    echo "::error::ref '$rref' could not be resolved on $host (check the ref exists and GH_TOKEN has access)" >&2
    return 1
  fi

  echo "agent=$agent version=$version ref=$ref ($sha) target=$host"
  echo "release tag: $rel"
  [ -n "$channel" ] && echo "channel tag: $chan -> $rel"

  if [ "$dry" = true ]; then
    echo "(dry-run) no tags created or pushed."
    return 0
  fi

  # Immutable release tags are never overwritten.
  if gh_tag_exists "$host" "$rel"; then
    echo "::error::release tag '$rel' already exists on $host — immutable tags are never overwritten." >&2
    return 1
  fi
  if [ "$do_push" != true ]; then
    echo "print only — re-run with --push to publish to $host: ${pushrefs[*]}"
    return 0
  fi
  gh_create_annotated_tag "$host" "$rel" "$sha" "$agent release v$version"
  echo "created $rel on $host"
  if [ -n "$channel" ]; then
    gh_move_tag "$host" "$chan" "$sha"
    echo "moved $chan -> $sha on $host"
  fi
  echo "published to $host: ${pushrefs[*]}"
  return 0
}

# Run main only when executed directly, so tests can source the helpers.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
