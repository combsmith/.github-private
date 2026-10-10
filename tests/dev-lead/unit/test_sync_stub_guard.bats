#!/usr/bin/env bats
# Unit tests for scripts/lib/sync-stub-guard.sh (#2185).
#
# On petry-projects/incubator#164 (a standards-sync PR) CodeAnt asked for a
# `pull_request: [review_requested]` trigger on the synced persona-mention.yml
# stub. A fix-bot-comment pass applied it and deleted the NOTE explaining why the
# template omits it; the PR then no longer matched the template it syncs, with
# auto-merge on. Nothing in the harness stopped it. This guard does: a bot-driven
# pass on a `standards-sync` PR may not change a stub whose header names a
# `SOURCE OF TRUTH` under petry-projects/.github/standards/, except to restore it
# to the content the sync commit wrote.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/sync-stub-guard.sh"
HARNESS="$SCRIPT_DIR/scripts/dev-lead-fix-reviews.sh"

STUB=".github/workflows/persona-mention.yml"
TPL="standards/workflows/persona-mention.yml"

setup() {
  # shellcheck source=scripts/lib/sync-stub-guard.sh
  source "$LIB"
}

@test "sync-stub-guard.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# ssg_template_path — the stub header names the template
# ---------------------------------------------------------------------------

@test "ssg_template_path: an org-standard stub header yields its template path" {
  run ssg_template_path $'# ──\n# SOURCE OF TRUTH: petry-projects/.github/standards/workflows/persona-mention.yml\nname: x\n'
  [[ "$status" -eq 0 ]]
  [[ "$output" == "$TPL" ]]
}

