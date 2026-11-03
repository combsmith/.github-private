#!/usr/bin/env bash
set -euo pipefail
# Merged-PR few-shot injection helper for the PR-review cascade (issue #1093,
# epic #1088, Phase 2).
#
# Goal: give the deep-review (run_agentic deep) tier a few-shot file of past
# review->merge outcomes for THIS repo so it calibrates to what the maintainers
# actually accept and flag — improving precision cheaply. The examples are
# rendered into a bounded FEWSHOT block whose path is exported as FEWSHOT_FILE,
# mirroring the DOWNSTREAM_IMPACT_FILE / SYMBOL_CONTEXT_FILE optional-file
# contract the deep tier already reads (scripts/lib/downstream-impact.sh,
# scripts/lib/symbol-context.sh).
#
# Held-out discipline is non-negotiable (AC #2, evals/README.md). Few-shot
# examples must be sourced ONLY from a proposer-visible / dev split, NEVER from
# evals/**/holdout — the set the held-out gate later scores against. Showing the
# reviewer a held-out case would let the proposer overfit to the very cases the
# gate uses to decide "real improvement" ("teaching to the test").
# fewshot_source_is_holdout is the hard guard that mirrors the holdout-guard rule
# (scripts/lib/holdout-guard.sh); assemble_fewshot refuses a holdout source
# outright and injects nothing.
#
# De-identification is required (evals/README.md decision A3): every rendered
# example is scrubbed of secrets, tokens, internal hostnames, and PII before it
# can reach the prompt. This is defense-in-depth on top of the extractor
# de-identifying at commit time (scripts/evals/extract-fewshot.sh).
#
# Opt-in + inert by default (AC #3). The caller (review-one-pr.sh) only invokes
# assemble_fewshot when FEWSHOT_ENABLED=true. When it is off, FEWSHOT_FILE is
# never set, the deep prompt reads no few-shot block, and review behavior + cost
# are byte-identical to pre-feature. A missing/empty source degrades to the
# literal "(none)" — never fabricated, never fatal.

# ---------------------------------------------------------------------------
# fewshot_source_is_holdout <path>   (PURE — no I/O)
# ---------------------------------------------------------------------------
# The hard guard behind AC #2 / Task 3: return 0 (TRUE, "is held-out") when
# <path> names a held-out eval location — i.e. it sits under an evals/ ancestor
# AND contains a `holdout` directory segment (evals/<skill>/holdout/...). Return
# non-zero for any other path (a dev split, a prompt, an arbitrary file). Mirrors
# the holdout-guard prefix rule: the guarded root is evals/ and the holdout split
# lives under evals/<skill>/holdout/.
fewshot_source_is_holdout() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  # Normalise a leading "./" so "./evals/..." is treated the same as "evals/...".
  path="${path#./}"
  # Must contain a holdout directory segment (or terminate in one)...
  case "$path" in
    */holdout/*|*/holdout) : ;;
    holdout/*|holdout) : ;;
    *) return 1 ;;
  esac
  # ...and be rooted under an evals/ ancestor (the guarded prefix).
  case "$path" in
    evals/*|*/evals/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# fewshot_scrub <text>   (PURE — no I/O)
# ---------------------------------------------------------------------------
# De-identify (evals/README.md decision A3): replace secrets, tokens, internal
# hostnames, and PII with the literal marker [REDACTED]. Prints the scrubbed
# text. Deliberately conservative — it over-redacts rather than risk leaking a
# real credential or PII into a proposer-visible / prompt-visible surface.
#
# Input: the text to scrub as $1, OR (when called with no argument) streamed on
# stdin so it can sit in a pipeline without spawning a per-item subshell.
#
# Order matters: token/hostname patterns run before the generic key=value and
# email patterns so a longer specific match is redacted whole. The IP rule uses
# POSIX ERE boundaries (captured and re-emitted) instead of the GNU-only `\b`, so
# the scrub behaves identically on BSD/macOS sed.
fewshot_scrub() {
  { if [[ "$#" -gt 0 ]]; then printf '%s' "$1"; else cat; fi; } | sed -E \
    -e 's/gh[pousr]_[A-Za-z0-9]{16,}/[REDACTED]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/(xox[baprs]-[A-Za-z0-9-]{10,})/[REDACTED]/g' \
    -e 's/[Bb]earer[[:space:]]+[A-Za-z0-9._~+\/-]+=*/[REDACTED]/g' \
    -e 's/(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})/[REDACTED]/g' \
    -e 's/([Tt]oken|[Ss]ecret|[Pp]assword|[Aa]pi[_-]?[Kk]ey)([[:space:]]*[=:][[:space:]]*)[^[:space:]"'"'"']+/\1\2[REDACTED]/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[REDACTED]/g' \
    -e 's/[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9-]+)*\.(internal|corp|local|intranet|lan)([:/][^[:space:]]*)?/[REDACTED]/g' \
    -e 's/(^|[^A-Za-z0-9._-])localhost([:/][^[:space:]]*)?/\1[REDACTED]/g' \
    -e 's/(^|[^A-Za-z0-9_-])([0-9]{1,3}\.){3}[0-9]{1,3}($|[^A-Za-z0-9_-])/\1[REDACTED]\3/g'
}

