# Cascade action — finalize verdict and prepare for posting

You are the final step of the cascading PR review. A previous tier (deep review or
security audit) has produced a verdict in `$FINAL_RESULT`. Your job is to:

1. Read the verdict
2. Compose the full review body
3. Write a final JSON to `$OUTPUT_FILE` using the steps below

The review will be posted by the bash script, not by this prompt.

> **Pre-fed PR context (epic #1101):** This step synthesizes the already-resolved
> verdict in `$FINAL_RESULT` (plus prior-tier context) into the posting body. It
> **does not fetch** the PR diff or metadata — so it needs no pre-fed-context
> rewire and is explicitly **out of scope** for the Story-5 (#1105) audit/single
> prompt changes.

## Inputs (environment variables)

- `$FINAL_RESULT` — path to verdict JSON from the resolving tier
- `$OUTPUT_FILE` — path where you MUST write the final verdict JSON
- `$PR_HEAD_SHA` — commit SHA that was reviewed
- `$FINAL_TIER` — which tier made the final call (deep+duck, deep, or audit)
- `$ENGINE_LABEL` — human-readable label for cascade models
- `$DUCK_ENGINE` — rubber duck engine (claude or copilot)
- `$DUCK_MODEL` — rubber duck model
- `$TRIAGE_RESULT` — triage verdict for context
- `$DOWNSTREAM_IMPACT_FILE` — (optional; set only when the downstream-impact pass
  is enabled) path to the `DOWNSTREAM_IMPACT` block listing the downstream consumer
  repos that pin a reusable workflow / shell lib / prompt this PR changes. May be
  the literal `(none)`. Used to surface an impacted-consumers note in the body.

## Steps

1. Read the verdict JSON and extract fields:
```bash
DECISION=$(jq -r '.decision' "$FINAL_RESULT")
RISK=$(jq -r '.risk' "$FINAL_RESULT")
SUMMARY=$(jq -r '.summary' "$FINAL_RESULT")
FINDINGS=$(jq -c '.findings // []' "$FINAL_RESULT")
AGREEMENT=$(jq -r '.agreement // ""' "$FINAL_RESULT")
ESCALATE_TO_AI=$(jq -r 'if .decision == "escalate" and .risk != "HIGH" then "true" else "false" end' "$FINAL_RESULT")
# metadata_only (#1551): true only when the decision is escalate/fix-requested AND
# EVERY blocking finding is fixable by editing PR metadata alone — the PR body, its
# labels, or its linked/closing issues — with NO code change (e.g. a `Closes #N`
# that would wrongly auto-close a staged issue, so the fix is "Refs #N"). When any
# blocking finding needs a code edit, this is false. It lets post-pr-review.sh stamp
# a metadata digest so the demanded metadata fix (which mints no commit) re-arms the
# re-review; a false value keeps commit-only re-arm. Default false.
METADATA_ONLY=$(jq -r 'if .decision == "escalate" and (.metadata_only == true) then "true" else "false" end' "$FINAL_RESULT")
# Marker vocabulary: "approved"/"escalated" — the posting guard and review-cycle
# consumers expect these exact strings, never the raw verdict word (#2169)
DECISION_MARKER=$([ "$DECISION" = "approve" ] && echo "approved" || echo "escalated")
```

2. Compose the review body. Write it to a temp file to avoid shell quoting issues:
```bash
cat > /tmp/cascade/review-body.txt << 'BODYEOF'
<!-- pr-review-agent v1 sha=PLACEHOLDER_SHA decision=PLACEHOLDER_DECISION risk=PLACEHOLDER_RISK -->

## Automated review — PLACEHOLDER_HEADING

**Risk:** PLACEHOLDER_RISK
**Reviewed commit:** `PLACEHOLDER_SHA`
**Cascade:** triage → PLACEHOLDER_TIER (PLACEHOLDER_ENGINE_LABEL)

### Summary
PLACEHOLDER_SUMMARY

### Cross-engine agreement (if deep+duck)
<If tier is deep+duck and agreement field exists, include this section>

### Findings
PLACEHOLDER_FINDINGS_LIST

---
_Reviewed by the PR-review cascade (PLACEHOLDER_ENGINE_LABEL). Reply if you need a human review._
BODYEOF
```

Replace each PLACEHOLDER with the actual values using sed. Then substitute the real values:
```bash
HEADING=$([ "$DECISION" = "approve" ] && echo "APPROVED ✓" || echo "NEEDS HUMAN REVIEW")
sed -i \
  -e "s|PLACEHOLDER_SHA|$PR_HEAD_SHA|g" \
  -e "s|PLACEHOLDER_DECISION|$DECISION_MARKER|g" \
  -e "s|PLACEHOLDER_RISK|$RISK|g" \
  -e "s|PLACEHOLDER_HEADING|$HEADING|g" \
  -e "s|PLACEHOLDER_TIER|$FINAL_TIER|g" \
  -e "s|PLACEHOLDER_ENGINE_LABEL|$ENGINE_LABEL|g" \
  -e "s|PLACEHOLDER_SUMMARY|$SUMMARY|g" \
  /tmp/cascade/review-body.txt
```

For findings, format each finding as a bullet and append:
```bash
# Remove the PLACEHOLDER_FINDINGS_LIST line and replace with formatted findings
FINDINGS_TEXT=$(echo "$FINDINGS" | jq -r '.[] | "- **\(.severity // "INFO")**: \(.description // .)"' 2>/dev/null || echo "- No specific findings")
sed -i "s|PLACEHOLDER_FINDINGS_LIST|$FINDINGS_TEXT|g" /tmp/cascade/review-body.txt
```

If the agreement field is non-empty and FINAL_TIER is "deep+duck", insert a cross-engine agreement section before Findings:
```bash
if [ -n "$AGREEMENT" ] && [ "$FINAL_TIER" = "deep+duck" ]; then
  sed -i "s|### Findings|### Cross-engine agreement\n$AGREEMENT\n\n### Findings|" /tmp/cascade/review-body.txt
fi
```

If `$DOWNSTREAM_IMPACT_FILE` is set, the file exists, and its contents are not the
literal `(none)`, insert a **Downstream impact** section before Findings so the
reviewer sees the blast radius right in the verdict (issue #752). When the block
is absent or `(none)`, add nothing — the body must carry no downstream note:
```bash
if [ -n "${DOWNSTREAM_IMPACT_FILE:-}" ] && [ -f "$DOWNSTREAM_IMPACT_FILE" ]; then
  DI_BLOCK=$(cat "$DOWNSTREAM_IMPACT_FILE")
  if [ -n "${DI_BLOCK//[[:space:]]/}" ] && [ "$DI_BLOCK" != "(none)" ]; then
    # Count impacted consumer repos (lines naming a "<owner>/<repo> (pins ...)").
    DI_COUNT=$(printf '%s\n' "$DI_BLOCK" | grep -cE '^[[:space:]]*- .+ \(pins ' || true)
    DI_NOTE="This change is consumed by ${DI_COUNT} downstream repo(s) that pin the affected reusable workflow / lib / prompt. Impacted consumers:"$'\n'"\`\`\`"$'\n'"${DI_BLOCK}"$'\n'"\`\`\`"
    # Write the note to a temp file and splice it in (avoids sed metachar issues
    # with the multi-line block).
    printf '### Downstream impact\n%s\n\n### Findings\n' "$DI_NOTE" > /tmp/cascade/di-section.txt
    awk 'BEGIN{while((getline l < "/tmp/cascade/di-section.txt")>0) s=s l "\n"} /^### Findings$/{if(s != "") printf "%s", s; else print; next} {print}' \
      /tmp/cascade/review-body.txt > /tmp/cascade/review-body.tmp && mv /tmp/cascade/review-body.tmp /tmp/cascade/review-body.txt
  fi
fi
```

3. Write the final verdict JSON to `$OUTPUT_FILE` using jq so all strings are properly escaped:
```bash
BODY=$(cat /tmp/cascade/review-body.txt)
jq -n \
  --arg decision "$DECISION" \
  --arg risk "$RISK" \
  --arg summary "$SUMMARY" \
  --argjson findings "$FINDINGS" \
  --arg body "$BODY" \
  --argjson escalate_to_ai "$ESCALATE_TO_AI" \
  --argjson metadata_only "$METADATA_ONLY" \
  '{decision: $decision, risk: $risk, summary: $summary, findings: $findings, body: $body, escalate_to_ai: $escalate_to_ai, metadata_only: $metadata_only}' \
  > "$OUTPUT_FILE"
```

4. Verify the output is valid:
```bash
jq -r '.decision' "$OUTPUT_FILE"
echo "Verdict written to $OUTPUT_FILE"
```

**IMPORTANT:** Do NOT print the JSON to stdout. Write it to `$OUTPUT_FILE` only. The bash script reads it from there.
