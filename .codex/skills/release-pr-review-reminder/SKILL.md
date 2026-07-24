---
name: release-pr-review-reminder
description: Prepare, publish, and verify a PR Review Reminder semantic release and its Homebrew Formula update. Use when asked to cut a version, deploy changes, publish a GitHub Release, update 90ms/homebrew-tap, or check that an app release reached Homebrew.
---

# Release PR Review Reminder

Release only from `90ms/pr-review-reminder`. Keep every mutation reviewable and
never place credentials, tokens, certificate data, or machine-specific values in
the repository.

## 1. Load the project contract

1. Read `.harness/generated/AGENTS.md` and `.harness/project.json`.
2. Read `docs/RELEASING.md`, `CHANGELOG.md`, `.github/workflows/release.yml`,
   `Scripts/render-homebrew-formula.sh`, and the Homebrew Formula template.
3. Respect the repository boundary that GitHub reviews, comments, approvals, and
   application-generated issues require explicit user actions. A release request
   does not authorize unrelated publishing.

## 2. Run preflight checks

1. Confirm `origin` is `90ms/pr-review-reminder`.
2. Preserve unrelated changes. Stop if the worktree is dirty and the changes
   cannot be safely separated.
3. Fetch tags without rewriting local work. Inspect the latest tag and GitHub
   Release.
4. Confirm the target commit is on `main`, matches `origin/main`, and has a
   successful `ci.yml` run containing build, test, launcher, bundle assembly,
   and bundle validation.
5. Inspect `CHANGELOG.md` Unreleased entries and recommend:
   - patch for compatible fixes;
   - minor for compatible features;
   - major for breaking behavior.
6. State the proposed version and obtain the user's version decision when it was
   not already explicit.

Do not tag a commit whose CI is pending, failed, cancelled without a superseding
successful run, or attached to a different SHA.

## 3. Prepare the release commit

1. Move Unreleased notes under `## [x.y.z] - YYYY-MM-DD`.
2. Leave an empty `## [Unreleased]` section.
3. Update comparison links and search the repository for stale current-version
   examples or milestone claims. Change only references that describe the new
   release.
4. Run `git diff --check`.
5. Commit with `docs(release): prepare version x.y.z` and push `main`.
6. Wait for the exact release-preparation SHA to pass `ci.yml`.

## 4. Require the tag approval gate

Before creating a tag, show:

- exact version and tag;
- exact commit SHA;
- CI result and URL;
- that an ad-hoc build will be produced when Developer ID secrets are absent;
- that Homebrew tap publication will follow.

Create and push the annotated `v<semver>` tag only after explicit user approval.
Never move, replace, or delete an existing tag.

## 5. Publish and verify GitHub Release

1. Watch `release.yml` through completion.
2. Verify the Release is marked latest and contains both:
   - `PR-Review-Reminder-<version>.zip`;
   - `PR-Review-Reminder-<version>.zip.sha256`.
3. Report whether signing/notarization ran or the workflow produced an ad-hoc
   build.
4. If the workflow fails, inspect the failed step and stop. Do not recreate or
   delete release artifacts without approval.

## 6. Update Homebrew through a PR

The Release workflow may open the tap PR when `HOMEBREW_TAP_TOKEN` is configured.
If it reports that the token is absent, use the currently authenticated `gh`
session only when the release request includes Homebrew publication:

1. Download the tag source archive over HTTPS and compute SHA-256 locally.
2. Clone `90ms/homebrew-tap` into a `mktemp -d` directory.
3. Create `automation/pr-review-reminder-<version>`.
4. Run this repository's `Scripts/render-homebrew-formula.sh`; do not hand-edit
   the Formula.
5. Commit and push only `Formula/pr-review-reminder.rb`.
6. Open a tap PR describing the source tag and required install/test/audit CI.
7. Wait for all tap checks.
8. Show the PR and check result. Merge only after explicit user approval unless
   the user already explicitly requested end-to-end release publication,
   including Homebrew.

Never commit an auth token or copy the local `gh` token into repository secrets.

## 7. Verify the published state

1. Confirm the tap `main` Formula URL is the new tag and its SHA matches the
   downloaded source archive.
2. Confirm the GitHub Release and Formula expose the same version.
3. Confirm the source worktree is clean and `HEAD == origin/main`.
4. Report the release URL, tap PR, CI results, signing mode, and the user command:

```bash
brew update
brew upgrade pr-review-reminder
```

State separately any checks that still require a real macOS session, using
`docs/MACOS_VALIDATION.md`. Never mark unchecked GUI, VoiceOver, notification,
or login-item behavior as verified by CI.

## Failure rules

- Stop on checksum, version, repository, CI, or Formula mismatches.
- Do not use destructive Git commands.
- Do not delete tags, Releases, branches, or artifacts as an automatic rollback.
- Do not bypass branch protection, failed checks, Homebrew audit, or approval
  gates.
- Keep partially successful states explicit: for example, “Release published;
  tap PR not created because credentials are unavailable.”
