#!/usr/bin/env bash
# apply-plan.sh — materialize a validated initiative plan as a GitHub epic +
# sub-issue DAG. Honors DRY_RUN (see lib/mutations.sh).
#
# What it creates:
#   - 1 epic issue           labelled `initiative`
#   - N story sub-issues      labelled `initiative` (hands_off stories also get
#                             `dev-lead:hands-off` + `initiative:hold`)
#   - native sub-issue links  (each story under the epic)
#   - native blocked_by edges (intra-plan ordering + existing-issue prereqs)
#   - a summary comment back on the source Discussion
#
# What it deliberately does NOT do:
#   - apply `initiative:auto`. The epic is created INERT. A human reviews the
#     real epic/DAG and adds `initiative:auto` to hand it to initiative-driver.
#   - create a duplicate. If an OPEN `initiative` epic already back-references
#     this discussion, it is idempotent: by default it creates NOTHING and
#     points back at the existing epic. Set FORCE_REPLAN=1 to instead supersede
#     it — create the fresh epic/DAG, then CLOSE (never delete) the old epic and
#     its sub-issues with a "superseded by #NEW" note.
#
# Env:
#   REPO                 owner/repo (required)
#   PLAN_PATH            path to validated plan.json (required)
#   DISCUSSION_NUMBER    source discussion number (for the summary text)
#   DISCUSSION_NODE_ID   source discussion GraphQL node id (optional; if set,
#                        the plan summary is posted back as a comment)
#   DISCUSSION_REPO      owner/repo the source discussion lives in (default:
#                        REPO). Cross-repo (graduation: incubator idea, product
#                        repo epic) the epic back-reference becomes
#                        "owner/repo#N" and issue links in the Discussion
#                        comment are qualified with REPO so they resolve. The
#                        comment itself goes to the Discussion's own repo via
#                        its global node id.
#   FORCE_REPLAN         "1" => supersede an existing epic instead of no-op
#   DRY_RUN / DRY_RUN_LOG  see lib/mutations.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutations.sh
. "${SCRIPT_DIR}/lib/mutations.sh"

# _reconcile_key <src_discussion> <proposed_story_title>
# Deterministic idempotency key for a materialized proposed_story, stamped into
# its body as a `reconcile-key:` marker so a later reconcile-in-place pass (#708)
# can detect the story is already tracked and skip it (the reconcile diff against
# the existing DAG). Keyed on the source discussion + the exact proposed_story
# title, so re-harvesting the same follow-up never mints a duplicate sub-issue.
_reconcile_key() {
  printf '%s::%s' "$1" "$2" | sha256sum | cut -d' ' -f1
}

