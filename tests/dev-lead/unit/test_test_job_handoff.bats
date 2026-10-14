#!/usr/bin/env bats
# Unit tests for scripts/lib/test-job-handoff.sh and the job split in
# dev-lead-reusable.yml (#2143).
#
# The test-regression guard (#2013) runs code from the PR branch. In the job that
# holds the secrets, that code could read them from /proc/$PPID/environ or the
# checkout's credential, even under `env -i`. The suite now runs in its own job
# (`test-suite`) with no secrets, `permissions: {}` and no checkout. These tests pin
# that job's shape, the handoff that carries the pass's result into it, and the
# verdict that carries the outcome back to the `push` job.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/test-job-handoff.sh"
TRG="$SCRIPT_DIR/scripts/lib/test-regression-guard.sh"
WF="$SCRIPT_DIR/.github/workflows/dev-lead-reusable.yml"
bats_require_minimum_version 1.5.0

setup() {
  # shellcheck source=scripts/lib/test-regression-guard.sh
  source "$TRG"
  # shellcheck source=scripts/lib/test-job-handoff.sh
  source "$LIB"
  unset DEV_LEAD_TEST_CMD
}

# _mk_pass — a repo whose HEAD is a pass's result on top of BASE. The suite is a
# tiny TAP script; $1 is the pass's change (run in the repo before committing).
_mk_pass() {
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  printf 'ok\n' > "$R/state.txt"
  cat > "$R/suite.sh" <<'SH'
#!/usr/bin/env bash
n=0; rc=0
t() { n=$((n+1)); if eval "$2"; then echo "ok $n $1"; else echo "not ok $n $1"; rc=1; fi; }
t "existing behaviour" '[ "$(cat state.txt)" = ok ]'
[ -f new_test_marker ] && t "new test" 'true'
exit $rc
SH
  chmod +x "$R/suite.sh"
  git -C "$R" add .
  git -C "$R" -c user.email=t@t -c user.name=T commit -q -m init
  BASE="$(git -C "$R" rev-parse HEAD)"
  ( cd "$R" && eval "$1" && git add -A && git -c user.email=t@t -c user.name=T commit -q -m fix )
  RESULT="$(git -C "$R" rev-parse HEAD)"
  export DEV_LEAD_TEST_CMD="./suite.sh"
}

# _handoff — tjh_write from the pass's repo; sets H (the tarball) and SHA.
_handoff() {
  H="$BATS_TEST_TMPDIR/out/handoff.tar"
  SHA=$(cd "$R" && tjh_write "$BATS_TEST_TMPDIR/out" "$BASE" '{"v":1,"intent":"fix-reviews"}')
}

@test "test-job-handoff.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

# --- the work side: tjh_write ------------------------------------------------

@test "tjh_write: writes one tarball and echoes its sha256" {
  _mk_pass ': > new_test_marker'
  _handoff
  [[ -f "$H" ]]
  [[ "$SHA" =~ ^[0-9a-f]{64}$ ]]
  [[ "$SHA" == "$(sha256sum "$H" | cut -d' ' -f1)" ]]
  run tar -tf "$H"
  [[ "$output" == *"./result.bundle"* ]]
  [[ "$output" == *"./result-tree.tar"* ]]
  [[ "$output" == *"./base-tree.tar"* ]]
  [[ "$output" == *"./state.json"* ]]
  [[ "$output" == *"./guard/test-regression-guard.sh"* ]]
  [[ "$output" == *"./guard/test-job-handoff.sh"* ]]
}

@test "tjh_write: the tarball carries no .git directory and no git config" {
  _mk_pass ': > new_test_marker'
  git -C "$R" config http.https://github.com/.extraheader "AUTHORIZATION: basic FAKE_GIT_CRED_2143"
  _handoff
  local x="$BATS_TEST_TMPDIR/x"; mkdir -p "$x"
  tar -xf "$H" -C "$x"
  run tar -tf "$x/result-tree.tar"
  [[ "$output" != *".git/"* ]]
  run grep -rl FAKE_GIT_CRED_2143 "$x"
  [[ "$status" -ne 0 ]]
}

# --- the test side: tjh_run_suite ---------------------------------------------

@test "tjh_run_suite: the 15a919e shape — existing test broken, new test added — is a regression" {
  _mk_pass ': > new_test_marker; printf "broken\n" > state.txt'
  _handoff
  run --separate-stderr tjh_run_suite "$H" "$BATS_TEST_TMPDIR/suite"
  [[ "$status" -eq 0 ]]
  [[ "$(jq -r .verdict <<<"$output")" == "regression" ]]
  [[ "$(jq -r .cmd <<<"$output")" == "./suite.sh" ]]
  [[ "$(jq -r '.tests | join(",")' <<<"$output")" == "existing behaviour" ]]
  # the run log still names the failing tests and the suite timings (#2055)
  [[ "$stderr" =~ result\ suite\ run\ took\ [0-9]+s ]]
  [[ "$stderr" =~ baseline\ suite\ run\ took\ [0-9]+s ]]
}

