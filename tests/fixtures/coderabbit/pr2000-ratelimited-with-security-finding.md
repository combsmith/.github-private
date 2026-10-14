<!-- This is an auto-generated comment: summarize by coderabbit.ai -->
<!-- review_stack_entry_start -->

<a href="https://app.coderabbit.ai/change-stack/petry-projects/.github-private/pull/2000?cs_source=review_comment"><img src="https://storage.googleapis.com/coderabbit_public_assets/review-stack-in-coderabbit-ui-dark.svg?v=2" alt="Review in Change Stack →" width="220" height="32"></a>

Navigate logical layers of code changes, visualize relationships, and explore their blast radius.

<!-- review_stack_entry_end -->
<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->

> [!WARNING]
> ## Review limit reached
> 
> You've used all free OSS reviews for now. Wait for the free limit to reset to keep reviewing this public repository.
> 
> **Next included review available in 9 minutes.**
> 
> [Check out review usage here](https://app.coderabbit.ai/dashboard/review-capacity?orgId=a994a7f2-c841-43f7-8a43-35243a386f9f).
> 
> <details>
> <summary>View limit details</summary>
> 
> **Limit details:** You’ve used the included review currently available.
> 
> [Learn how review limits work](https://docs.coderabbit.ai/management/plans#rate-limits).
> 
> **Review configuration:**
> 
> <details>
> <summary>⚙️ Run configuration</summary>
> 
> **Configuration used**: Organization UI
> 
> **Review profile**: ASSERTIVE
> 
> **Plan**: Advanced
> 
> **Run ID**: `76c5a2c2-16ab-4255-9994-7596afc76c78`
> 
> </details>
> 
> <details>
> <summary>📥 Commits</summary>
> 
> Reviewing files that changed from the base of the PR and between 769f3dda691839f3099812ccdb687b1f802b2dc9 and 2c77e41d28d7c9fdd5c2675ba36bb490404c6c26.
> 
> </details>
> 
> <details>
> <summary>📒 Files selected for processing (1)</summary>
> 
> * `tests/dev-lead/unit/test_maintainer_resolve_comment.bats`
> 
> </details>
> 
> </details>

<!-- end of auto-generated comment: rate limited by coderabbit.ai -->

<!-- recent_review_start -->

No actionable comments were generated in the recent review. 🎉

<details>
<summary>ℹ️ Recent review info</summary>

<details>
<summary>⚙️ Run configuration</summary>

**Configuration used**: Organization UI

**Review profile**: ASSERTIVE

**Plan**: Advanced

**Run ID**: `78d02d76-4e35-4aa2-a270-0b733e22db88`

</details>

<details>
<summary>📥 Commits</summary>

Reviewing files that changed from the base of the PR and between 9b79eabff600a61727c5e4f50c72ef679f190639 and 769f3dda691839f3099812ccdb687b1f802b2dc9.

</details>

<details>
<summary>⛔ Files ignored due to path filters (1)</summary>

* `scripts/lib/reviewer-sources.tsv` is excluded by `!**/*.tsv`

</details>

<details>
<summary>📒 Files selected for processing (2)</summary>

* `tests/dev-lead/unit/test_maintainer_comment_gate.bats`
* `tests/test_reviewer_sources.bats`

</details>

**Included review availability:** This review used your included allowance. Your plan provides up to 1 included review per hour; 0 remain after this review.

</details>

---



<!-- recent_review_end -->
<!-- walkthrough_start -->

<details>
<summary>📝 Summary</summary>

<!-- This is an auto-generated comment: release notes by coderabbit.ai -->

## Summary by CodeRabbit

* **Tests**
  * Expanded validation of review-status handling for Codex, CodeRabbit, and Qodo service notices.
  * Confirmed that matching usage-limit and trial-ended notices clear the review gate, while genuine review findings continue to block it.
  * Added coverage for notice wording embedded in review text and Codex’s bot-login variant.
  * Updated info-status exclusions for Cubic while retaining exclusions for CodeAnt and Graphite.

<!-- end of auto-generated comment: release notes by coderabbit.ai -->
## Walkthrough

Tests cover Codex, CodeRabbit, and Qodo service-notice patterns. They verify that matching notices clear the maintainer comment gate and that review findings block it.

### Changes

**Service-notice disposition**

|Layer / File(s)|Summary|
|---|---|
|**Reviewer pattern matching tests** <br> `tests/test_reviewer_sources.bats`|Tests retrieve each bot’s info-status pattern and check notice and review-body examples. The negative test updates which sources are expected to have no pattern.|
|**Maintainer gate outcome tests** <br> `tests/dev-lead/unit/test_maintainer_comment_gate.bats`|Tests expect Codex, CodeRabbit, and Qodo notices to clear the gate, including Codex’s `[bot]` login. Tests expect genuine review findings to block it.|

<!-- change_assessment_start -->
**Priority:** ➖ Normal







**Estimated code review effort:** 2 (Simple) | ~10 minutes

<!-- change_assessment_commit:"769f3dda691839f3099812ccdb687b1f802b2dc9" -->
**Change:** Bug fix · **Severity of issue fixed:** Medium
<!-- change_assessment_end -->

</details>

<!-- walkthrough_end -->
<!-- final_review_risk_start -->
**Merge Risk:** _⚪ Minimal_ · up to `769f3`
<!-- final_review_risk_coverage:{"sourceCommitId":"769f3dda691839f3099812ccdb687b1f802b2dc9","coveredCommitId":"769f3dda691839f3099812ccdb687b1f802b2dc9","kind":"reviewed"} -->

This PR adds test coverage for reviewer service-notice patterns and the maintainer gate. It does not change production behavior and carries no actionable merge risk.
<!-- final_review_risk_end -->
<!-- architecture_review_start -->
### Security Architecture Review

**Security architecture risk:** _🟡 Moderate_ · up to `769f3`

The new notice patterns can also clear comments that begin with a recognized notice and then contain substantive findings. This weakens an approval safeguard. The exposure is limited to comments attributed to three registered reviewers; ordinary commenters cannot obtain the exemption merely by copying the notice text.

**Retained concerns**
- **Medium · security · inferred:** New exemptions classify an entire registered-reviewer comment as clean when only its opening notice matches. A complete Codex, CodeRabbit, or Qodo notice followed by a substantive finding therefore escapes verified disposition. These identities had no notice exemption at the canonical base. Passing this gate permits progression through the remaining approval checks, although attacker control of such bot-authored content and a resulting merge are unproven.

<details>
<summary>Security review details</summary>

**Security Blast Radius**
- _inferred_ — The affected surface is issue comments attributed to the three registered reviewers on PRs evaluated with this registry. One matching prefix exempts the whole comment, including any appended findings. Broader repository deployment or tenant exposure is not established.

**Security Findings and Attack Paths**
- _inferred_ — A registered bot's comment containing a complete recognized notice followed by a finding is dropped before disposition enforcement. Exploitation would require influencing content published under that bot's identity or controlling the account; neither capability is proven. This is a source-supported control weakness, not a verified external exploit.

**Trust Boundaries and Controls**
- _observed_ — Notice matching is author-specific, not a body-only exemption for arbitrary commenters. Other undispositioned comments remain blockers, and a separate review-thread gate follows this check. Those controls do not restore disposition enforcement for a misclassified issue comment.

**Resilience and Maintainability Implications**
- _observed_ — Registry loading failures produce an empty exemption map, while snapshot parsing failures or absent verdicts block evaluation. Each invocation recalculates the blocker count from its supplied snapshot; there is no persisted notice-classification state in the evaluator.

**Hardening Proposals**
- _proposed_ — Define accepted complete notice bodies, including documented benign suffixes, and retain disposition enforcement whenever additional unrecognized content remains.


</details>

<!-- architecture_review_end -->
<!-- pre_merge_checks_walkthrough_start -->

<details>
<summary>🚥 Pre-merge checks | ✅ 3 | ❌ 1 | ❓ 1</summary>

### ❌ Failed checks (1 warning, 1 inconclusive)

|      Check name     | Status         | Explanation                                                                                                                                                                                               | Resolution                                                                                                                                                                                                                                        |
| :-----------------: | :------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
|  Docstring Coverage | ⚠️ Warning     | Docstring coverage is 33.33% which is insufficient. The required threshold is 80.00%. Docstring coverage is scoped to functions touched by this diff. Analyzed 3 functions across 2 files.                | Write docstrings for the functions missing them to satisfy the coverage threshold.                                                                                                                                                                |
| Linked Issues check | ❓ Inconclusive | The changes add focused tests for Codex, CodeRabbit, and Qodo service notices. The tests cover matching notices and non-matching review bodies, including mid-text and quoted variants. The summary also… | Provide reviewable evidence for the excluded registry and bot-path behavior, or include an independent test result that proves each required pattern is narrowly matched, documented as no-finding-only, and still requires `--reason` while ref… |

<details>
<summary>✅ Passed checks (3 passed)</summary>

|         Check name         | Status   | Explanation                                                                                                                                                                                               |
| :------------------------: | :------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
|         Title check        | ✅ Passed | The title clearly identifies the main change: extending info_status_pattern handling for Codex, Qodo, and CodeRabbit usage-limit notices. It is overly long but remains specific and related to the pull… |
|      Description check     | ✅ Passed | The description includes the required Problem, Risk, Test plan, Rollback, and Monitoring sections. It links issue `#1995` and provides testing, rollback, and monitoring details. The optional Summary and… |
| Out of Scope Changes check | ✅ Passed | The reported changes are limited to maintainer-gate and reviewer-source tests, plus the reviewer registry reported in the PR summary. These changes directly support issue `#1995` by validating service-n… |

</details>

<details>
<summary>Full details: Linked Issues check</summary>

**Explanation**

The changes add focused tests for Codex, CodeRabbit, and Qodo service notices. The tests cover matching notices and non-matching review bodies, including mid-text and quoted variants. The summary also reports registry changes. However, `scripts/lib/reviewer-sources.tsv` is intentionally excluded, and that file is required to verify the declared patterns, their tight anchoring, the no-finding documentation, and the `--reason` bot-path requirement. The provided evidence also does not establish that the reported bot-path authorization concern was fixed.

**Resolution**

Provide reviewable evidence for the excluded registry and bot-path behavior, or include an independent test result that proves each required pattern is narrowly matched, documented as no-finding-only, and still requires `--reason` while refusing genuine findings.

</details>

</details>

<!-- pre_merge_checks_walkthrough_end -->
<!-- finishing_touch_checkbox_start -->

<details>
<summary>✨ Finishing Touches 💡 1</summary>

<!-- finishing_touch_suggestion:docstrings -->
<details open>
<summary>📝 Generate docstrings 💡</summary>

- [ ] <!-- {"checkboxId":"3e1879ae-f29b-4d0d-8e06-d12b7ba33d98"} --> Commit to this branch
- [ ] <!-- {"checkboxId":"7962f53c-55bc-4827-bfbf-6a18da830691"} --> Create a new PR

</details>
<details open>
<summary>🧪 Generate unit tests (beta)</summary>

- [ ] <!-- {"checkboxId": "6ba7b810-9dad-11d1-80b4-00c04fd430c8", "radioGroupId": "utg-output-choice-group-unknown_comment_id"} --> Commit to this branch
- [ ] <!-- {"checkboxId": "f47ac10b-58cc-4372-a567-0e02b2c3d479", "radioGroupId": "utg-output-choice-group-unknown_comment_id"} --> Create a new PR

</details>

</details>

<!-- finishing_touch_checkbox_end -->

<!-- autopilot:start -->
- [ ] <!-- {"checkboxId":"2708ad07-9f24-4260-9c11-7dc76a49f2e3"} --> <strong title="Keep fixing CodeRabbit findings and required CI, and resolving merge conflicts">Autopilot</strong> · Keep fixing CodeRabbit findings and required CI, and resolving merge conflicts

> Autopilot is currently an internal CodeRabbit preview.
<!-- autopilot:end -->
<!-- tips_start -->

---

Thanks for using [CodeRabbit](https://coderabbit.ai?utm_source=oss&utm_medium=github&utm_campaign=petry-projects/.github-private&utm_content=2000)! It's free for OSS, and your support helps us grow. If you like it, consider giving us a shout-out.

<details>
<summary>❤️ Share</summary>

- [X](https://twitter.com/intent/tweet?text=I%20just%20used%20%40coderabbitai%20for%20my%20code%20review%2C%20and%20it%27s%20fantastic%21%20It%27s%20free%20for%20OSS%20and%20offers%20a%20free%20trial%20for%20the%20proprietary%20code.%20Check%20it%20out%3A&url=https%3A//coderabbit.ai)
- [Mastodon](https://mastodon.social/share?text=I%20just%20used%20%40coderabbitai%20for%20my%20code%20review%2C%20and%20it%27s%20fantastic%21%20It%27s%20free%20for%20OSS%20and%20offers%20a%20free%20trial%20for%20the%20proprietary%20code.%20Check%20it%20out%3A%20https%3A%2F%2Fcoderabbit.ai)
- [Reddit](https://www.reddit.com/submit?title=Great%20tool%20for%20code%20review%20-%20CodeRabbit&text=I%20just%20used%20CodeRabbit%20for%20my%20code%20review%2C%20and%20it%27s%20fantastic%21%20It%27s%20free%20for%20OSS%20and%20offers%20a%20free%20trial%20for%20proprietary%20code.%20Check%20it%20out%3A%20https%3A//coderabbit.ai)
- [LinkedIn](https://www.linkedin.com/sharing/share-offsite/?url=https%3A%2F%2Fcoderabbit.ai&mini=true&title=Great%20tool%20for%20code%20review%20-%20CodeRabbit&summary=I%20just%20used%20CodeRabbit%20for%20my%20code%20review%2C%20and%20it%27s%20fantastic%21%20It%27s%20free%20for%20OSS%20and%20offers%20a%20free%20trial%20for%20proprietary%20code)

</details>


<sub>Comment `@coderabbitai help` to get the list of available commands.</sub>

<!-- tips_end -->