# materialize_accepted_findings <epic_number> <reconcile_flag>
# Reused by BOTH the plan-time path (#706) and the reconcile-in-place pass (#708),
# so materialization is defined ONCE. For every maintainer-accepted proposed_story
# finding it creates a sub-issue of <epic_number>, links it under the epic, wires
# the native proposed_blocked_by edge, and stamps a reconcile-key marker into the
# body. When <reconcile_flag>=1, a finding whose key already exists among the
# epic's sub-issues is skipped, so a reconcile re-run with no new signal is a clean
# no-op (zero create/edge ops). Sets MATERIALIZED_COUNT for the caller's summary.
MATERIALIZED_COUNT=0
materialize_accepted_findings() {
  local epic_number="$1" reconcile="${2:-0}"
  local existing_keys=""
  if [ "$reconcile" = "1" ]; then
    existing_keys="$(existing_reconcile_keys "$REPO" "$epic_number" || true)"
  fi
  MATERIALIZED_COUNT=0
  declare -A existing_keys_map=()
  while IFS= read -r k; do
    [[ -n "$k" ]] && existing_keys_map["$k"]=1
  done <<< "$existing_keys"
  local q_index ps_title rk ps_body ps_out ps_number ps_id pbb
  while IFS= read -r q_index; do
    [ -n "$q_index" ] || continue
    ps_title="$(jq -r --argjson i "$q_index" '.open_questions[$i].proposed_story.title' "$PLAN_PATH")"
    rk="$(_reconcile_key "${src:-0}" "$ps_title")"
    if [ "$reconcile" = "1" ] && [[ -n "${existing_keys_map["$rk"]:-}" ]]; then
      echo "  reconcile: proposed_story already materialized (key match) — skipping: ${ps_title}"
      continue
    fi
    ps_body="$(jq -r --argjson i "$q_index" '
      .open_questions[$i].proposed_story
      | "## Story\n" + .title
        + "\n\n## Acceptance Criteria\n"
        + ([.acceptance_criteria | to_entries[] | "\(.key + 1). \(.value)"] | join("\n"))
    ' "$PLAN_PATH")"
    ps_body="${ps_body}"$'\n\n'"_Materialized from a maintainer-accepted plan-critic finding for epic #${epic_number} (issue #706). Status: ready-for-dev._"$'\n'"<!-- reconcile-key: ${rk} -->"

    ps_out="$(create_issue "$REPO" "$ps_title" "$ps_body" "initiative")"
    read -r ps_number ps_id <<< "$ps_out"
    echo "  materialized proposed_story: #${ps_number} (id ${ps_id}) — ${ps_title}"
    link_sub_issue "$REPO" "$epic_number" "$ps_id"

    # proposed_blocked_by is the EXISTING issue this new story gates; wire it so
    # that issue becomes blocked_by the new story (the new story must land first).
    pbb="$(jq -r --argjson i "$q_index" '.open_questions[$i].proposed_blocked_by // empty' "$PLAN_PATH")"
    if [ -n "$pbb" ]; then
      add_blocked_by "$REPO" "$pbb" "$ps_number"
      echo "  edge: #${pbb} blocked_by materialized #${ps_number} (proposed_blocked_by)"
    fi
    MATERIALIZED_COUNT=$((MATERIALIZED_COUNT + 1))
  done < <(jq -r '(.open_questions // []) | to_entries[] | select(.value | type=="object") | select(.value?.accepted == true and .value?.proposed_story != null) | .key' "$PLAN_PATH")
}

REPO="${REPO:?REPO required}"
PLAN_PATH="${PLAN_PATH:?PLAN_PATH required}"
DISCUSSION_NUMBER="${DISCUSSION_NUMBER:-}"
DISCUSSION_NODE_ID="${DISCUSSION_NODE_ID:-}"
DISCUSSION_REPO="${DISCUSSION_REPO:-$REPO}"

# Cross-repo references. Same-repo both prefixes are empty, so every rendered
# string (and the idempotency key) is byte-for-byte what it was before.
#   disc_prefix   qualifies the discussion number in text that lives in REPO
#   issue_prefix  qualifies REPO issue numbers in text posted to the Discussion
disc_prefix=""
issue_prefix=""
if [ "$DISCUSSION_REPO" != "$REPO" ]; then
  disc_prefix="$DISCUSSION_REPO"
  issue_prefix="$REPO"
fi

[ -s "$PLAN_PATH" ] || { echo "::error::plan file '$PLAN_PATH' missing or empty" >&2; exit 1; }