@test "tjh_run_suite: verdicts are unchanged — green, preexisting, timeout, not-run" {
  _mk_pass ': > new_test_marker'
  _handoff
  run --separate-stderr tjh_run_suite "$H" "$BATS_TEST_TMPDIR/s1"
  [[ "$(jq -r .verdict <<<"$output")" == "green" ]]

  export DEV_LEAD_TEST_CMD='echo "not ok 1 old"; exit 1'
  run --separate-stderr tjh_run_suite "$H" "$BATS_TEST_TMPDIR/s2"
  [[ "$(jq -r .verdict <<<"$output")" == "preexisting" ]]

  export DEV_LEAD_TEST_CMD='sleep 5' DEV_LEAD_TEST_TIMEOUT=1
  run --separate-stderr tjh_run_suite "$H" "$BATS_TEST_TMPDIR/s3"
  [[ "$(jq -r .verdict <<<"$output")" == "timeout" ]]
  unset DEV_LEAD_TEST_TIMEOUT

  unset DEV_LEAD_TEST_CMD
  run --separate-stderr tjh_run_suite "$H" "$BATS_TEST_TMPDIR/s4"
  [[ "$status" -eq 0 ]]
  [[ "$(jq -r .verdict <<<"$output")" == "not-run" ]]
}

@test "tjh_run_suite: the suite sees the result's untracked files and the base's tracked files" {
  _mk_pass 'printf "changed\n" > state.txt'
  # an untracked dependency in the work tree (e.g. node_modules) travels with the result
  mkdir -p "$R/deps"; printf 'dep\n' > "$R/deps/lib.txt"
  _handoff
  local seen="$BATS_TEST_TMPDIR/seen"
  export DEV_LEAD_TEST_CMD="{ echo \"dep=\$(cat deps/lib.txt 2>&1)\"; echo \"state=\$(cat state.txt 2>&1)\"; } >> '$seen'; echo 'not ok 1 probe'; exit 1"
  run --separate-stderr tjh_run_suite "$H" "$BATS_TEST_TMPDIR/s"
  # the result is red, so the baseline ran too: probe failed on both → preexisting
  [[ "$(jq -r .verdict <<<"$output")" == "preexisting" ]]
  # run 1 (result): the untracked dep and the changed tracked file; run 2 (baseline): the base's tracked file
  [[ "$(sed -n 1p "$seen")" == "dep=dep" ]]
  [[ "$(sed -n 2p "$seen")" == "state=changed" ]]
  [[ "$(sed -n 4p "$seen")" == "state=ok" ]]
}

@test "tjh_run_suite: fake secrets in the environment and git config do not reach the suite (#2143)" {
  _mk_pass ': > new_test_marker'
  git -C "$R" config http.https://github.com/.extraheader "AUTHORIZATION: basic FAKE_GIT_CRED_9f3"
  _handoff
  export GH_PAT_DON_PETRY=FAKE_PAT_1 GH_TOKEN=FAKE_PAT_2 CLAUDE_CODE_OAUTH_TOKEN=FAKE_C3 GOOGLE_API_KEY=FAKE_G4
  local log="$BATS_TEST_TMPDIR/suite.out"
  export DEV_LEAD_TEST_CMD="{ env; git config --list --show-origin; cat .git/config; } > '$log' 2>&1; echo END >> '$log'"
  run --separate-stderr tjh_run_suite "$H" "$BATS_TEST_TMPDIR/s"
  [[ "$(jq -r .verdict <<<"$output")" == "green" ]]
  grep -q END "$log"
  run grep -c FAKE_ "$log"
  [[ "$output" == "0" ]]
  run grep -c extraheader "$log"
  [[ "$output" == "0" ]]
}

@test "tjh_run_suite: an unreadable handoff reports no verdict (status 2, no JSON)" {
  printf 'not a tar' > "$BATS_TEST_TMPDIR/bad.tar"
  run --separate-stderr tjh_run_suite "$BATS_TEST_TMPDIR/bad.tar" "$BATS_TEST_TMPDIR/s"
  [[ "$status" -eq 2 ]]
  [[ -z "$output" ]]
}

# --- the push side: tjh_verdict (pure) ----------------------------------------

