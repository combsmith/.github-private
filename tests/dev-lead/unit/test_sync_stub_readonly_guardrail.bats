#!/usr/bin/env bats
# Prompt contract for #2185: the dev-lead review prompts must treat a file whose
# header names a `SOURCE OF TRUTH` under petry-projects/.github/standards/ as
# read-only in a consumer repo. A bot suggestion to change it is declined (no code
# change, no addressed-marker) with a pointer to the template, so a standards-sync
# PR never drifts from the template it syncs (petry-projects/incubator#164). The
# harness half of the guard is tested in test_sync_stub_guard.bats.

PROMPTS_DIR="$(cd "$BATS_TEST_DIRNAME"/../../.. && pwd)/prompts/dev-lead"

# Every prompt that answers review/bot/maintainer feedback on a PR.
RELEVANT_PROMPTS=(fix-bot-comment.md fix-reviews.md review-changes.md on-mention.md)

@test "sync-stub guardrail: present in every review prompt (#2185)" {
  for p in "${RELEVANT_PROMPTS[@]}"; do
    grep -qiE 'guardrail .{1,3} a synced org-standard stub is read-only' "$PROMPTS_DIR/$p" \
      || { echo "missing sync-stub read-only guardrail in prompts/dev-lead/$p"; return 1; }
  done
}

@test "sync-stub guardrail: identifies the stub by its SOURCE OF TRUTH header and the standards-sync label (#2185)" {
  for p in "${RELEVANT_PROMPTS[@]}"; do
    body="$(cat "$PROMPTS_DIR/$p")"
    grep -qF 'SOURCE OF TRUTH: petry-projects/.github/standards/' <<<"$body" \
      || { echo "guardrail in $p does not name the SOURCE OF TRUTH header"; return 1; }
    grep -qF 'standards-sync' <<<"$body" \
      || { echo "guardrail in $p does not name the standards-sync label"; return 1; }
  done
}

@test "sync-stub guardrail: a bot suggestion is declined with a template pointer and no addressed-marker (#2185)" {
  for p in "${RELEVANT_PROMPTS[@]}"; do
    body="$(cat "$PROMPTS_DIR/$p")"
    grep -qiE 'declined .{1,3} change the template' <<<"$body" \
      || { echo "guardrail in $p does not prescribe the 'declined, change the template' reply"; return 1; }
    grep -qF 'https://github.com/petry-projects/.github/blob/main/standards/' <<<"$body" \
      || { echo "guardrail in $p does not point at the template in petry-projects/.github"; return 1; }
    grep -qiE 'no code change' <<<"$body" \
      || { echo "guardrail in $p does not forbid the code change"; return 1; }
    grep -qiE 'without the addressed-marker|no addressed-marker' <<<"$body" \
      || { echo "guardrail in $p does not forbid the addressed-marker on the declined reply"; return 1; }
  done
}

@test "sync-stub guardrail: a restore to the template stays allowed (#2185)" {
  for p in "${RELEVANT_PROMPTS[@]}"; do
    grep -qiE 'restor(e|es|ing) .{0,40}(to|back to) (the|its) (template|synced content)' "$PROMPTS_DIR/$p" \
      || { echo "guardrail in $p does not keep the restore-to-template path open"; return 1; }
  done
}