# ── blocking open-questions gate ──────────────────────────────────────────────
# Bob routes anything he can't resolve to `open_questions`. A question shaped as
# an object with `blocking:true` means the idea is not yet plannable — building
# an epic + story DAG now would just create throwaway issues a human must close
# and re-plan (see #682; incidents #650→#659, #666→#667). So if ANY blocking
# question is present we create NOTHING: post the questions back to the source
# discussion with "not yet planned" framing and exit cleanly (DRY_RUN honored
# via comment_on_discussion). Re-running once the questions are answered then
# materializes the real plan. Plain-string questions stay advisory only.
#
# A finding a maintainer has explicitly accepted (`accepted:true`, #706) is no
# longer an open blocker — it is resolved by materialization (see below) — so it
# is excluded here. An un-accepted proposed_story finding still gates like any
# other blocking open_question until the human accepts it.
blocking_count="$(jq '[(.open_questions // [])[] | select(type=="object" and .blocking==true and .accepted != true)] | length' "$PLAN_PATH")"
if [ "$blocking_count" -gt 0 ]; then
  src_g="$(jq -r '.source_discussion // empty' "$PLAN_PATH")"
  [ -n "$src_g" ] || src_g="$DISCUSSION_NUMBER"
  if [ -n "$DISCUSSION_NODE_ID" ]; then
    blocking_list="$(jq -r '[(.open_questions // [])[] | select(type=="object" and .blocking==true and .accepted != true) | .question] | map("- " + .) | join("\n")' "$PLAN_PATH")"
    other_list="$(jq -r '(.open_questions // []) | map(select((type=="string") or (type=="object" and .blocking != true))) | map(if type=="string" then . else .question end) | if length>0 then "\n\n_Also worth confirming (non-blocking):_\n" + (map("- " + .) | join("\n")) else "" end' "$PLAN_PATH")"
    printf -v gate_comment '<!-- initiative-planner -->\n**⏸️ Not yet planned — the BMAD Scrum Master (Bob) has blocking open questions.**\n\nThis idea cannot be turned into an epic until these are answered:\n\n%s%s\n\n---\n**No epic or stories were created.** Answer the questions above, then re-approve / re-dispatch the planner and Bob will materialize the full epic + sub-issue DAG.' \
      "$blocking_list" "$other_list"
    comment_on_discussion "$DISCUSSION_NODE_ID" "$DISCUSSION_REPO" "$gate_comment"
    echo "posted 'not yet planned' open-questions back to discussion #${DISCUSSION_NUMBER:-?}"
  fi
  echo "::warning::initiative-planner: idea #${src_g:-?} has ${blocking_count} blocking open question(s) — no epic created. Answer them and re-dispatch."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## Initiative not yet planned — needs answers$(if [ "${DRY_RUN:-0}" = "1" ]; then echo " (DRY_RUN)"; fi)"
      echo "- Source discussion: #${src_g:-?}"
      echo "- Blocking open questions: ${blocking_count}"
      echo "- **No epic or stories were created.** Answer the questions and re-dispatch the planner."
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  echo "gated: ${blocking_count} blocking open question(s); created nothing. dry_run=${DRY_RUN:-0}"
  exit 0
fi

# Resolve the source discussion once (plan wins, else env) — used by the
# idempotency/supersede guard (in the epic section) and the epic back-reference.
src="$(jq -r '.source_discussion // empty' "$PLAN_PATH")"
[ -n "$src" ] || src="$DISCUSSION_NUMBER"

# Set by the idempotency/supersede guard (below) when force_replan supersedes an
# existing epic; consumed by the supersede step after the new DAG is created.
SUPERSEDE_OLD_EPIC=""

# ── mode guards (#708 reconcile-in-place) ─────────────────────────────────────
# RECONCILE re-triggers the planner against a LIVE epic to ADD newly-surfaced
# work in place; FORCE_REPLAN SUPERSEDES the epic (closes it, builds a fresh DAG).
# They are opposite intents — reject setting both so a caller can't silently get
# a supersede when they meant an additive reconcile (or vice versa).
RECONCILE="${RECONCILE:-0}"
if [ "$RECONCILE" = "1" ] && [ "${FORCE_REPLAN:-0}" = "1" ]; then
  echo "::error::RECONCILE and FORCE_REPLAN are mutually exclusive — reconcile is additive-in-place; force_replan supersedes. Pick one." >&2
  exit 2