@test "ssg_template_path: a .github-private SOURCE OF TRUTH is out of scope" {
  run ssg_template_path $'# SOURCE OF TRUTH: petry-projects/.github-private/.github/workflows/token-report.yml\n'
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "ssg_template_path: no header, or a header deep in the body, is not a stub" {
  run ssg_template_path $'name: ci\non: push\n'
  [[ "$status" -eq 1 ]]
  local body i
  body=""
  for i in $(seq 1 30); do body+="# line ${i}"$'\n'; done
  body+=$'# SOURCE OF TRUTH: petry-projects/.github/standards/workflows/x.yml\n'
  run ssg_template_path "$body"
  [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# ssg_has_sync_label
# ---------------------------------------------------------------------------

@test "ssg_has_sync_label: matches the standards-sync label exactly" {
  ssg_has_sync_label $'dependencies\nstandards-sync'
  run ssg_has_sync_label $'dependencies\nstandards-sync-legacy'
  [[ "$status" -eq 1 ]]
  run ssg_has_sync_label ""
  [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# ssg_scan_pass — the impure gatherer over <pre-pass>..<head>
# ---------------------------------------------------------------------------

_stub_body() {
  cat <<'EOF'
# ─────────────────────────────────────────────────────────────────────────────
# SOURCE OF TRUTH: petry-projects/.github/standards/workflows/persona-mention.yml
# Do not change the trigger events in a consumer repo.
# ─────────────────────────────────────────────────────────────────────────────
name: Persona Mention
on:
  issue_comment:
    types: [created]
  # NOTE: pull_request review_requested is deliberately not subscribed — the
  # router has no path for reviewer assignment (finding 10 in
  # petry-projects/.github#755). Do not add it here; change the template.
jobs:
  route:
    uses: petry-projects/.github/.github/workflows/persona-mention-reusable.yml@v1
EOF
}

# _mk_sync_pr: main holds a README and a .github-private-sourced stub; the PR
# branch's sync commit writes the org-standard stub and a docs file. PRE is the
# pre-pass head, MB the merge base.
_mk_sync_pr() {
  REPO_DIR="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$REPO_DIR"
  cd "$REPO_DIR"
  git config user.email t@t; git config user.name T
  mkdir -p .github/workflows docs
  echo "# repo" > README.md
  printf '# SOURCE OF TRUTH: petry-projects/.github-private/.github/workflows/token-report.yml\nname: t\n' \
    > .github/workflows/token-report.yml
  git add -A; git commit -q -m base
  MB="$(git rev-parse HEAD)"
  git checkout -q -b feat
  _stub_body > "$STUB"
  echo "synced" > docs/sync.md
  git add -A; git commit -q -m "chore: sync 1 org-standard workflow stub(s)"
  SYNC="$(git rev-parse HEAD)"
  PRE="$SYNC"
}

# _bot_drift: the incubator#164 edit — add the trigger, delete the NOTE.
_bot_drift() {
  sed -i -e '/# NOTE:/,/change the template\./d' "$STUB"
  sed -i -e 's/^    types: \[created\]$/    types: [created]\n  pull_request:\n    types: [review_requested]/' "$STUB"
  git add -A; git commit -q -m "fix(bot): address bot feedback"
}

@test "ssg_scan_pass: the incubator#164 shape — a bot pass edits the synced stub -> drift rc1, template named" {
  _mk_sync_pr
  _bot_drift
  run ssg_scan_pass "$PRE" HEAD "$MB"
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == "drift" ]]
  [[ "${lines[1]}" == "${STUB}"$'\t'"${TPL}" ]]
}

@test "ssg_scan_pass: deleting the synced stub -> drift" {
  _mk_sync_pr
  git rm -q "$STUB"; git commit -q -m "fix(bot): drop it"
  run ssg_scan_pass "$PRE" HEAD "$MB"
  [[ "$status" -eq 1 ]]
  [[ "${lines[1]}" == "${STUB}"$'\t'"${TPL}" ]]
}

@test "ssg_scan_pass: a maintainer restore of a drifted stub to the synced content -> clean" {
  _mk_sync_pr
  _bot_drift
  PRE="$(git rev-parse HEAD)"   # the drift already landed; this pass restores it
  git show "${SYNC}:${STUB}" > "$STUB"
  git add -A; git commit -q -m "fix(reviews): restore the stub to the template"
  run ssg_scan_pass "$PRE" HEAD "$MB"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ssg_scan_pass: a partial restore that still differs from the synced content -> drift" {
  _mk_sync_pr
  _bot_drift
  PRE="$(git rev-parse HEAD)"
  echo "# tweak" >> "$STUB"
  git add -A; git commit -q -m "fix(bot): more"
  run ssg_scan_pass "$PRE" HEAD "$MB"
  [[ "$status" -eq 1 ]]
}

@test "ssg_scan_pass: a stub the PR did not touch, edited by the pass -> drift" {
  _mk_sync_pr
  printf '# SOURCE OF TRUTH: petry-projects/.github/standards/workflows/ci.yml\nname: ci\n' > .github/workflows/ci.yml
  git add -A; git commit -q -m "main stub"
  # Rebuild the PR on top of that commit so the stub exists at the merge base.
  MB="$(git rev-parse HEAD)"; PRE="$MB"
  echo "  # extra" >> .github/workflows/ci.yml
  git add -A; git commit -q -m "fix(bot): x"
  run ssg_scan_pass "$PRE" HEAD "$MB"
  [[ "$status" -eq 1 ]]
  [[ "${lines[1]}" == ".github/workflows/ci.yml"$'\t'"standards/workflows/ci.yml" ]]
}

@test "ssg_scan_pass: the sync PR's other files and .github-private stubs are unaffected -> clean" {
  _mk_sync_pr
  echo "more" >> README.md
  echo "  # note" >> .github/workflows/token-report.yml
  echo "x" > new.txt
  git add -A; git commit -q -m "fix(bot): docs"
  run ssg_scan_pass "$PRE" HEAD "$MB"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ssg_scan_pass: unknown pre-pass head fails closed -> unknown rc2" {
  _mk_sync_pr
  run ssg_scan_pass "" HEAD "$MB"
  [[ "$status" -eq 2 ]]
  [[ "$output" == "unknown" ]]
  run ssg_scan_pass "0000000000000000000000000000000000000000" HEAD "$MB"
  [[ "$status" -eq 2 ]]
}

@test "ssg_scan_pass: a pass touching a stub with no resolvable merge base fails closed -> unknown rc2" {
  _mk_sync_pr
  _bot_drift
  run ssg_scan_pass "$PRE" HEAD ""
  [[ "$status" -eq 2 ]]
  [[ "$output" == "unknown" ]]
}

@test "ssg_scan_pass: a pass changing no file is clean without a merge base" {
  _mk_sync_pr
  git commit -q --allow-empty -m "fix(bot): nothing"
  run ssg_scan_pass "$PRE" HEAD ""
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ssg_pass_touches_stubs: true for any file change or an unknown base, false for an empty pass" {
  _mk_sync_pr
  git commit -q --allow-empty -m "nothing"
  run ssg_pass_touches_stubs "$PRE" HEAD
  [[ "$status" -eq 1 ]]
  _bot_drift
  run ssg_pass_touches_stubs "$PRE" HEAD
  [[ "$status" -eq 0 ]]
  run ssg_pass_touches_stubs "" HEAD
  [[ "$status" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# ssg_evaluate — label gating over the PR JSON (non-sync PRs are unaffected)
# ---------------------------------------------------------------------------

# _mk_remote: a bare origin holding main and the PR branch, so the merge base
# resolves the way it does on a runner.
_mk_remote() {
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare "$REMOTE"
  git remote add origin "file://$REMOTE"
  git push -q origin main feat
}

SYNC_PR_JSON='{"base":{"ref":"main"},"labels":[{"name":"standards-sync"}]}'
PLAIN_PR_JSON='{"base":{"ref":"main"},"labels":[{"name":"enhancement"}]}'

@test "ssg_evaluate: a standards-sync PR whose pass drifts a stub -> drift rc1" {
  _mk_sync_pr
  _mk_remote
  _bot_drift
  run ssg_evaluate "$PRE" HEAD "$SYNC_PR_JSON" feat
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == "drift" ]]
  [[ "${lines[1]}" == "${STUB}"$'\t'"${TPL}" ]]
}

@test "ssg_evaluate: the same stub edit on a non-sync PR -> clean" {
  _mk_sync_pr
  _mk_remote
  _bot_drift
  run ssg_evaluate "$PRE" HEAD "$PLAIN_PR_JSON" feat
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ssg_evaluate: a pass changing no file never needs the PR JSON -> clean" {
  _mk_sync_pr
  git commit -q --allow-empty -m "nothing"
  run ssg_evaluate "$PRE" HEAD "" feat
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ssg_evaluate: an unreadable PR when a stub was touched fails closed -> unknown rc2" {
  _mk_sync_pr
  _bot_drift
  run ssg_evaluate "$PRE" HEAD "" feat
  [[ "$status" -eq 2 ]]
  run ssg_evaluate "$PRE" HEAD "not json" feat
  [[ "$status" -eq 2 ]]
}

@test "ssg_evaluate: an unreadable PR with only an ordinary file changed is clean (warning, no hold)" {
  _mk_sync_pr
  echo "more" >> README.md
  git add -A; git commit -q -m "fix(bot): docs"
  local out
  out=$(ssg_evaluate "$PRE" HEAD "" feat 2>"$BATS_TEST_TMPDIR/err")
  [[ "$out" == "clean" ]]
  grep -q '::warning::.*sync-stub check was skipped' "$BATS_TEST_TMPDIR/err"
  out=$(ssg_evaluate "$PRE" HEAD "not json" feat 2>/dev/null)
  [[ "$out" == "clean" ]]
}

@test "ssg_evaluate: an object with no labels key is a readable, unlabeled PR -> clean" {
  _mk_sync_pr
  _bot_drift
  run ssg_evaluate "$PRE" HEAD '{"base":{"ref":"main"}}' feat
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "Wiring: the harness retries an unreadable PR read a bounded number of times" {
  grep -q 'ssg_try' "$HARNESS"
  grep -q 'SSG_RETRY_SLEEP' "$HARNESS"
}

@test "ssg_evaluate: a sync PR whose merge base cannot be resolved fails closed -> unknown rc2" {
  _mk_sync_pr
  _bot_drift   # no origin: the merge base with origin/main is unresolvable
  run ssg_evaluate "$PRE" HEAD "$SYNC_PR_JSON" feat
  [[ "$status" -eq 2 ]]
}

# ---------------------------------------------------------------------------
# Header-less synced stubs (dev-lead.yml has no SOURCE OF TRUTH header)
# ---------------------------------------------------------------------------

HL=".github/workflows/dev-lead.yml"

_headerless_body() {
  cat <<'EOF'
name: dev-lead
on:
  issue_comment:
    types: [created]
jobs:
  dispatch:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@dev-lead/v1-stable
EOF
}

# _mk_headerless_pr: the sync commit also writes a header-less dev-lead.yml.
_mk_headerless_pr() {
  _mk_sync_pr
  _headerless_body > "$HL"
  git add -A; git commit -q -m "chore: sync dev-lead stub"
  PRE="$(git rev-parse HEAD)"
}

_pin_uses() {
  sed -i -e 's#@dev-lead/v1-stable#@0123456789abcdef0123456789abcdef01234567#' "$HL"
  git add -A; git commit -q -m "fix(bot): pin uses"
}

@test "ssg_scan_pass: a header-less file the sync commit wrote, SHA-pinned by a bot pass -> drift, no template named" {
  _mk_headerless_pr
  _pin_uses
  run ssg_scan_pass "$PRE" HEAD "$MB"
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == "drift" ]]
  [[ "${lines[1]}" == "${HL}"$'\t' ]]
}

@test "ssg_scan_pass: restoring the header-less file to the sync content -> clean" {
  _mk_headerless_pr
  _pin_uses
  PRE="$(git rev-parse HEAD)"
  _headerless_body > "$HL"
  git add -A; git commit -q -m "fix(reviews): restore"
  run ssg_scan_pass "$PRE" HEAD "$MB"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ssg_scan_pass: a header-less file the PR never touched, edited by the pass -> clean" {
  _mk_sync_pr
  echo "  # extra" >> .github/workflows/token-report.yml
  printf 'name: other\n' > .github/workflows/other.yml
  git add -A; git commit -q -m "fix(bot): x"
  run ssg_scan_pass "$PRE" HEAD "$MB"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clean" ]]
}

@test "ssg_evaluate: the header-less drift on a standards-sync PR -> drift rc1; on a plain PR -> clean" {
  _mk_headerless_pr
  _mk_remote
  _pin_uses
  run ssg_evaluate "$PRE" HEAD "$SYNC_PR_JSON" feat
  [[ "$status" -eq 1 ]]
  [[ "${lines[1]}" == "${HL}"$'\t' ]]
  run ssg_evaluate "$PRE" HEAD "$PLAIN_PR_JSON" feat
  [[ "$status" -eq 0 ]]
}

@test "ssg_declined_body: a row with no template points at standards/ in petry-projects/.github" {
  run ssg_declined_body "fix-bot-comment" ".github/workflows/dev-lead.yml"
  [[ "$output" == *'`.github/workflows/dev-lead.yml` — no template header'* ]]
  [[ "$output" == *"petry-projects/.github/tree/main/standards"* ]]
}


# ---------------------------------------------------------------------------
# ssg_declined_body — the reply that answers the bot as declined
# ---------------------------------------------------------------------------

@test "ssg_declined_body: declines, links each template in petry-projects/.github, and says nothing was pushed" {
  run ssg_declined_body fix-bot-comment "${STUB}"$'\t'"${TPL}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Declined"* ]]
  [[ "$output" == *"change the template"* ]]
  [[ "$output" == *"\`${STUB}\`"* ]]
  [[ "$output" == *"https://github.com/petry-projects/.github/blob/main/${TPL}"* ]]
  [[ "$output" == *"did not push"* ]]
  [[ "$output" == *"fix-bot-comment"* ]]
}

@test "ssg_declined_body: an unverifiable scan says so instead of naming a template" {
  run ssg_declined_body fix-reviews ""
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"could not be verified"* ]]
}

