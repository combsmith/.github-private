#!/usr/bin/env bash
set -euo pipefail
# test_sonarcloud_workflow.sh — regression guard for issue #699.
#
# The SonarCloud Analysis workflow installs JDK 21 via setup-java and points the
# scanner at it. But unless JRE provisioning is explicitly disabled, the scanner
# still downloads its own JRE from scanner.sonarcloud.io, which intermittently
# returns "HTTP 403 Forbidden" and failed ~26.5% of runs. This test asserts the
# scan args pin the scanner JRE to the setup-java JDK so that flaky download
# never happens.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${SCRIPT_DIR}/../.github/workflows/sonarcloud.yml"
fail=0

if ! command -v yq >/dev/null 2>&1; then
  echo "FAIL: yq is required to run this test"
  exit 2
fi

if [[ ! -f "$WORKFLOW" ]]; then
  echo "FAIL: $WORKFLOW not found"
  exit 1
fi

args=$(yq '.jobs.sonarcloud.steps[] | select(.name == "SonarCloud Scan") | .with.args' "$WORKFLOW")

if [[ -z "$args" ]] || [[ "$args" = "null" ]]; then
  echo "FAIL: could not find SonarCloud Scan step args in $WORKFLOW"
  exit 1
fi

if ! grep -Fq "sonar.scanner.skipJreProvisioning=true" <<<"$args"; then
  echo "FAIL: $WORKFLOW SonarCloud Scan args must set -Dsonar.scanner.skipJreProvisioning=true"
  echo "  Without it the scanner downloads its own JRE from scanner.sonarcloud.io,"
  echo "  which intermittently returns HTTP 403 and fails the run (issue #699)."
  fail=1
fi

# shellcheck disable=SC2016  # single quotes are intentional: search for literal ${{ }} expression
if ! grep -Fq 'sonar.scanner.javaExePath=${{ steps.setup_java.outputs.path }}/bin/java' <<<"$args"; then
  echo "FAIL: $WORKFLOW SonarCloud Scan args must set -Dsonar.scanner.javaExePath to the setup-java JDK path (\${{ steps.setup_java.outputs.path }}/bin/java)"
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: $WORKFLOW pins the scanner JRE to the setup-java JDK"
fi
exit "$fail"