fi
# Reconcile binds to the existing epic via the source-discussion back-reference,
# so it requires a source discussion to key on.
if [ "$RECONCILE" = "1" ] && [ -z "$src" ]; then
  echo "::error::RECONCILE requires a source discussion (plan.source_discussion or DISCUSSION_NUMBER) to bind to the existing epic." >&2
  exit 2
fi

# ── epic ──────────────────────────────────────────────────────────────────────
epic_title="$(jq -r '.epic.title' "$PLAN_PATH")"
epic_body="$(jq -r '.epic.body' "$PLAN_PATH")"

# Untracked prerequisites: real prereqs that are NOT issues (a discussion, an
# external dependency) — rendered as a maintainer-tickable checklist on the epic,
# distinct from the blocked_by_existing_issues edges (which cover prereqs that ARE
# issues). Appended before the idempotency footer so the footer stays at the bottom.
# Guarded so an empty/absent array leaves epic_body byte-for-byte as-is.
untracked_prereqs="$(jq -r '(.epic.untracked_prerequisites // []) | map("- [ ] " + .) | join("\n")' "$PLAN_PATH")"
if [ -n "$untracked_prereqs" ]; then
  epic_body="${epic_body}"$'\n\n'"## Untracked prerequisites"$'\n'"${untracked_prereqs}"
