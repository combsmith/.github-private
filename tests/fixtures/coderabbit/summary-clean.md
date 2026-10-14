<!-- This is an auto-generated comment: summarize by coderabbit.ai -->
<!-- review_stack_entry_start -->

<a href="https://app.coderabbit.ai/change-stack/petry-projects/.github-private/pull/2000?cs_source=review_comment"><img src="https://storage.googleapis.com/coderabbit_public_assets/review-stack-in-coderabbit-ui-dark.svg?v=2" alt="Review in Change Stack →" width="220" height="32"></a>

Navigate logical layers of code changes, visualize relationships, and explore their blast radius.

<!-- review_stack_entry_end -->

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

**Security architecture risk:** _⚪ Minimal_ · up to `769f3`

This PR adds test coverage only. It introduces no new trust boundary, credential path or authorization decision.

<!-- architecture_review_end -->
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
