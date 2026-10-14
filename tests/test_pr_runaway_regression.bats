#!/usr/bin/env bats
# E2E regression scenarios for the PR-runaway guard (issue #926), reproducing
# the two interacting loops that drove PR #860 to 378 commits / 1,582 comments:
#
#   Scenario A — self-mention comment storm: the cascade's ack comment re-fires
#     the mention listener, posting another identical ack (93.6% of #860's
#     volume). Here the acks are bot-authored events with no human in the thread.
#   Scenario B — review<->fix ping-pong: each fix push re-fires the review, each
#     review re-triggers dev-lead; all events are agent-authored.
#
# Both must HALT at the per-PR automation budget and escalate EXACTLY ONCE.
# gh is fully mocked: comment/review/commit history is served from fixtures, and
# the escalation side effects (comment, label, auto-merge disable) are logged.
#
# Run with: bats tests/test_pr_runaway_regression.bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib/pr-automation-budget.sh"
  MOCK_BIN="$(mktemp -d)"
  FIX="$(mktemp -d)"
  POSTED="$(mktemp)"; LABELS="$(mktemp)"; MERGE="$(mktemp)"
  export FIX POSTED LABELS MERGE
  export PATH="$MOCK_BIN:$PATH"
  export REPO="petry-projects/.github-private"
  export DEV_LEAD_DRY_RUN=false
  echo '[]' > "$FIX/comments.json"
  echo '[]' > "$FIX/commits.json"
  echo '[]' > "$FIX/reviews.json"

  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# Minimal gh mock for the runaway-guard regression tests.
all="$*"
case "$1" in
  api)
    case "$all" in
      *"/issues/"*"/comments"*) cat "$FIX/comments.json" ;;
      # Hold label via the REST labels API (#2142).
      *"/issues/"*"/labels"*)   printf '%s\n' "$all" >> "$LABELS"; echo '[]' ;;
      *"/pulls/"*"/commits"*)   cat "$FIX/commits.json" ;;
      *"/pulls/"*"/reviews"*)   cat "$FIX/reviews.json" ;;
      *) echo '[]' ;;
    esac
    ;;
  pr)
    case "$2" in
      comment)
        body=""
        for ((i=1; i<=$#; i++)); do
          if [ "${!i}" = "--body-file" ]; then j=$((i+1)); body="$(cat "${!j}")"; fi
          if [ "${!i}" = "--body" ]; then j=$((i+1)); body="${!j}"; fi
        done
        printf '%s\n----\n' "$body" >> "$POSTED"
        # Reflect the posted comment back into history so dedupe sees it.
        tmp="$(mktemp)"
        jq --arg b "$body" '. + [{created_at:"2026-06-25T12:00:00Z", user:{login:"donpetry-bot"}, body:$b}]' \
          "$FIX/comments.json" > "$tmp" && mv "$tmp" "$FIX/comments.json"
        ;;
      edit)   printf '%s\n' "$all" >> "$LABELS" ;;
      merge)  printf '%s\n' "$all" >> "$MERGE" ;;
    esac
    ;;
esac
exit 0
EOF
  chmod +x "$MOCK_BIN/gh"
}

teardown() {
  rm -rf "${MOCK_BIN:-}" "${FIX:-}"
  rm -f "${POSTED:-}" "${LABELS:-}" "${MERGE:-}"
}

# Fill comments.json with N byte-identical bot ack comments (~9s cadence).
fill_bot_acks() {  # fill_bot_acks <count>
  local n="$1" i=0 arr='[]' tmp
  while [ "$i" -lt "$n" ]; do
    arr=$(echo "$arr" | jq --arg w "2026-06-24T01:00:$(printf '%02d' "$i")Z" \
      '. + [{created_at:$w, user:{login:"donpetry-bot"}, body:"<!-- pr-review-agent mention-ack -->\n@donpetry-bot I'\''m on it"}]')
    i=$((i + 1))
  done
  tmp="$(mktemp)"; echo "$arr" > "$tmp"; mv "$tmp" "$FIX/comments.json"
}

posted_count() { local n; n=$(grep -c '^----$' "$POSTED" 2>/dev/null) || n=0; echo "${n:-0}"; }

# ---------------------------------------------------------------------------
# Scenario A — self-mention ack storm
# ---------------------------------------------------------------------------

@test "scenario A: self-mention ack storm exhausts the budget" {
  fill_bot_acks 12
  run enforce_pr_budget 860 "$REPO"
  [ "$status" -eq 0 ]   # exhausted -> caller must stop
}

@test "scenario A: escalation fires exactly once (deduped on marker)" {
  fill_bot_acks 12
  enforce_pr_budget 860 "$REPO"
  enforce_pr_budget 860 "$REPO"
  enforce_pr_budget 860 "$REPO"
  [ "$(posted_count)" -eq 1 ]
  run grep -c 'pr-automation-budget exhausted' "$POSTED"
  [ "$output" -eq 1 ]
  # side effects applied: label + auto-merge disabled
  run grep -q 'needs-human-review' "$LABELS"; [ "$status" -eq 0 ]
  run grep -q 'disable-auto' "$MERGE";        [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Scenario B — review<->fix ping-pong
# ---------------------------------------------------------------------------

@test "scenario B: review<->fix ping-pong exhausts and escalates once" {
  # 6 bot review comments + 6 bot fix commits = 12 agent events, no human.
  local arr='[]' commits='[]' i=0
  while [ "$i" -lt 6 ]; do
    arr=$(echo "$arr" | jq --arg w "2026-06-24T0$i:00:00Z" \
      '. + [{created_at:$w, user:{login:"donpetry-bot"}, body:"review cycle"}]')
    commits=$(echo "$commits" | jq --arg w "2026-06-24T0$i:30:00Z" \
      '. + [{commit:{author:{date:$w}}, author:{login:"donpetry-bot"}}]')
    i=$((i + 1))
  done
  echo "$arr" > "$FIX/comments.json"
  echo "$commits" > "$FIX/commits.json"
  run enforce_pr_budget 860 "$REPO"
  [ "$status" -eq 0 ]
  enforce_pr_budget 860 "$REPO"
  [ "$(posted_count)" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Human-in-the-loop rescues the PR (the reset is human-gated)
# ---------------------------------------------------------------------------

@test "a human comment after the storm resets the budget — no escalation" {
  fill_bot_acks 20
  tmp="$(mktemp)"
  jq '. + [{created_at:"2026-06-25T09:00:00Z", user:{login:"alice"}, body:"taking a look"}]' \
    "$FIX/comments.json" > "$tmp" && mv "$tmp" "$FIX/comments.json"
  run enforce_pr_budget 860 "$REPO"
  [ "$status" -ne 0 ]              # not exhausted
  [ "$(posted_count)" -eq 0 ]     # nothing posted
}
