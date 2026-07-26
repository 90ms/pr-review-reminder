---
name: implement-github-issue
description: Implement an explicitly approved GitHub issue in an isolated checkout, including tests, relevant documentation, and reviewable commits. Use when a maintainer or the Synology issue automation asks Codex to work a numbered issue from the repository's main branch and prepare a branch for a Draft PR.
---

# Implement GitHub Issue

Implement only the approved issue. Leave publishing, labels, Slack messages, Draft PR creation,
and merging to the surrounding automation.

## Preconditions

Require all of the following before editing:

- A repository and issue number supplied by the caller.
- The issue title, body, labels, and acceptance criteria available through `gh` or caller context.
- An isolated checkout on a branch named `codex/issue-<number>-<slug>` based on current
  `origin/main`.
- A clean worktree with no unrelated user changes.
- Repository agent instructions and project command configuration read in full.

Stop as `blocked` instead of guessing when the issue is ambiguous, conflicts with repository
instructions, lacks information needed for a safe implementation, or requires protected paths.

## Protected Boundaries

Do not:

- Modify `.github/workflows/**`, `.agents/**`, `.harness/**`, or `SECURITY.md`.
- Read, print, copy, or commit credentials, auth sessions, `.env` files, or machine-specific
  configuration.
- Push branches, create or update PRs, change issue labels, post comments, publish reviews,
  approve changes, merge, release, or deploy.
- Expand the issue into unrelated refactors or dependency upgrades.
- Disable tests or weaken safety checks to make validation pass.

If a protected change is genuinely necessary, preserve the worktree, explain why, and return
`blocked`.

## Workflow

1. Read the issue with `gh issue view` and confirm it is open and has the approval label provided
   by the caller.
2. Search for the affected code, existing tests, documentation, and repository conventions.
3. Write a short implementation plan tied to the issue acceptance criteria.
4. Reproduce bugs before fixing them when practical.
5. Implement the smallest complete change and add a regression test or focused test coverage.
6. Run the commands defined by repository guidance. On platforms that cannot run a required
   command, run safe portable checks and report the omitted macOS validation precisely.
7. Update only documentation affected by the behavior, configuration, operation, or user flow.
8. Inspect the complete diff for secrets, protected paths, unrelated edits, generated artifacts,
   and accidental formatting churn.
9. Create one or more logical commits with imperative Conventional Commit messages. Include
   `Refs #<number>` in each commit body.
10. Confirm the worktree is clean and the branch contains only commits intended for the issue.

Do not manufacture a change when the issue is already satisfied. Return `blocked` with the
evidence needed for a maintainer decision.

## Completion Report

When the caller supplies an output schema, return data matching that schema. Otherwise end with a
compact machine-readable summary in this exact shape:

```text
STATUS: completed|blocked|failed
ISSUE: <number>
SUMMARY: <one line>
TESTS: <commands and outcomes, or explicit reason not run>
DOCS: <updated paths, or none>
COMMITS: <short SHAs, or none>
RISKS: <remaining risks, CI-only checks, or none>
```

Use `completed` only when implementation, local validation, documentation review, and commits are
finished. Use `blocked` for a required human decision or protected-path change. Use `failed` for a
tool or validation failure that cannot be resolved safely.