@test "tjh_verdict: each verdict maps to trg_scan_pass's output and status" {
  local v
  for v in green preexisting unattributed unbaselined timeout not-run; do
    run tjh_verdict success "{\"verdict\":\"$v\",\"cmd\":\"make test\",\"tests\":[]}"
    [[ "$status" -eq 0 ]]
    [[ "${lines[0]}" == "${v}"$'\tmake test' ]]
  done
  run tjh_verdict success '{"verdict":"regression","cmd":"make test","tests":["a b","c"]}'
  [[ "$status" -eq 1 ]]
  [[ "${lines[0]}" == $'regression\tmake test' ]]
  [[ "${lines[1]}" == "a b" ]]
  [[ "${lines[2]}" == "c" ]]
}

@test "tjh_verdict: a failed, cancelled, timed-out or skipped test job fails closed" {
  local r
  for r in failure cancelled skipped ""; do
    run tjh_verdict "$r" '{"verdict":"green","cmd":"make test","tests":[]}'
    [[ "$status" -eq 2 ]]
    [[ "${lines[0]}" == no-verdict* ]]
  done
}

@test "tjh_verdict: no verdict, an unknown verdict or bad JSON fails closed" {
  run tjh_verdict success ""
  [[ "$status" -eq 2 ]]
  run tjh_verdict success '{"cmd":"x"}'
  [[ "$status" -eq 2 ]]
  run tjh_verdict success '{"verdict":"passed"}'
  [[ "$status" -eq 2 ]]
  run tjh_verdict success 'not json'
  [[ "$status" -eq 2 ]]
  # a multi-word value is not a verdict, even when its words are listed ones
  run tjh_verdict success '{"verdict":"preexisting unattributed"}'
  [[ "$status" -eq 2 ]]
  [[ "${lines[0]}" == no-verdict* ]]
}

# --- the push side: tjh_restore + tjh_apply_result ----------------------------

@test "tjh_restore: a digest mismatch or a missing tarball is refused" {
  _mk_pass ': > new_test_marker'
  _handoff
  run tjh_restore "$H" "0000" "$BATS_TEST_TMPDIR/r1"
  [[ "$status" -ne 0 ]]
  run tjh_restore "$BATS_TEST_TMPDIR/none.tar" "$SHA" "$BATS_TEST_TMPDIR/r2"
  [[ "$status" -ne 0 ]]
  run tjh_restore "$H" "" "$BATS_TEST_TMPDIR/r3"
  [[ "$status" -ne 0 ]]
  run tjh_restore "$H" "$SHA" "$BATS_TEST_TMPDIR/r4"
  [[ "$status" -eq 0 ]]
  [[ "$(jq -r .intent "$BATS_TEST_TMPDIR/r4/state.json")" == "fix-reviews" ]]
}

@test "tjh_apply_result: a fresh clone at the pre-pass head gets the pass's exact commit" {
  _mk_pass ': > new_test_marker'
  _handoff
  tjh_restore "$H" "$SHA" "$BATS_TEST_TMPDIR/r"
  local c="$BATS_TEST_TMPDIR/clone"
  git clone -q "$R" "$c"
  git -C "$c" reset -q --hard "$BASE"
  ( cd "$c" && tjh_apply_result "$BATS_TEST_TMPDIR/r" "$RESULT" )
  [[ "$(git -C "$c" rev-parse HEAD)" == "$RESULT" ]]
  # a result the bundle does not carry is refused
  git -C "$c" reset -q --hard "$BASE"
  run bash -c "source '$LIB'; cd '$c' && tjh_apply_result '$BATS_TEST_TMPDIR/r' 1111111111111111111111111111111111111111"
  [[ "$status" -ne 0 ]]
  [[ "$(git -C "$c" rev-parse HEAD)" == "$BASE" ]]
}

# --- the workflow: three jobs, the suite's job holds nothing (#2143 AC 1, 2) --