fi
if [ -n "$src" ]; then
  # idem_key is the idempotency back-reference embedded in every epic body and
  # reused verbatim as the search key by find_existing_epic.
  idem_key="Planned from idea discussion ${disc_prefix}#${src}"
  epic_body="${epic_body}"$'\n\n'"---"$'\n'"${idem_key} by the BMAD Scrum Master initiative-planner. **Inert until a maintainer adds \`initiative:auto\`.**"

  # Idempotency / supersede guard: a second dispatch/auto-trigger for the same
  # idea must not create a duplicate epic + DAG. If an open initiative epic
  # already carries the back-reference, default to a benign skip (exit 0). With
  # FORCE_REPLAN=1, record it for supersede instead and continue to build the
  # fresh DAG; the old epic + its sub-issues are CLOSED at the end (see below).
  existing_epic="$(find_existing_epic "$REPO" "$idem_key")"

  # ── reconcile-in-place (#708) ───────────────────────────────────────────────
  # Turn the idempotent "already planned" SKIP into an ADDITIVE pass: bind to the
  # existing epic and materialize only the accepted proposed_story findings that
  # are NOT already in the epic's DAG (the reconcile diff, keyed on the same
  # back-reference idempotency scheme as #598). Reuses #706's materialization
  # (materialize_accepted_findings) — it does not reimplement it. Writes are
  # limited to NEW sub-issues + their edges: the epic and its base/in-flight
  # stories are never recreated, edited, or closed. Un-accepted findings still
  # gate above (the #682/#600 blocking-open-questions gate ran already), so
  # nothing self-promotes and the epic stays inert.
  if [ "$RECONCILE" = "1" ]; then
    if [ -z "$existing_epic" ]; then
      echo "::warning::reconcile: no existing epic for idea discussion #${src} — nothing to reconcile. Run the planner (idea:approved) first."
      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
          echo "## Initiative reconcile — nothing to do$(if [ "${DRY_RUN:-0}" = "1" ]; then echo " (DRY_RUN)"; fi)"
          echo "- No existing epic found for idea discussion #${src}."
          echo "- **Nothing created.** Plan the idea first (\`idea:approved\`), then reconcile."
        } >>"$GITHUB_STEP_SUMMARY"
      fi
      echo "reconcile: no existing epic for #${src}; created nothing. dry_run=${DRY_RUN:-0}"
      exit 0
    fi

    echo "reconcile: binding to existing epic #${existing_epic} for idea discussion #${src}"
    materialize_accepted_findings "$existing_epic" 1

    if [ "$MATERIALIZED_COUNT" -gt 0 ] && [ -n "$DISCUSSION_NODE_ID" ]; then
      printf -v reconcile_comment '<!-- initiative-planner -->\n**🔁 Reconciled epic %s#%s in place.**\n\n%s newly-surfaced item(s) were added as sub-issues of the existing epic (harvested from sub-issue/review comments, vetted through the plan-critic + acceptance gate). No existing story was rewritten; the epic stays inert (labelled `initiative`, NOT `initiative:auto`).' \
        "$issue_prefix" "$existing_epic" "$MATERIALIZED_COUNT"
      comment_on_discussion "$DISCUSSION_NODE_ID" "$DISCUSSION_REPO" "$reconcile_comment"
      echo "posted reconcile summary to discussion #${DISCUSSION_NUMBER:-?}"
    fi

    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        echo "## Initiative reconciled in place$(if [ "${DRY_RUN:-0}" = "1" ]; then echo " (DRY_RUN)"; fi)"
        echo "- Epic: #${existing_epic} (bound via back-reference; not recreated)"
        echo "- New sub-issues added: ${MATERIALIZED_COUNT}"
        echo "- Base/in-flight stories untouched; epic remains **inert** (no \`initiative:auto\`)."
      } >>"$GITHUB_STEP_SUMMARY"
    fi
    echo "reconcile done. epic=#${existing_epic} added=${MATERIALIZED_COUNT} dry_run=${DRY_RUN:-0}"
    exit 0
  fi

  if [ -n "$existing_epic" ]; then
    if [ "${FORCE_REPLAN:-0}" = "1" ]; then
      SUPERSEDE_OLD_EPIC="$existing_epic"
      echo "force_replan: existing epic #${existing_epic} will be superseded after the new plan is created."
    else
      echo "already planned (epic #${existing_epic}) for idea discussion #${src} — skipping creation"
      if [ -n "$DISCUSSION_NODE_ID" ]; then
        printf -v guard_comment '<!-- initiative-planner -->\n**ℹ️ Already planned — no new epic created.**\n\nThis idea is already materialized as epic %s#%s. Nothing was created on this run.\n\nTo re-plan from scratch (close the existing epic and its stories and build a fresh DAG), re-dispatch the planner with `force_replan=true`.' "$issue_prefix" "$existing_epic"
        comment_on_discussion "$DISCUSSION_NODE_ID" "$DISCUSSION_REPO" "$guard_comment"
        echo "posted 'already planned' notice back to discussion #${DISCUSSION_NUMBER:-?}"
      fi
      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
          echo "## Initiative plan skipped$(if [ "${DRY_RUN:-0}" = "1" ]; then echo " (DRY_RUN)"; fi)"
          echo "- Already planned: epic #${existing_epic} for idea discussion #${src}"
          echo "- No issues created (idempotency guard). Re-dispatch with \`force_replan=true\` to supersede."
        } >>"$GITHUB_STEP_SUMMARY"
      fi
      exit 0
    fi
  fi
fi

epic_out="$(create_issue "$REPO" "$epic_title" "$epic_body" "initiative")"
read -r epic_number epic_id <<< "$epic_out"
echo "epic: #${epic_number} (id ${epic_id}) — ${epic_title}"

# ── stories (id order) ────────────────────────────────────────────────────────
# Map: local story id -> created issue number (used to thread blocked_by edges).
declare -A NUM_BY_LOCAL=()

story_count="$(jq '.stories | length' "$PLAN_PATH")"
mapfile -t local_ids < <(jq -r '.stories | sort_by(.id) | .[].id' "$PLAN_PATH")