# ---------------------------------------------------------------------------
# Harness wiring (scripts/dev-lead-fix-reviews.sh)
# ---------------------------------------------------------------------------

@test "Wiring: the harness sources the sync-stub guard" {
  grep -q 'source "$(dirname "$0")/lib/sync-stub-guard.sh"' "$HARNESS"
}

@test "Wiring: commit_and_push guards the bot-driven intents only and refuses with rc 4" {
  local body
  body=$(awk '/^commit_and_push\(\) \{/,/^}/' "$HARNESS")
  grep -q 'ssg_evaluate' <<<"$body"
  # Scoped to bot-driven passes; maintainer-driven intents (review-changes,
  # human-pr, on-mention, human) are an explicit override and are not guarded.
  awk '/^[[:space:]]*fix-bot-comment\|fix-reviews\)$/,/;;/' <<<"$body" | grep -q 'ssg_evaluate'
  if awk '/^[[:space:]]*case "\$intent" in/,/esac/' <<<"$body" \
    | grep -B12 'ssg_evaluate' | grep -qE 'review-changes|human-pr|on-mention'; then
    return 1
  fi
  grep -A12 'ssg_evaluate' <<<"$body" | grep -q 'flag_sync_stub_drift'
  grep -A14 'ssg_evaluate' <<<"$body" | grep -q 'return 4'
}

@test "Wiring: flag_sync_stub_drift holds the PR and posts the declined body once" {
  local body
  body=$(awk '/^flag_sync_stub_drift\(\) \{/,/^}/' "$HARNESS")
  [[ -n "$body" ]]
  grep -q 'ssg_declined_body' <<<"$body"
  grep -q 'apply_hold_label' <<<"$body"
  grep -q 'disable_auto_merge_for_hold' <<<"$body"
  grep -q '_AM_NEEDS_RESTORE=0' <<<"$body"
}