# _py <workflow> — load a workflow file and assert the job split; prints each violation.
_py() {
  WF="$1" python3 - <<'PY'
import os, sys, yaml
doc = yaml.safe_load(open(os.environ["WF"], encoding="utf-8"))
jobs = doc["jobs"]
errs = []
t = jobs.get("test-suite")
if t is None:
    print("no test-suite job"); sys.exit(1)

def walk(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk(v, f"{path}[{i}]")
    else:
        yield path, node

for p, v in walk(t):
    if isinstance(v, str) and "secrets." in v:
        errs.append(f"test-suite references secrets at {p}")
    if isinstance(v, str) and "github.token" in v:
        errs.append(f"test-suite references github.token at {p}")
if t.get("permissions", "MISSING") != {}:
    errs.append(f"test-suite permissions must be {{}}, got {t.get('permissions', 'MISSING')!r}")
if "secrets" in t:
    errs.append("test-suite declares secrets")
for i, s in enumerate(t.get("steps", [])):
    uses = s.get("uses", "") or ""
    if uses.startswith("actions/checkout"):
        errs.append(f"test-suite step {i} checks out the repository")
needs = t.get("needs")
needs = [needs] if isinstance(needs, str) else (needs or [])
if needs != ["dispatch"]:
    errs.append(f"test-suite must need only dispatch, got {needs!r}")
if "needs.dispatch.outputs.handoff == 'true'" not in str(t.get("if", "")):
    errs.append("test-suite must run only on a handoff")
if "always()" in str(t.get("if", "")):
    errs.append("test-suite must not run when there is no handoff")

d = jobs["dispatch"]
if (d.get("env") or {}).get("DEV_LEAD_PHASE") != "work":
    errs.append("dispatch must set DEV_LEAD_PHASE: work so the suite never runs there")
if "handoff" not in (d.get("outputs") or {}):
    errs.append("dispatch must output handoff")

p = jobs.get("push")
if p is None:
    errs.append("no push job")
else:
    pn = p.get("needs")
    pn = [pn] if isinstance(pn, str) else (pn or [])
    if "test-suite" not in pn or "dispatch" not in pn:
        errs.append(f"push must need dispatch and test-suite, got {pn!r}")
    cond = str(p.get("if", ""))
    if "always()" not in cond or "handoff" not in cond:
        errs.append(f"push must run always() on a handoff, got {cond!r}")
    run_env = {}
    for s in p.get("steps", []):
        if (s.get("env") or {}).get("DEV_LEAD_PHASE") == "push":
            run_env = s["env"]
    if "needs.test-suite.result" not in str(run_env.get("DEV_LEAD_TEST_JOB_RESULT", "")):
        errs.append("push must pass needs.test-suite.result to the script")
    if "needs.test-suite.outputs.result" not in str(run_env.get("DEV_LEAD_TRG_RESULT", "")):
        errs.append("push must pass the test job's verdict to the script")

inputs = doc[True]["workflow_call"]["inputs"] if True in doc else doc["on"]["workflow_call"]["inputs"]
if sorted(inputs) != ["agent_ref", "event_name"]:
    errs.append(f"no new workflow_call input allowed, got {sorted(inputs)!r}")

print("\n".join(errs))
sys.exit(1 if errs else 0)
PY
}

@test "dev-lead-reusable.yml: the test-suite job has no secrets, permissions: {} and no credentialed checkout (#2143)" {
  run _py "$WF"
  echo "$output"
  [[ "$status" -eq 0 ]]
}

@test "structure check fails when the test-suite job gains a secret, a permission or a credentialed checkout" {
  local bad="$BATS_TEST_TMPDIR/bad.yml"
  # a secret in env
  python3 - "$WF" "$bad" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
doc["jobs"]["test-suite"].setdefault("env", {})["X"] = "${{ secrets.GH_PAT_DON_PETRY }}"
yaml.safe_dump(doc, open(sys.argv[2], "w"))
PY
  run _py "$bad"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"references secrets"* ]]
  # a non-empty permissions block
  python3 - "$WF" "$bad" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
doc["jobs"]["test-suite"]["permissions"] = {"contents": "read"}
yaml.safe_dump(doc, open(sys.argv[2], "w"))
PY
  run _py "$bad"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"permissions must be"* ]]
  # a checkout that persists credentials (the default)
  python3 - "$WF" "$bad" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
doc["jobs"]["test-suite"]["steps"].insert(0, {"uses": "actions/checkout@abc"})
yaml.safe_dump(doc, open(sys.argv[2], "w"))
PY
  run _py "$bad"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"checks out the repository"* ]]
}

@test "dev-lead-reusable.yml: the test-suite job runs the guard from the handoff and verifies its digest" {
  run python3 - "$WF" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
t = doc["jobs"]["test-suite"]
text = yaml.safe_dump(t)
assert "tjh_run_suite" in text, "test-suite must run tjh_run_suite"
assert "needs.dispatch.outputs.handoff_sha256" in text, "test-suite must verify the handoff digest"
assert "DEV_LEAD_TEST_CMD" in (t.get("env") or {}), "test-suite must map DEV_LEAD_TEST_CMD"
assert "result" in (t.get("outputs") or {}), "test-suite must output the verdict"
p = yaml.safe_dump(doc["jobs"]["push"])
assert "needs.dispatch.outputs.handoff_sha256" in p, "push must verify the handoff digest"
PY
  echo "$output"
  [[ "$status" -eq 0 ]]
}
