#!/usr/bin/env bash
# validate-interaction-model.sh — mechanical enforcement of the agentic
# interaction model (Story 4 / #1406, epic #1402).
#
# docs/agentic-interaction-model.md is a NORMATIVE repo-local standard: it fixes
# the three trigger classes (§2/§3), the timer contract (§6), the GITHUB_TOKEN
# event-boundary rule + its sanctioned bridges (§5), and a machine-checkable §4
# classification table. Story 2 (#1404) turned each role's interaction pattern
# into a machine-readable contract (personas/<id>/interaction.yml and
# interaction-contracts/<name>.yml). This script makes the standard and the
# contracts CI-enforced (§10) rather than review-enforced, so drift and unsafe
# additions are caught at PR time instead of surfacing as runaways.
#
# It is PURE / HERMETIC (reads in-repo files only, no network, no gh, no schema
# fetch), mirroring scripts/validate-workflow-schedules.sh and
# scripts/caller_stub_freeze.sh, so it runs in CI without credentials. Every scan
# helper is sourceable and unit-testable; main is thin I/O.
#
# It reports EVERY violation it finds (it never short-circuits on the first) so a
# single workflow tripping several rules surfaces all of them.
#
# Violation classes (tagged in output for grep-ability):
#   FAIL[a]     — an in-scope workflow has no §4 classification row (or a duplicate
#                 row). Adding a new agentic role without declaring it fails here.
#   FAIL[b]     — a Class-2 (scheduled interaction-family) row carries no valid
#                 timer_role (empty, `driver`, or anything outside
#                 backstop|safety-net|self-heal).
#   FAIL[c]     — a role's interaction contract diverges from its workflow's real
#                 on: block (declared events/timers != actual events/schedules).
#   FAIL[d]     — an interaction contract lacks an idempotency_key or a
#                 concurrency_lane.
#   FAIL[e]     — an agent->agent chain crosses the GITHUB_TOKEN boundary via a
#                 suppressed event without a declared repository_dispatch bridge.
#   FAIL[stop]  — a persona interaction contract's stop_markers over- or
#                 under-claim what a serving surface honours (#1745): it omits the
#                 canonical human brake (needs-human-review), or it declares a
#                 marker no serving workflow checks. Markers are derived from the
#                 serving scripts, never re-listed as literals here.
#   FAIL[class] — a §4 row's asserted Class contradicts the workflow's real on:
#                 block via the §3 discriminator (both misclassification
#                 directions).
#   FAIL[table] — a §4 row names a workflow that does not exist on disk.
#
# Usage: validate-interaction-model.sh
#   INTERACTION_MODEL_ROOT — repo root to scan (default: the repo containing this
#                            script). Overridden by tests to point at fixture trees.

set -euo pipefail

VALID_TIMER_ROLES=" backstop safety-net self-heal "

# ── §3 discriminator primitives ──────────────────────────────────────────────

# imv_norm_timer_role <value> — echo the normalized timer_role: empty for an
# absent role (`—`, en-dash, `-`, `N/A`, whitespace), the trimmed value otherwise.
imv_norm_timer_role() {
  local v
  v="$(printf '%s' "${1:-}" | tr -d '[:space:]')"
  case "$v" in
    ""|"—"|"–"|"-"|"N/A"|"n/a"|"NA"|"na") printf '' ;;
    *) printf '%s' "$v" ;;
  esac
}

# imv_valid_timer_role <value> — return 0 iff <value> is one of the §6.1 roles.
imv_valid_timer_role() {
  case "$VALID_TIMER_ROLES" in
    *" ${1:-} "*) return 0 ;;
  esac
  return 1
}

# ── on: block parsing (S / E signals) ────────────────────────────────────────