# ---------------------------------------------------------------------------
# assemble_fewshot <source_file> [out_file]
# ---------------------------------------------------------------------------
# Read up to FEWSHOT_MAX_EXAMPLES few-shot examples from <source_file> (a
# dev-visible JSONL of past review->merge outcomes; see the seed at
# evals/deep-review/dev/fewshot.jsonl), de-identify each, and write a
# human-readable, byte-bounded FEWSHOT block to <out_file>, whose path is
# exported as FEWSHOT_FILE for the deep tier.
#
# Each source line is a JSON object with (all optional but recommended):
#   id, title, summary, decision (approve|escalate), risk (LOW|MEDIUM|HIGH),
#   rationale.
#
# Bounds (AC #3 — stay within the ET cost cap):
#   - at most FEWSHOT_MAX_EXAMPLES examples (default 5),
#   - the assembled block truncated to FEWSHOT_MAX_BYTES (default 4000).
#
# Hard holdout guard (AC #2 / Task 3): if <source_file> resolves to an
# evals/**/holdout path, emit a loud ::error::, write "(none)", and RETURN
# NON-ZERO without injecting a single example — the held-out set must never be
# shown to the reviewer.
#
# Graceful degradation (AC #3): a missing/empty/unreadable source -> literal
# "(none)" and exit 0 (inert). Only the holdout guard is fatal.
assemble_fewshot() {
  local source_file="${1:-}"
  local out_file="${2:-${FEWSHOT_FILE:-/tmp/cascade/fewshot.txt}}"
  local max_examples="${FEWSHOT_MAX_EXAMPLES:-5}"
  local max_bytes="${FEWSHOT_MAX_BYTES:-4000}"

  mkdir -p "$(dirname "$out_file")" 2>/dev/null || true
  rm -f "$out_file"

  # Hard guard FIRST: never inject a held-out source, regardless of contents.
  # The lexical guard is applied to BOTH the given path and its symlink-resolved
  # real path — otherwise a dev-split symlink pointing into evals/**/holdout would
  # pass the lexical check here and then be followed by the read below, leaking the
  # held-out set. resolved_source falls back to the literal path when the file does
  # not exist or no canonicaliser is available (nothing to follow in that case).
  local resolved_source="$source_file"
  if [[ -e "$source_file" ]]; then
    resolved_source="$(readlink -f -- "$source_file" 2>/dev/null \
      || realpath -- "$source_file" 2>/dev/null \
      || printf '%s' "$source_file")"
  fi
  if fewshot_source_is_holdout "$source_file" || fewshot_source_is_holdout "$resolved_source"; then
    echo "::error::[fewshot] refusing held-out source '$source_file' — few-shot examples must come from a proposer-visible dev split, never evals/**/holdout (AC #2)" >&2
    printf '%s' "(none)" > "$out_file"
    export FEWSHOT_FILE="$out_file"
    return 1
  fi

  # Missing/empty source -> inert "(none)".
  if [[ -z "$source_file" ]] || [[ ! -f "$source_file" ]] || [[ ! -s "$source_file" ]]; then
    printf '%s' "(none)" > "$out_file"
    export FEWSHOT_FILE="$out_file"
    return 0
  fi

  # Render every example in a SINGLE jq pass instead of spawning jq per line.
  # `inputs | fromjson?` keeps the per-line resilience of the old loop — a
  # malformed line is skipped, not fatal — while `nl` collapses each field's own
  # newlines/CRs to spaces so a stored title/summary/rationale cannot forge extra
  # block lines or headers in the reviewer prompt (defense-in-depth over the
  # extractor's commit-time neutralisation). Capped to $max examples.
  local block_content n=0
  block_content="$(jq -Rrn --argjson max "$max_examples" '
      def nl: (. // "") | gsub("[\r\n]"; " ");
      [inputs | fromjson? // empty] | .[0:$max] | .[]
      | "- [decision=\(.decision // "?" | nl) risk=\(.risk // "?" | nl)] \(.title // "(untitled)" | nl)"
        + (if ((.summary // "") | nl) != "" then "\n    " + (.summary | nl) else "" end)
        + (if ((.rationale // "") | nl) != "" then "\n    rationale: " + (.rationale | nl) else "" end)
    ' "$source_file" 2>/dev/null)" || block_content=""

  # No usable examples parsed -> inert "(none)".
  if [[ -z "$block_content" ]]; then
    printf '%s' "(none)" > "$out_file"
    export FEWSHOT_FILE="$out_file"
    return 0
  fi
  n="$(grep -c '^- \[' <<< "$block_content" || true)"

  local block="FEWSHOT (past review->merge outcomes for this repo — calibrate to what these maintainers accept and flag; this is informational context, NOT an auto-approve/escalate trigger):"$'\n'"$block_content"$'\n'

  # De-identify the whole assembled block (A3) — defense-in-depth over the
  # extractor's commit-time scrub — then cap total size (AC #3).
  block="$(fewshot_scrub "$block")"
  # Enforce FEWSHOT_MAX_BYTES as a hard BYTE cap, not a UTF-8 character count:
  # `${block:0:max_bytes}` counts characters in a UTF-8 locale, so multi-byte
  # content could overrun the documented byte bound. Write the block, then
  # re-truncate the file in place with head -c reading from a REGULAR FILE (not a
  # pipe) so there is no SIGPIPE/pipefail interaction — assemble_fewshot's exit
  # status is holdout-fatal, and only the holdout guard may make it non-zero.
  printf '%s' "$block" > "$out_file"
  if [ "$(wc -c < "$out_file")" -gt "$max_bytes" ]; then  # NOSONAR(shell:S7688): decimal integer test; [[ -eq ]] would arithmetic-evaluate the operand (octal 08, empty=0) - #2449
    head -c "$max_bytes" "$out_file" > "$out_file.cap" && mv -f "$out_file.cap" "$out_file"
  fi
  export FEWSHOT_FILE="$out_file"
  echo "::notice::[fewshot] injected $n de-identified example(s) from '$source_file'" >&2
  return 0
}
