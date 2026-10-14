#!/usr/bin/env bats
# Tests for the idea-triage queue upsert (scripts/idea-triage/upsert-queue.sh).
# Only the DRY_RUN path is exercised (no network).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TRIAGE_DIR="$ROOT/scripts/idea-triage"
  TMP="$(mktemp -d)"
  BODY="$TMP/body.md"
  LOG="$TMP/dry.jsonl"
  printf '# Idea Promotion Queue\n\nRipe: #562\n' >"$BODY"
}

teardown() { rm -rf "$TMP"; }

@test "upsert-queue (DRY_RUN) logs the intended upsert with a non-empty body" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    QUEUE_BODY_PATH="$BODY" run bash "$TRIAGE_DIR/upsert-queue.sh"
  [ "$status" -eq 0 ]
  grep -q '"op":"upsert_queue"' "$LOG"
  # body_len recorded and > 0
  [ "$(jq -r 'select(.op=="upsert_queue") | .body_len' "$LOG")" -gt 0 ]
}

@test "upsert-queue fails on a missing/empty body" {
  DRY_RUN=1 DRY_RUN_LOG="$LOG" REPO="petry-projects/.github-private" \
    QUEUE_BODY_PATH="$TMP/does-not-exist.md" run bash "$TRIAGE_DIR/upsert-queue.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or empty"* ]]
}

# ── cross-repo target_repo parameterization (#821) ────────────────────────────
# The central triage workflow can run for a NON-self target repo: the Ideas
# backlog is gathered FROM, and the "Idea Promotion Queue" tracking issue is
# created IN, that target repo. The scripts already take REPO; these assert REPO
# threads through to every gh/GraphQL call for a target repo that is NOT
# .github-private. gh is stubbed so no network is touched.

@test "gather-ideas gathers the backlog FROM the target repo (non-self)" {
  MOCK_BIN="$TMP/mock_bin_gather"
  mkdir -p "$MOCK_BIN"
  GH_LOG="$TMP/gh.log"
  export GH_LOG
  export PATH="$MOCK_BIN:$PATH"
  cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *graphql*) echo '{"data":{"repository":{"discussions":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[]}}}}' ;;
  *"issue list"*) echo '[]' ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"

  CTX="$TMP/context.json"
  REPO="acme/widgets" CONTEXT_PATH="$CTX" GH_TOKEN=x \
    run bash "$TRIAGE_DIR/gather-ideas.sh"
  [ "$status" -eq 0 ]
  # GraphQL discussions query targets the target repo's owner/name.
  grep -qF -- "owner=acme" "$GH_LOG"
  grep -qF -- "name=widgets" "$GH_LOG"
  # Open-epics lookup runs against the target repo, not .github-private.
  grep -qF -- "--repo acme/widgets" "$GH_LOG"
  ! grep -qF -- ".github-private" "$GH_LOG"
  # The assembled context records the target repo.
  [ "$(jq -r '.repo' "$CTX")" = "acme/widgets" ]
}

@test "upsert-queue creates the queue issue IN the target repo (non-self, live)" {
  MOCK_BIN="$TMP/mock_bin_upsert"
  mkdir -p "$MOCK_BIN"
  GH_LOG="$TMP/gh.log"
  export GH_LOG
  export PATH="$MOCK_BIN:$PATH"
  cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"issue list"*) echo '' ;;
  *"issue create"*) echo 'https://github.com/acme/widgets/issues/7' ;;
  *) echo '' ;;
esac
EOF
  chmod +x "$MOCK_BIN/gh"

  # Live path (no DRY_RUN): create the queue issue + label in the TARGET repo.
  REPO="acme/widgets" QUEUE_BODY_PATH="$BODY" GH_TOKEN=x \
    run bash "$TRIAGE_DIR/upsert-queue.sh"
  [ "$status" -eq 0 ]
  grep -qF -- "issue create --repo acme/widgets" "$GH_LOG"
  grep -qF -- "label create idea-triage --repo acme/widgets" "$GH_LOG"
  ! grep -qF -- ".github-private" "$GH_LOG"
}