for lid in "${local_ids[@]}"; do
  title="$(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | .title' "$PLAN_PATH")"
  hands_off="$(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | .hands_off // false' "$PLAN_PATH")"
  # Compose the story body in the BMAD create-story template order:
  # Story / Acceptance Criteria / Tasks-Subtasks / Dev Notes / Project Structure
  # Notes / References. (See prompts/bmad/skills/create-story/template.md.)
  body="$(jq -r --argjson i "$lid" '
    .stories[] | select(.id==$i)
    | "## Story\n"
      + "As a " + .user_story.role + ",\nI want " + .user_story.action + ",\nso that " + .user_story.benefit + ".\n"
      + "\n## Acceptance Criteria\n"
      + ([.acceptance_criteria | to_entries[] | "\(.key + 1). \(.value)"] | join("\n"))
      + "\n\n## Tasks / Subtasks\n"
      + ([.tasks[]
          | "- [ ] " + .task
            + (if (.ac_refs // []) | length > 0 then " (AC: " + ([.ac_refs[] | "#\(.)"] | join(", ")) + ")" else "" end)
            + (if (.subtasks // []) | length > 0 then "\n" + ([.subtasks[] | "  - [ ] " + .] | join("\n")) else "" end)
         ] | join("\n"))
      + "\n\n## Dev Notes\n" + ([.dev_notes[] | "- " + .] | join("\n"))
      + (if .project_structure_notes then "\n\n### Project Structure Notes\n" + .project_structure_notes else "" end)
      + (if (.references // []) | length > 0 then "\n\n### References\n" + ([.references[] | "- " + .] | join("\n")) else "" end)
      + (if (.target_surface // []) | length > 0 then "\n\n### Likely target surface\n" + ([.target_surface[] | "- `" + . + "`"] | join("\n")) else "" end)
  ' "$PLAN_PATH")"
  body="${body}"$'\n\n'"_Story prepared by the BMAD Scrum Master (Bob) for epic #${epic_number}. Status: ready-for-dev._"

  labels="initiative"
  if [ "$hands_off" = "true" ]; then
    labels="initiative,dev-lead:hands-off,initiative:hold"
  fi

  story_out="$(create_issue "$REPO" "$title" "$body" "$labels")"
  read -r s_number s_id <<< "$story_out"
  NUM_BY_LOCAL[$lid]="$s_number"
  echo "  story[$lid]: #${s_number} (id ${s_id}) — ${title}$(if [ "$hands_off" = "true" ]; then echo ' [hands-off]'; fi)"

  link_sub_issue "$REPO" "$epic_number" "$s_id"
done

# ── dependency edges ──────────────────────────────────────────────────────────
for lid in "${local_ids[@]}"; do
  issue_num="${NUM_BY_LOCAL[$lid]}"

  # intra-plan blockers (local ids -> created numbers)
  while IFS= read -r dep_local; do
    [ -n "$dep_local" ] || continue
    add_blocked_by "$REPO" "$issue_num" "${NUM_BY_LOCAL[$dep_local]}"
    echo "  edge: #${issue_num} blocked_by #${NUM_BY_LOCAL[$dep_local]} (plan-local ${lid}<-${dep_local})"
  done < <(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | (.blocked_by // [])[]' "$PLAN_PATH")

  # existing-issue prerequisites (real numbers as-is)
  while IFS= read -r dep_existing; do
    [ -n "$dep_existing" ] || continue
    add_blocked_by "$REPO" "$issue_num" "$dep_existing"
    echo "  edge: #${issue_num} blocked_by existing #${dep_existing}"
  done < <(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | (.blocked_by_existing_issues // [])[]' "$PLAN_PATH")
done

# ── materialize accepted proposed-story findings (#706) ───────────────────────
# A plan-critic finding may carry a proposed_story (a whole story the plan is
# missing) + proposed_blocked_by (the existing issue that story gates). Until a
# maintainer sets accepted:true it gates like any blocking open_question (the
# gate above); on ACCEPTANCE we turn it into a real sub-issue of THIS epic and
# wire the native blocked_by edge — instead of leaving it as advisory prose that
# had to be created by hand (the #581 -> #691/#692 gap). Materialization happens
# ONLY on explicit acceptance, never automatically. A plan with no accepted
# proposed_story findings materializes nothing (clean no-op). The reconcile-in-place
# pass (#708) reuses this SAME function against an existing epic — see the RECONCILE
# branch above. Here (plan time) dedup is off: the epic is brand new.
materialize_accepted_findings "$epic_number" 0

# ── post the plan back to the discussion ──────────────────────────────────────
if [ -n "$DISCUSSION_NODE_ID" ]; then
  rows=""
  for lid in "${local_ids[@]}"; do
    t="$(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | .title' "$PLAN_PATH")"
    sz="$(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | .size' "$PLAN_PATH")"
    rows="${rows}- ${issue_prefix}#${NUM_BY_LOCAL[$lid]} (${sz}) — ${t}"$'\n'
  done
  oq="$(jq -r '(.open_questions // []) | map(if type=="string" then . else .question end) | if length>0 then "\n**Open questions for review:**\n" + (map("- " + .) | join("\n")) else "" end' "$PLAN_PATH")"
  comment="$(printf '<!-- initiative-planner -->\n**📋 Initiative planned by the BMAD Scrum Master (Bob).**\n\nEpic **%s#%s** — %s\n\n%s stories created (inert — labelled `initiative`, NOT `initiative:auto`):\n\n%s\n%s\n---\nReview the epic and its sub-issue DAG, adjust as needed, then add **`initiative:auto`** to epic %s#%s to hand it to `initiative-driver` for auto-implementation.' \
    "$issue_prefix" "$epic_number" "$epic_title" "$story_count" "$rows" "$oq" "$issue_prefix" "$epic_number")"
  comment_on_discussion "$DISCUSSION_NODE_ID" "$DISCUSSION_REPO" "$comment"
  echo "posted plan summary to discussion #${DISCUSSION_NUMBER:-?}"
fi

# ── supersede the prior epic (force_replan only) ──────────────────────────────
# The fresh epic + DAG now exist and have been announced; close (never delete)
# the superseded epic and its sub-issues so history and inbound references stay
# resolvable, each pointing forward to the replacement.
if [ -n "${SUPERSEDE_OLD_EPIC:-}" ]; then
  echo "force_replan: closing superseded epic #${SUPERSEDE_OLD_EPIC} and its sub-issues (replaced by #${epic_number})."
  # Capture into a variable (not process substitution) so a failed lookup trips
  # set -e and aborts, rather than silently skipping the sub-issue closes.
  old_subs="$(list_sub_issue_numbers "$REPO" "$SUPERSEDE_OLD_EPIC")"
  while IFS= read -r old_sub; do
    [ -n "$old_sub" ] || continue
    close_issue "$REPO" "$old_sub" "Superseded by the re-planned initiative epic #${epic_number} (re-planned from idea discussion ${disc_prefix}#${src})."
    echo "  closed superseded story #${old_sub}"
  done <<< "$old_subs"
  close_issue "$REPO" "$SUPERSEDE_OLD_EPIC" "Superseded by #${epic_number} — re-planned from idea discussion ${disc_prefix}#${src}. This epic and its stories were closed by the initiative-planner \`force_replan\` path."
  echo "  closed superseded epic #${SUPERSEDE_OLD_EPIC}"
fi

# ── step summary ──────────────────────────────────────────────────────────────
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Initiative plan applied$(if [ "${DRY_RUN:-0}" = "1" ]; then echo " (DRY_RUN)"; fi)"
    echo "- Epic: #${epic_number} — ${epic_title}"
    echo "- Stories: ${story_count}"
    echo "- Epic is **inert** (no \`initiative:auto\`); add it manually to activate."
    if [ -n "${SUPERSEDE_OLD_EPIC:-}" ]; then
      echo "- Superseded prior epic #${SUPERSEDE_OLD_EPIC} (closed, not deleted)."
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi

echo "done. epic=#${epic_number} stories=${story_count} dry_run=${DRY_RUN:-0}${SUPERSEDE_OLD_EPIC:+ superseded=#${SUPERSEDE_OLD_EPIC}}"
