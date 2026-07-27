---
name: validate-github-prs
description: Validate one or more GitHub pull requests for combined merge safety and release readiness without publishing reviews or changing GitHub state. Use when asked to review current or Draft PRs, determine whether several PRs can merge together, find cross-PR conflicts or dependencies, simulate a merge order, assess whether the integrated result is safe to release, or produce a pre-merge go/no-go report.
---

# Validate GitHub PRs

Produce an evidence-based report. Keep GitHub and the source worktree unchanged.
Treat individual green CI as necessary but insufficient when validating multiple PRs.

## Safety contract

- Read repository agent instructions and project commands before validation.
- Use `gh` and `git` with the caller's existing authentication. Never read or print tokens.
- Do not post reviews, approvals, comments, labels, status checks, or Slack messages.
- Do not push, merge, close, edit, or convert PRs from Draft.
- Do not edit source files to make a PR pass. Report required fixes against the relevant PR.
- Preserve dirty worktrees. Perform checkouts and merge simulations only in temporary worktrees.
- Record exact base and head SHAs. Invalidate the result if any reviewed SHA changes.

## Resolve the review set

1. Use explicit PR numbers when supplied.
2. Otherwise list all open PRs targeting the repository's default branch, including Draft PRs.
3. Capture for every PR:
   - number, title, URL, author, Draft state, base and head SHA;
   - body, linked issues, labels, commits, changed files, and diff;
   - mergeability, review decision, unresolved review threads, and required checks.
4. Identify stacked PRs, explicit dependencies, shared files or symbols, and changes to build,
   packaging, deployment, configuration, persistence, permissions, or public behavior.
5. State exclusions when the requested set is narrowed. Never silently omit a failing PR.

Resolve the current remote base SHA through the GitHub ref API or a fetched remote ref when
`gh pr view` does not expose it. Use GitHub metadata only as a snapshot. Fetch the exact SHAs and
inspect the code locally.

## Review each PR

For each PR:

1. Compare the linked issue or stated intent with the implementation.
2. Review the complete diff for correctness, regressions, security, secrets, error handling,
   concurrency, data compatibility, documentation, and unrelated scope.
3. Verify that tests exercise the changed behavior rather than only adjacent helpers.
4. Run focused validation in an isolated worktree at that PR head.
5. Run every repository-required command available on the current platform. Report platform-only
   checks precisely; never infer success from an unavailable check.
6. Confirm required CI belongs to the recorded head SHA and is successful, not merely queued,
   stale, skipped, or successful on an older commit.

Classify findings as `blocker`, `high`, `medium`, or `low`. Cite file and line evidence when
possible. A Draft flag is a workflow gate, not proof that the implementation is defective.

## Validate the combined result

1. Fetch the current target branch and all recorded PR head SHAs.
2. Derive a merge order from stacked branches and semantic dependencies. If no dependency exists,
   state the assumed order.
3. Create a temporary detached worktree from the recorded base SHA.
4. Simulate the repository's intended merge strategy locally, one PR at a time. Use only local
   commits with a disposable validation identity.
5. After each merge:
   - record textual conflicts;
   - inspect overlapping behavior even when Git reports no conflict;
   - run focused tests for the newly combined area.
6. On the fully integrated tree, run the project build, test, automation, packaging, and static
   validation commands that apply.
7. For independent PRs that touch the same files, APIs, state, or configuration, test an alternate
   plausible order when practical. Explain when combinatorial testing is intentionally bounded.
8. Remove temporary worktrees and validation refs after recording results. Preserve them only when
   the user explicitly asks for debugging artifacts.

Do not resolve conflicts during validation. A conflict or semantic overwrite is a finding for the
owning PRs.

## Assess release readiness

Keep merge readiness separate from release readiness.

Require all of the following for `READY` release status:

- combined required tests and checks pass on the recorded integrated content;
- no blocker or high-severity finding remains;
- configuration, stored-data, API, and upgrade compatibility are understood;
- packaging and release inputs are consistent;
- user-facing behavior and operational documentation are current;
- security, privacy, observability, rollback, and manual platform gates are addressed.

Use `CONDITIONAL` when code can merge but a named CI, environment, signing, notarization, manual
UI, migration, or staged rollout gate remains. Use `NOT_READY` for conflicts, failing validation,
unsafe behavior, missing required coverage, or release blockers. Use `BLOCKED` when evidence
cannot be obtained safely.

For this repository, inspect `.github/workflows/ci.yml`, the bundle build, launcher and Formula
tests, Synology automation tests when relevant, and `docs/MACOS_VALIDATION.md`. Do not call a
release ready when required macOS or distribution checks remain unverified.

## Report

Lead with the two verdicts and recommended order:

```text
MERGE_READINESS: READY|CONDITIONAL|NOT_READY|BLOCKED
RELEASE_READINESS: READY|CONDITIONAL|NOT_READY|BLOCKED
BASE: <branch>@<sha>
PRS: #<number>@<sha>, ...
MERGE_ORDER: #<number> -> #<number> -> ...
```

Then provide:

1. blockers and high-severity findings;
2. per-PR findings;
3. cross-PR conflicts, dependencies, and semantic interactions;
4. checks run with exact outcomes and CI links;
5. remaining manual or environment gates;
6. the condition that invalidates the report, normally any base or head SHA change.

Say explicitly when no findings exist. Recommend fixes and revalidation, but do not publish an
approval or claim that a future GitHub-generated merge commit was tested when only a local
simulation was tested.
