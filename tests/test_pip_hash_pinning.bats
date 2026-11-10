#!/usr/bin/env bats
# Regression guard for issue #1240 (OpenSSF Scorecard: Pinned-Dependencies).
#
# Scorecard counts a `pip install` as pinned only when it runs with
# `--require-hashes`, which means every package and every transitive dependency
# has to be hash-pinned. A version pin (`pyyaml==6.0.3`) is not enough. So this
# repo's workflows install Python dependencies only from hash-pinned
# requirements files under requirements/ci/:
#
#   pip install --require-hashes --only-binary ":all:" -r requirements/ci/<set>.txt
#
# These tests fail when:
#   - a workflow `pip install` drops --require-hashes or --only-binary, or names a
#     package inline instead of reading it from a requirements/ci/ file;
#   - a referenced requirements file does not exist;
#   - a requirements file has an entry that is not `name==version` with at
#     least one `--hash=sha256:` value;
#   - dependabot stops tracking requirements/ci/, which would let the hashes go stale.
#
# Run with: bats tests/test_pip_hash_pinning.bats

setup() {
  cd "$(dirname "$BATS_TEST_FILENAME")/.."
  python3 -c 'import yaml' 2>/dev/null || skip "PyYAML is required"
}

@test "every workflow pip install is hash-pinned via requirements/ci (#1240)" {
  run python3 - <<'PY'
import glob, re, shlex, sys, os
import yaml

PIP = re.compile(r'(?:^|[\s;&|(])(?:python[0-9.]*\s+-m\s+)?pip[0-9.]*\s+install\b')
problems = []
found = 0

def steps_of(doc):
    for job in (doc.get("jobs") or {}).values():
        for step in (job or {}).get("steps") or []:
            if isinstance(step, dict) and isinstance(step.get("run"), str):
                yield step.get("name") or "<unnamed>", step["run"]

for path in sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml")):
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    for name, run in steps_of(doc):
        logical = re.sub(r'\\\n', ' ', run)
        for line in logical.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            m = PIP.search(stripped)
            if not m:
                continue
            found += 1
            where = f"{path} [{name}]: {stripped}"
            # Tokenize from the `install` subcommand up to a shell operator or trailing comment.
            rest = stripped[m.end():]
            try:
                toks = shlex.split(rest, comments=True)
            except ValueError as exc:
                problems.append(f"{where}\n    unparseable ({exc})")
                continue
            args = []
            for t in toks:
                if t in (";", "&&", "||", "|", ")") or t.startswith((";", "&", "|")):
                    break
                args.append(t)
            reqs, positional, flags = [], [], set()
            i = 0
            while i < len(args):
                a = args[i]
                if a in ("-r", "--requirement"):
                    if i + 1 < len(args):
                        reqs.append(args[i + 1])
                    i += 2
                    continue
                if a.startswith("--requirement="):
                    reqs.append(a.split("=", 1)[1])
                elif a == "--only-binary":
                    flags.add(a)
                    i += 2
                    continue
                elif a.startswith("-"):
                    flags.add(a.split("=", 1)[0])
                else:
                    positional.append(a)
                i += 1
            if "--require-hashes" not in flags:
                problems.append(f"{where}\n    missing --require-hashes")
            if "--only-binary" not in flags:
                problems.append(f"{where}\n    missing --only-binary (no source builds)")
            if positional:
                problems.append(f"{where}\n    inline package(s) {positional}: list them in requirements/ci/*.txt instead")
            if not reqs:
                problems.append(f"{where}\n    no -r requirements/ci/<set>.txt")
            for r in reqs:
                if not re.fullmatch(r'requirements/ci/[A-Za-z0-9._-]+\.txt', r):
                    problems.append(f"{where}\n    requirements file {r!r} is not under requirements/ci/")
                elif not os.path.isfile(r):
                    problems.append(f"{where}\n    requirements file {r!r} does not exist")

if found == 0:
    problems.append("no workflow pip install found: the scanner is broken")
print(f"scanned {found} pip install command(s)")
for p in problems:
    print("FAIL: " + p)
sys.exit(1 if problems else 0)
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "every requirements/ci file pins name==version with sha256 hashes (#1240)" {
  run python3 - <<'PY'
import glob, re, sys

problems = []
files = sorted(glob.glob("requirements/ci/*.txt"))
if not files:
    problems.append("no requirements/ci/*.txt files found")
REQ = re.compile(r'^([A-Za-z0-9][A-Za-z0-9._-]*)==([A-Za-z0-9.+!_-]+)((?:\s+--hash=sha256:[0-9a-f]{64})+)\s*$')
for path in files:
    text = open(path).read()
    entries = 0
    for raw in re.sub(r'\\\n', ' ', text).splitlines():
        line = raw.split(" #", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        entries += 1
        if not REQ.match(line):
            problems.append(f"{path}: not 'name==version --hash=sha256:...': {line[:120]}")
    if entries == 0:
        problems.append(f"{path}: no requirement entries")
for p in problems:
    print("FAIL: " + p)
sys.exit(1 if problems else 0)
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "dependabot tracks requirements/ci so the hashes stay current (#1240)" {
  run yq -r '.updates[] | select(.["package-ecosystem"] == "pip") | .directory' .github/dependabot.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"/requirements/ci"* ]]
}