# imv_on_signals <file> — emit one line per top-level on: trigger:
#   SCHEDULE                              (a schedule.cron trigger is present)
#   EVENT <name>                          (a webhook event that represents work;
#                                          repository_dispatch is expanded to
#                                          EVENT repository_dispatch:<type>)
# workflow_dispatch and workflow_call are neither S nor E (a manual escape hatch
# and a reusable entrypoint — §3). Pure: reads the file, writes stdout.
imv_on_signals() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  awk '
    BEGIN { inon=0; topkey=""; in_rd_types=0; rd_had_types=0 }
    # inline array form: on: [push, pull_request]
    /^on:[[:space:]]*\[/ {
      s=$0; sub(/^on:[[:space:]]*\[/,"",s); sub(/\].*/,"",s);
      n=split(s,a,",");
      for (i=1;i<=n;i++) { gsub(/[[:space:]"\\047]/,"",a[i]);
        if (a[i]=="schedule") print "SCHEDULE";
        else if (a[i]!="" && a[i]!="workflow_dispatch" && a[i]!="workflow_call") print "EVENT " a[i] }
      next
    }
    # inline scalar form: on: push
    /^on:[[:space:]]*[A-Za-z_]/ {
      s=$0; sub(/^on:[[:space:]]*/,"",s); sub(/[[:space:]#].*/,"",s);
      if (s=="schedule") print "SCHEDULE";
      else if (s!="" && s!="workflow_dispatch" && s!="workflow_call") print "EVENT " s;
      next
    }
    # block form
    /^on:/ { inon=1; next }
    inon && /^[A-Za-z_]/ {
      if (topkey=="repository_dispatch" && !rd_had_types) print "EVENT repository_dispatch"
      inon=0; in_rd_types=0; rd_had_types=0; topkey=""
    }
    inon {
      if ($0 ~ /^  [A-Za-z_]+:/) {
        key=$0; sub(/^  /,"",key); sub(/:.*/,"",key);
        if (topkey=="repository_dispatch" && !rd_had_types) print "EVENT repository_dispatch"
        topkey=key; in_rd_types=0; rd_had_types=0;
        if (key=="schedule") print "SCHEDULE";
        else if (key=="workflow_dispatch" || key=="workflow_call" || key=="repository_dispatch") { }
        else print "EVENT " key;
        next
      }
      if (topkey=="repository_dispatch" && $0 ~ /types:[[:space:]]*\[/) {
        s=$0; sub(/.*\[/,"",s); sub(/\].*/,"",s);
        n=split(s,a,",");
        for (i=1;i<=n;i++) { gsub(/[[:space:]"\\047]/,"",a[i]); if (a[i]!="") print "EVENT repository_dispatch:" a[i] }
        rd_had_types=1; next
      }
      if (topkey=="repository_dispatch" && $0 ~ /types:[[:space:]]*$/) {
        in_rd_types=1; rd_had_types=1; next
      }
      if (in_rd_types) {
        if ($0 ~ /^[[:space:]]*-[[:space:]]/) {
          val=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",val); gsub(/[[:space:]"\\047]/,"",val);
          if (val!="") print "EVENT repository_dispatch:" val
          next
        } else { in_rd_types=0 }
      }
    }
    END {
      if (inon && topkey=="repository_dispatch" && !rd_had_types) print "EVENT repository_dispatch"
    }
  ' "$file"
}

# imv_on_has_schedule <file> — return 0 iff the on: block declares a schedule.
imv_on_has_schedule() {
  imv_on_signals "$1" | grep -q '^SCHEDULE$'
}

# imv_on_event_set <file> — print the sorted, unique set of webhook event tokens.
imv_on_event_set() {
  imv_on_signals "$1" | sed -n 's/^EVENT //p' | sort -u
}

# imv_on_crons <file> — print each schedule.cron string in the on: block (quotes
# and trailing comments stripped). Pure.
imv_on_crons() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  awk '
    /^on:/ { inon=1 }
    inon && /^[A-Za-z_]/ && !/^on:/ { inon=0 }
    inon && /^  schedule:/ { insch=1; next }
    insch && /^  [A-Za-z_]/ { insch=0 }
    insch && /cron:/ {
      s=$0; sub(/.*cron:[[:space:]]*/,"",s);
      sub(/#.*/,"",s); gsub(/[\047"]/,"",s);
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",s);
      if (s!="") print s
    }
  ' "$file"
}

# ── §4 classification table parsing ──────────────────────────────────────────

# imv_table_rows <md> — print `path<TAB>class<TAB>timer_role<TAB>role` for each §4
# data row (a table row whose first cell is a `.github/workflows/...` path). The
# path is the first backtick-delimited span of the first cell; the optional role
# is the trailing text after it — the ADR-0007 ingress convention, where one
# agent-ingress.yml contributes one row per collapsed role-job, each first cell
# shaped `` `path` (job-name) ``. A legacy single-role stub carries no qualifier,
# so its role field is empty. The header, separator, and the blockquoted
# exclusion table are ignored. Pure.
imv_table_rows() {
  local md="${1:-}"
  [ -n "$md" ] && [ -f "$md" ] || return 0
  awk -F'|' '
    $0 ~ "^\\|[[:space:]]*`\\.github/workflows/" {
      # first cell ($2): `path` optionally followed by a (role) qualifier
      path=$2; sub(/^[^`]*`/,"",path); sub(/`.*/,"",path); gsub(/[[:space:]]/,"",path);
      # role qualifier: accept ONLY the documented ` (job-name) ` form, or no
      # qualifier at all. Any other trailing text is malformed and is tagged
      # __invalid__ so completeness reports it instead of silently accepting it.
      role=$2; sub(/^[^`]*`[^`]*`/,"",role);
      if (role ~ /^[[:space:]]*\([A-Za-z0-9_-]+\)[[:space:]]*$/) {
        sub(/^[[:space:]]*\(/,"",role); sub(/\)[[:space:]]*$/,"",role);
      } else {
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",role);
        if (role != "") role="__invalid__" role;
      }
      cls=$3;  gsub(/[[:space:]]/,"",cls);
      tr=$4;   gsub(/^[[:space:]]+|[[:space:]]+$/,"",tr);
      print path "\t" cls "\t" tr "\t" role
    }
  ' "$md"
}

# imv_wf_jobs <file> — print each top-level job name (a key indented under
# the `jobs:` block, at the same indentation as the first job). For an ADR-0007
# agent-ingress.yml this is one name per collapsed role-job, the unit the §4
# completeness check counts rows against. Pure: reads the file, writes stdout.
imv_wf_jobs() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  awk '
    /^jobs:[[:space:]]*(#.*)?$/ { inj=1; job_indent=""; next }
    inj && /^[A-Za-z_]/ { inj=0 }
    # A job key may be an unquoted scalar or a quoted YAML scalar ("dev-lead":).
    # Strip surrounding quote delimiters so a quoted key compares like a bare one.
    inj && job_indent == "" && /^[[:space:]]+("[^"]+"|\047[^\047]+\047|[A-Za-z0-9_-]+):[[:space:]]*(#.*)?$/ {
      match($0, /^[[:space:]]+/);
      job_indent = substr($0, RSTART, RLENGTH);
      k=$0; sub(/^[[:space:]]+/,"",k); sub(/:[[:space:]]*(#.*)?$/,"",k);
      gsub(/^["\047]|["\047]$/,"",k); print k;
      next
    }
    inj && job_indent != "" && $0 ~ /^[[:space:]]+("[^"]+"|\047[^\047]+\047|[A-Za-z0-9_-]+):[[:space:]]*(#.*)?$/ {
      indent = ""; match($0, /^[[:space:]]+/); indent = substr($0, RSTART, RLENGTH);
      if (indent == job_indent) {
        k=$0; sub(/^[[:space:]]+/,"",k); sub(/:[[:space:]]*(#.*)?$/,"",k);
        gsub(/^["\047]|["\047]$/,"",k); print k
      }
    }
  ' "$file"
}

# imv_table_exclusions <md> — print each `.github/workflows/...` path listed in
# the §4 blockquoted exclusion table. Pure.
imv_table_exclusions() {
  local md="${1:-}"
  [ -n "$md" ] && [ -f "$md" ] || return 0
  awk '
    $0 ~ "^>[[:space:]]*\\|[[:space:]]*`\\.github/workflows/" {
      s=$0; sub(/^[^`]*`/,"",s); sub(/`.*/,"",s); print s
    }
  ' "$md"
}

# ── interaction-contract parsing ─────────────────────────────────────────────

# imv_contract_files <root> — print every interaction contract path under <root>.
imv_contract_files() {
  local root="${1:-}"
  { find "$root/personas" -maxdepth 2 -type f -name 'interaction.yml' 2>/dev/null
    find "$root/interaction-contracts" -maxdepth 1 -type f -name '*.yml' 2>/dev/null
  } | sort
}

# imv_c_role <file> — the contract's top-level role value.
imv_c_role() {
  awk '/^role:/ { sub(/^role:[[:space:]]*/,""); gsub(/[\047"]/,""); print; exit }' "$1"
}

# imv_c_workflows <file> — the contract's declared workflow paths, one per line.
imv_c_workflows() {
  awk '
    /^workflows:/ { f=1; next }
    f && /^  - / { v=$0; sub(/^  - /,"",v); gsub(/[\047"]/,"",v); gsub(/[[:space:]]+$/,"",v); print v; next }
    f && /^[A-Za-z_]/ { f=0 }
  ' "$1"
}

# imv_c_events <file> — the contract's declared triggers.events, one per line.
imv_c_events() {
  awk '
    /^    events:/ { f=1; next }
    f && /^      - / { v=$0; sub(/^      - /,"",v); gsub(/[\047"]/,"",v); gsub(/[[:space:]]+$/,"",v); print v; next }
    f && /^    [A-Za-z]/ { f=0 }
    f && /^  [A-Za-z]/ { f=0 }
    f && /^[A-Za-z]/ { f=0 }
  ' "$1"
}

# imv_c_timer_crons <file> — the cron string of each declared timer.
imv_c_timer_crons() {
  awk '
    /^    timers:/ { f=1; next }
    f && /cron:/ { v=$0; sub(/.*cron:[[:space:]]*/,"",v); sub(/#.*/,"",v); gsub(/[\047"]/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); if (v!="") print v }
    f && /^  [A-Za-z]/ { f=0 }
    f && /^[A-Za-z]/ { f=0 }
  ' "$1"
}

# imv_c_emits <file> — the contract's declared emits, one per line.
imv_c_emits() {
  awk '
    /^  emits:/ { f=1; next }
    f && /^    - / { v=$0; sub(/^    - /,"",v); gsub(/[\047"]/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; next }
    f && /^  [A-Za-z]/ { f=0 }
    f && /^[A-Za-z]/ { f=0 }
  ' "$1"
}

# imv_c_kind <file> — the contract's top-level kind value (persona | runtime).
imv_c_kind() {
  awk '/^kind:/ { sub(/^kind:[[:space:]]*/,""); gsub(/[\047"]/,""); print; exit }' "$1"
}

# imv_c_stop_markers <file> — the contract's declared interaction.stop_markers,
# one per line. Handles the block-list form and the inline-list form
# (`stop_markers: [a, b]`); an inline empty list (`[]`) yields nothing.
imv_c_stop_markers() {
  awk '
    /^  stop_markers:[[:space:]]*\[/ {
      v=$0; sub(/^  stop_markers:[[:space:]]*\[/,"",v); sub(/\].*/,"",v);
      n=split(v, a, ",");
      for (i=1;i<=n;i++) {
        s=a[i]; gsub(/[\047"]/,"",s); gsub(/^[[:space:]]+|[[:space:]]+$/,"",s);
        if (s!="") print s;
      }
      next
    }
    /^  stop_markers:/ { f=1; next }
    f && /^    - / { v=$0; sub(/^    - /,"",v); gsub(/[\047"]/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; next }
    f && /^  [A-Za-z]/ { f=0 }
    f && /^[A-Za-z]/ { f=0 }
  ' "$1"
}

# imv_c_field <file> <key> — the trimmed (quote-stripped) value of a 2-space
# indented interaction.<key> scalar (e.g. idempotency_key, concurrency_lane).
imv_c_field() {
  awk -v k="$2" '
    $0 ~ "^  " k ":" {
      v=$0; sub("^  " k ":[[:space:]]*","",v);
      gsub(/[\047"]/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v);
      print v; exit
    }
  ' "$1"
}

# ── serving-side stop-marker derivation (§6.2.3, #1745) ──────────────────────
#
# The stop-marker checks must reuse the CANONICAL definition of the escalation
# markers rather than re-listing literals (issue #1745 AC #2). The two sources of
# truth live in the serving scripts:
#   - needs-human-review  ← NEEDS_HUMAN_REVIEW_LABEL in scripts/lib/pr-automation-budget.sh
#                           (the label pr_has_escalation_label checks — the event
#                           surface's canonical human brake)
#   - dev-lead:needs-human ← DEV_LEAD_NEEDS_HUMAN_LABEL in scripts/qa-lead-advisory-gate.sh
# They are parsed from the scripts' `: "${VAR:=default}"` declarations so a rename
# there propagates here — never duplicated as literals in this validator.

# imv_serving_scripts_dir — the directory holding the serving scripts this
# validator derives markers from. Resolves to this script's own dir (scripts/),
# independent of INTERACTION_MODEL_ROOT, so fixture trees need not ship the
# scripts. Overridable via INTERACTION_MODEL_SCRIPTS_DIR for isolated tests.
imv_serving_scripts_dir() {
  if [ -n "${INTERACTION_MODEL_SCRIPTS_DIR:-}" ]; then
    printf '%s' "$INTERACTION_MODEL_SCRIPTS_DIR"
  else
    (cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi
}

# imv_escalation_label_from <file> <VARNAME> — echo the default value of a
# `: "${VARNAME:=default}"` shell assignment in <file>. Empty if absent.
imv_escalation_label_from() {
  local file="${1:-}" var="${2:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  awk -v v="$var" '
    index($0, v ":=") > 0 {
      s=$0; sub(/.*:=/,"",s); sub(/}.*/,"",s); gsub(/[\047"]/,"",s);
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",s);
      if (s!="") { print s; exit }
    }
  ' "$file"
}

# imv_needs_human_review_label — the canonical universal human brake.
imv_needs_human_review_label() {
  imv_escalation_label_from "$(imv_serving_scripts_dir)/lib/pr-automation-budget.sh" NEEDS_HUMAN_REVIEW_LABEL
}

# imv_canonical_escalation_markers — the persona-agnostic human-brake set the
# serving side honours, one per line (needs-human-review, dev-lead:needs-human).
imv_canonical_escalation_markers() {
  local dir; dir="$(imv_serving_scripts_dir)"
  imv_escalation_label_from "$dir/lib/pr-automation-budget.sh" NEEDS_HUMAN_REVIEW_LABEL
  imv_escalation_label_from "$dir/qa-lead-advisory-gate.sh" DEV_LEAD_NEEDS_HUMAN_LABEL
}

# imv_persona_opt_out <root> <role> — the opt_out_label declared in the persona's
# manifest (personas/<role>/persona.yml); the router's opt-out check honours it.
# Empty if the manifest or the field is absent.
imv_persona_opt_out() {
  local root="${1:-}" role="${2:-}" pf
  pf="$root/personas/$role/persona.yml"
  [ -f "$pf" ] || return 0
  awk '
    /^[[:space:]]*opt_out_label:/ {
      v=$0; sub(/.*opt_out_label:[[:space:]]*/,"",v); gsub(/[\047"]/,"",v);
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit
    }
  ' "$pf"
}

# imv_persona_serves_pr_surface <root> <role> — return 0 iff the persona's manifest
# (personas/<role>/persona.yml) declares a `pull_request` surface with
# `enabled: true` and at least one declared event the router subscribes (opened,
# ready_for_review, reopened). The shared persona-mention router derives which personas it
# dispatches on the pull_request EVENT from exactly these manifest surfaces (#1165,
# #2187), so only such a persona is served pull_request by the router.
imv_persona_serves_pr_surface() {
  local root="${1:-}" role="${2:-}" pf
  pf="$root/personas/$role/persona.yml"
  [ -f "$pf" ] || return 1
  awk '
    function flush() { if (cur == "pull_request" && en && ov) found=1; cur=""; en=0; ov=0 }
    /^[A-Za-z_]/ { flush() }   # a top-level key ends the surfaces list
    /^[[:space:]]*-[[:space:]]*surface:/ {
      flush()
      s=$0; sub(/.*surface:[[:space:]]*/,"",s); gsub(/[\047"]/,"",s); sub(/[[:space:]#].*/,"",s)
      cur=s; next
    }
    cur == "pull_request" && /^[[:space:]]*events:/ {
      # only the actions the router subscribes (opened, ready_for_review, reopened) count
      if ($0 ~ /[^A-Za-z_](opened|ready_for_review|reopened)[^A-Za-z_]/) ov=1
    }
    cur == "pull_request" && /^[[:space:]]*enabled:[[:space:]]*true([[:space:]#]|$)/ { en=1 }
    END { flush(); exit found ? 0 : 1 }
  ' "$pf"
}

# ── detectors (each prints tagged FAIL lines; none aborts on first finding) ───

# imv_v_completeness <root> <md> — bidirectional §4 completeness (§10). Every
# in-scope .github/workflows/*.yml (not on the exclusion list) must be classified:
#   - a regular single-role workflow: exactly one §4 row (FAIL[a] if it has none);
#   - an ADR-0007 agent-ingress.yml: one row per collapsed role-job — the set of
#     row role-qualifiers must equal the file's set of job names, so an
#     under-documented ingress (a job with no row) FAIL[a]s and a stale row naming
#     a job that no longer exists FAIL[table]s. Each per-role row is still
#     classified against the shared on: block by imv_v_class.
imv_v_completeness() {
  local root="$1" md="$2" f rel base
  local rows exclusions matching_rows count
  rows="$(imv_table_rows "$md")"
  exclusions="$(imv_table_exclusions "$md")"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$root/"}"
    if printf '%s\n' "$exclusions" | grep -qxF "$rel"; then continue; fi
    base="$(basename "$rel")"
    if [ "$base" = "agent-ingress.yml" ]; then
      imv_v_completeness_ingress "$f" "$rel" "$rows"
    else
      # For regular workflows: count rows with this path and no role qualifier
      matching_rows="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$rel" '$1==p && $4~/^[[:space:]]*$/ {print}')"
      count=$(printf '%s' "$matching_rows" | grep -c . || true)
      if [ "$count" -eq 0 ]; then
        printf 'FAIL[a]: %s is an in-scope workflow with no §4 classification row (declare it in docs/agentic-interaction-model.md §4, or add it to the exclusion list).\n' "$rel"
      elif [ "$count" -gt 1 ]; then
        printf 'FAIL[a]: %s is a regular workflow with multiple §4 classification rows — each workflow must have exactly one row (§10).\n' "$rel"
      fi
    fi
  done < <(find "$root/.github/workflows" -maxdepth 1 -type f -name '*.yml' 2>/dev/null | sort)
}

# imv_v_completeness_ingress <file> <rel> <rows> — per-job completeness for a
# collapsed ADR-0007 ingress: the set of §4 row role-qualifiers naming <rel> must
# equal <file>'s job names. FAIL[a] a job with no row; FAIL[table] a row-role that
# names no job. Called by imv_v_completeness; <rows> is imv_table_rows output.
imv_v_completeness_ingress() {
  local file="$1" rel="$2" rows="$3" jobs roles job role roles_raw roles_dedup blank_count
  jobs="$(imv_wf_jobs "$file" | sort -u)"
  # An ingress row must name its role-job. Inspect ALL rows for this path before
  # filtering blanks — a blank/whitespace-only qualifier is malformed and must
  # FAIL[a], else a complete set of qualified rows plus one blank row would pass.
  blank_count="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$rel" '$1==p && $4~/^[[:space:]]*$/ {c++} END{print c+0}')"
  if [ "$blank_count" -gt 0 ]; then
    printf 'FAIL[a]: %s has %s §4 row(s) with a blank role qualifier — every collapsed ingress row must name its role-job (see the §4 ingress convention).\n' "$rel" "$blank_count"
  fi
  roles_raw="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$rel" '$1==p && $4!~/^[[:space:]]*$/ {print $4}')"
  roles_dedup="$(printf '%s' "$roles_raw" | sort -u)"
  # Check for duplicate role qualifiers (same role appearing more than once)
  if [ -n "$roles_raw" ] && [ "$(printf '%s' "$roles_raw" | grep -c . || true)" -gt "$(printf '%s' "$roles_dedup" | grep -c . || true)" ]; then
    while IFS= read -r role; do
      [ -n "$role" ] || continue
      count=$(printf '%s' "$roles_raw" | grep -c "^${role}$" || true)
      if [ "$count" -gt 1 ]; then
        printf 'FAIL[a]: %s has multiple §4 rows for role %s — each role-job must have exactly one row (§10).\n' "$rel" "$role"
      fi
    done <<< "$roles_dedup"
  fi
  roles="$roles_dedup"
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    if ! printf '%s\n' "$roles" | grep -qxF "$job"; then
      printf 'FAIL[a]: %s job %s is a collapsed ingress role with no §4 classification row — add one row per role-job (see the §4 ingress convention).\n' "$rel" "$job"
    fi
  done <<< "$jobs"
  while IFS= read -r role; do
    [ -n "$role" ] || continue
    if ! printf '%s\n' "$jobs" | grep -qxF "$role"; then
      printf 'FAIL[table]: §4 row %s (%s) names an ingress role that is not a job in the file — remove the stale row (§10).\n' "$rel" "$role"
    fi
  done <<< "$roles"
}

# imv_v_timer_roles <md> — FAIL[b] for every Class-2 row lacking a valid timer_role.
imv_v_timer_roles() {
  local md="$1" path cls tr role trn
  while IFS=$'\t' read -r path cls tr role; do
    [ -n "$path" ] || continue
    [ "$cls" = "2" ] || continue
    trn="$(imv_norm_timer_role "$tr")"
    if [ -z "$trn" ] || ! imv_valid_timer_role "$trn"; then
      printf 'FAIL[b]: %s is Class 2 (a scheduled interaction-family timer) but its timer_role is %s — a Class-2 backstop must declare one of backstop|safety-net|self-heal (§6.1).\n' \
        "$path" "${trn:-<none>}"
    fi
  done < <(imv_table_rows "$md")
}

# imv_v_class <root> <md> — FAIL[table] for a row naming a missing workflow, and
# FAIL[class] when a row's asserted Class contradicts the workflow's real on:
# block via the §3 discriminator.
imv_v_class() {
  local root="$1" md="$2" path cls tr role trn wf S
  while IFS=$'\t' read -r path cls tr role; do
    [ -n "$path" ] || continue
    wf="$root/$path"
    if [ ! -f "$wf" ]; then
      printf 'FAIL[table]: §4 row names %s, which does not exist on disk — remove the stale row (§10).\n' "$path"
      continue
    fi
    trn="$(imv_norm_timer_role "$tr")"
    if imv_on_has_schedule "$wf"; then S=1; else S=0; fi
    case "$cls" in
      1)
        if [ "$S" = "1" ]; then
          printf 'FAIL[class]: %s is asserted Class 1 but its on: block has a schedule — a Class-1 event reaction must not carry a cron (§2/§3).\n' "$path"
        fi
        if [ -n "$trn" ]; then
          printf 'FAIL[class]: %s is asserted Class 1 but declares timer_role %s — Class 1 carries no timer_role (§3).\n' "$path" "$trn"
        fi
        ;;
      2)
        if [ "$S" = "0" ]; then
          printf 'FAIL[class]: %s is asserted Class 2 but its on: block has no schedule — a Class-2 backstop is defined by its reconciliation timer (§2/§3).\n' "$path"
        fi
        ;;
      3)
        if [ "$S" = "0" ]; then
          printf 'FAIL[class]: %s is asserted Class 3 but its on: block has no schedule — a Class-3 origin is the cadence (§2/§3).\n' "$path"
        fi
        if [ -n "$trn" ]; then
          printf 'FAIL[class]: %s is asserted Class 3 but declares timer_role %s — a Class-3 report/canary carries no timer_role (§6.1).\n' "$path" "$trn"
        fi
        ;;
      *)
        printf 'FAIL[class]: %s has an unrecognized Class %s — must be 1, 2, or 3 (§2).\n' "$path" "${cls:-<none>}"
        ;;
    esac
  done < <(imv_table_rows "$md")
}

# imv_v_contracts <root> — FAIL[c] when a contract's declared triggers diverge
# from the union of its workflows' real on: blocks; FAIL[d] when a contract lacks
# an idempotency_key or a concurrency_lane.
imv_v_contracts() {
  local root="$1" c rel wf actual_events actual_crons decl_events decl_crons
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    rel="${c#"$root/"}"

    actual_events=""; actual_crons=""
    while IFS= read -r wf; do
      [ -n "$wf" ] || continue
      # The shared persona-mention router's on: block also carries the
      # pull_request EVENT surface (#2187), but the router dispatches a persona on
      # it only when that persona's manifest enables a pull_request surface. A
      # mention-only persona is not served pull_request by the router, so its
      # contract is not charged with it.
      local role status=0
      role="$(imv_c_role "$c")" || status=$?
      if [ "$status" -eq 0 ] && [ "$wf" = ".github/workflows/persona-mention.yml" ] \
         && ! imv_persona_serves_pr_surface "$root" "$role"; then
        actual_events+="$(imv_on_event_set "$root/$wf" | grep -vx 'pull_request' || true)"$'\n'
      else
        actual_events+="$(imv_on_event_set "$root/$wf")"$'\n'
      fi
      actual_crons+="$(imv_on_crons "$root/$wf")"$'\n'
    done < <(imv_c_workflows "$c")

    actual_events="$(printf '%s' "$actual_events" | grep -v '^$' | sort -u || true)"
    actual_crons="$(printf '%s' "$actual_crons" | grep -v '^$' | sort -u || true)"
    decl_events="$(imv_c_events "$c" | grep -v '^$' | sort -u || true)"
    decl_crons="$(imv_c_timer_crons "$c" | grep -v '^$' | sort -u || true)"

    if [ "$decl_events" != "$actual_events" ]; then
      printf 'FAIL[c]: %s declares triggers.events {%s} but its workflows subscribe to {%s} — the contract must mirror the real on: block (§8.1/§10).\n' \
        "$rel" "$(printf '%s' "$decl_events" | paste -sd, -)" "$(printf '%s' "$actual_events" | paste -sd, -)"
    fi
    if [ "$decl_crons" != "$actual_crons" ]; then
      printf 'FAIL[c]: %s declares timer crons {%s} but its workflows schedule {%s} — the contract must mirror the real on: block (§8.1/§10).\n' \
        "$rel" "$(printf '%s' "$decl_crons" | paste -sd, -)" "$(printf '%s' "$actual_crons" | paste -sd, -)"
    fi

    if [ -z "$(imv_c_field "$c" idempotency_key)" ]; then
      printf 'FAIL[d]: %s declares no idempotency_key — an interaction driver must state what makes a re-run a no-op (§8.1).\n' "$rel"
    fi
    if [ -z "$(imv_c_field "$c" concurrency_lane)" ]; then
      printf 'FAIL[d]: %s declares no concurrency_lane — an interaction driver must state its serialization lane (§8.1).\n' "$rel"
    fi
  done < <(imv_contract_files "$root")
}

# imv_v_boundary <root> — FAIL[e] when one role emits a bare (suppressed) webhook
# event that a DIFFERENT role subscribes to, with no repository_dispatch bridge.
# GITHUB_TOKEN-authored suppressed events (push, …) never trigger a downstream
# workflow (§5); such a chain must cross the boundary via a sanctioned bridge.
imv_v_boundary() {
  local root="$1" c role ev emit sub_role sub_ev subs=""
  # Collect `role<TAB>bare-event` subscription pairs across all contracts.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    role="$(imv_c_role "$c")"
    while IFS= read -r ev; do
      case "$ev" in ""|*:*) continue ;; esac   # skip empties and prefixed (bridge) events
      subs+="${role}"$'\t'"${ev}"$'\n'
    done < <(imv_c_events "$c")
  done < <(imv_contract_files "$root")

  while IFS= read -r c; do
    [ -n "$c" ] || continue
    role="$(imv_c_role "$c")"
    while IFS= read -r emit; do
      case "$emit" in ""|*:*) continue ;; esac  # only bare emits (commit, push) can be a raw event
      while IFS=$'\t' read -r sub_role sub_ev; do
        [ -n "$sub_role" ] || continue
        [ -n "$sub_ev" ] || continue
        [ "$sub_ev" = "$emit" ] || continue
        [ "$sub_role" != "$role" ] || continue
        printf 'FAIL[e]: role %s emits the suppressed event %q that role %s subscribes to, with no repository_dispatch bridge — a GITHUB_TOKEN-authored %s never triggers a downstream workflow (§5).\n' \
          "$role" "$emit" "$sub_role" "$emit"
      done <<< "$subs"
    done < <(imv_c_emits "$c")
  done < <(imv_contract_files "$root")
}

# imv_v_stop_markers <root> — FAIL[stop] for a persona interaction contract whose
# stop_markers over- or under-claim what a serving surface actually honours (#1745).
#
# The serving side honours, for a persona:
#   - its own opt_out_label (personas/<id>/persona.yml) — the router's opt-out check;
#   - the canonical escalation markers (needs-human-review, dev-lead:needs-human).
# The mention router now reads a persona's stop_markers straight from this contract
# (petry-projects/.github#1133), so a marker declared here is what actually gates the
# mention surface — which is exactly why a claim that no serving workflow can honour,
# or a missing universal brake, is a real behavioural defect, not just tidiness.
#
# Two directions, both tagged FAIL[stop]:
#   under-claim — a persona whose stop_markers omit the universal human brake
#                 (needs-human-review) is routed on a mention even after a human
#                 applies it (the #1745 fail-open asymmetry).
#   over-claim  — a declared marker outside the honoured set is a contract that
#                 over-declares a stop marker no serving workflow checks (the
#                 mirror of #1647's over-declared surfaces).
# Only kind: persona contracts are in scope; runtime-lens contracts
# (interaction-contracts/*.yml) are the deployment view and declare their own
# stop sets tied to their own gate code.
imv_v_stop_markers() {
  local root="$1" c rel kind role brake canon opt_out honoured markers m
  brake="$(imv_needs_human_review_label)"
  canon="$(imv_canonical_escalation_markers)"

  # Fail closed when the canonical markers cannot be derived (e.g.
  # INTERACTION_MODEL_SCRIPTS_DIR points at a missing/incompatible serving-script
  # directory). Without this guard an empty brake silently disables the required
  # human-brake check, letting a persona pass without declaring it.
  if [ -z "$brake" ] || [ -z "$canon" ]; then
    printf 'FAIL[stop]: could not derive the canonical escalation markers from the serving scripts (%s) — the required human-brake check cannot run. Check INTERACTION_MODEL_SCRIPTS_DIR / scripts/lib/pr-automation-budget.sh and scripts/qa-lead-advisory-gate.sh (§6.2.3).\n' \
      "$(imv_serving_scripts_dir)"
    return 0
  fi

  while IFS= read -r c || [ -n "$c" ]; do
    [ -n "$c" ] || continue
    kind="$(imv_c_kind "$c")"
    [ "$kind" = "persona" ] || continue
    rel="${c#"$root/"}"
    role="$(imv_c_role "$c")"
    opt_out="$(imv_persona_opt_out "$root" "$role")"
    honoured="$(printf '%s\n%s\n' "$opt_out" "$canon" | grep -v '^$' | sort -u)"
    markers="$(imv_c_stop_markers "$c")"

    if [ -n "$brake" ] && ! printf '%s\n' "$markers" | grep -qxF "$brake"; then
      printf 'FAIL[stop]: %s omits the canonical human brake %q from stop_markers — the mention router reads this contract, so a human applying %q would not stop this persona there (§6.2.3; pr_has_escalation_label). Declare it.\n' \
        "$rel" "$brake" "$brake"
    fi

    while IFS= read -r m || [ -n "$m" ]; do
      [ -n "$m" ] || continue
      if ! printf '%s\n' "$honoured" | grep -qxF "$m"; then
        printf 'FAIL[stop]: %s declares stop_marker %q that no serving workflow honours — a persona honours only its opt_out_label (%s) and the canonical escalation markers {%s} (§6.2.3/§8.1). Remove it or wire a surface that checks it.\n' \
          "$rel" "$m" "${opt_out:-<none>}" "$(printf '%s' "$canon" | paste -sd, -)"
      fi
    done <<< "$markers"
  done < <(imv_contract_files "$root")
}

# ── main ─────────────────────────────────────────────────────────────────────

imv_repo_root() {
  if [ -n "${INTERACTION_MODEL_ROOT:-}" ]; then
    printf '%s' "$INTERACTION_MODEL_ROOT"
  else
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  fi
}

main() {
  local root md violations
  root="$(imv_repo_root)"
  md="$root/docs/agentic-interaction-model.md"

  if [ ! -f "$md" ]; then
    echo "::error::validate-interaction-model: standard not found at $md" >&2
    return 1
  fi

  violations="$(
    imv_v_completeness "$root" "$md"
    imv_v_timer_roles "$md"
    imv_v_class "$root" "$md"
    imv_v_contracts "$root"
    imv_v_boundary "$root"
    imv_v_stop_markers "$root"
  )"

  if [ -n "$violations" ]; then
    echo "" >&2
    echo "validate-interaction-model: FAIL — the agentic interaction model (docs/agentic-interaction-model.md) is violated:" >&2
    printf '%s\n' "$violations" >&2
    echo "" >&2
    echo "See docs/adding-an-agentic-role.md for the conforming shape." >&2
    return 1
  fi

  echo "validate-interaction-model: OK — §4 table, on: blocks, and interaction contracts all agree."
  return 0
}

# Only run main when executed directly, so tests can source the functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
