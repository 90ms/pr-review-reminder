# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2026-07-28

### Added

- Reviews with no inline comments or review points expose a localized
  "No issues · Approve" action with a prefilled approval message.
- Review settings can discover Markdown guidance from a repository's default
  branch, let the selected Claude/Codex CLI classify relevant review,
  convention, and architecture documents, and apply imports by repository and
  `AGENTS.md` directory scope.

### Changed

- Settings are organized into General, Review, Automation, Data, and Advanced;
  app updates now live under General.
- Prompt composition no longer exposes Unified/Base + Files modes. Inline
  guidance, local files, and imported repository documents are always combined.

### Removed

- Deployment-specific auxiliary services, container configuration, and
  operating documentation that are not part of the macOS application.

## [0.5.1] - 2026-07-27

### Fixed

- External commands inherit the app's environment unless a command explicitly
  supplies a restricted environment, restoring `gh` keychain authentication.
- GitHub dependency checks scope the active `github.com` account, distinguish
  authentication failures from API timeouts, and retry timed-out reads over
  HTTP/1.1 when the local `gh` HTTP/2 client stalls.

## [0.5.0] - 2026-07-27

### Added

- A repository-local `$validate-github-prs` skill reviews individual and combined
  PR changes for merge and release readiness without changing GitHub state.
- Review prompts can compose a base template with one or more persisted skill
  files, and inline comment previews remain editable and individually removable.
- Dependabot monitors GitHub Actions and CodeQL scans the Swift code path.

### Changed

- AI CLI runs use an isolated temporary working directory, a minimal inherited
  environment, finite timeouts, and read-only/non-writing tool restrictions.
- External GitHub and dependency-diagnostic commands now have explicit finite
  timeouts.

### Fixed

- Configured review skill files that cannot be read, or templates missing the
  required `{{SKILL}}` placeholder, now stop analysis with a visible error.
- Feedback issue creation retries without labels only for label-specific errors
  and keeps the result visible with a warning listing omitted labels.
- Editing or deleting the first, middle, or last inline comment no longer risks
  changing a neighboring comment because preview rows now use stable identities.
- AI analysis preserves its timeout when the final stdin command is assembled.

## [0.4.0] - 2026-07-27

### Added

- Separate inboxes for pull requests awaiting my review and unapproved formal
  review feedback on pull requests I authored, including status classification,
  new-feedback counts, duplicate notification suppression, and direct GitHub links.
- Local history for submitted feedback issues with open, closed, and resolved
  status refresh; successful submission now clears the form and closes its window.
- Completed PR reviews now expose a direct "Review again" action that fetches
  the current PR head and diff before running a fresh analysis.
- Settings are grouped into General, Review, Automation, and Data tabs.
- A repository-local `$implement-github-issue` skill for implementing an
  explicitly approved issue with tests, documentation, and reviewable commits.

### Fixed

- Pull request refresh now preserves completed analysis while updating current
  pull request metadata.
- Feedback issue status refresh continues updating other records when one issue
  lookup fails.

## [0.3.1] - 2026-07-24

### Changed

- Successful in-app Homebrew updates now launch the updated application and
  terminate the old instance automatically, while retaining a manual retry when
  relaunch fails.

### Added

- The next launch detects an unclean previous session and offers a privacy-safe
  diagnostic issue draft; GitHub submission still requires explicit user action.

## [0.3.0] - 2026-07-24

### Added

- Pull request details provide focused Review, Changes, and Side-by-side layouts.
- Homebrew updates show tap, version, build, link, and restart stages with
  operation-specific failures, cancellation, and an explicit restart action.
- Settings show storage locations, sizes, last-save times, and persistence
  failures; corrupt history JSON is backed up before recovery.
- GitHub refresh diagnostics record successful retries, rate-limit failures,
  timestamps, and the 1,000-result Search API ceiling.
- Diff file filtering, previous/next changed-line navigation, and inline-comment
  links that jump to the matching file, side, and line.
- Recent scheduled refresh results persist across launches and show failures in
  Settings; scheduled failures can trigger a notification.
- A launch-at-login preference and a quit confirmation for active work.
- Release automation can open a reviewable Homebrew tap Formula pull request
  when its optional token is configured.

### Fixed

- Diff loading failures now show the error and a retry action instead of an
  indefinite progress indicator, with empty diffs handled separately.
- Persisted schedule state initializes without accessing partially initialized
  application state.

## [0.2.2] - 2026-07-24

### Added

- Settings can check the installed Homebrew Formula against the latest tap
  version and install an update on explicit user action.

### Changed

- User feedback now always targets the `90ms/pr-review-reminder` issue tracker.
- Diff content is anchored at the top-leading edge and includes changed-file
  navigation that scrolls to the selected file.

### Fixed

- The settings button now opens a dedicated SwiftUI window in packaged Homebrew
  builds instead of relying on an AppKit responder selector.

## [0.2.1] - 2026-07-24

### Fixed

- Homebrew source builds now install the bundled ICNS asset without invoking
  sandbox-incompatible Quick Look tooling.

## [0.2.0] - 2026-07-24

### Added

- Public repository community health files and macOS continuous integration.
- History detail/diff viewing, current-head re-review, retention, opt-out, and delete-all controls.
- Configurable Codex cost estimates and a rolling local review-token budget.
- Bundled application icon and localized diff/usage labels.
- Process timeouts and cancellation support for external commands.
- User-facing review cancellation with distinct cancelled and timed-out states.
- Bounded GitHub read retries and visible AI diff truncation warnings.
- Search pagination up to 1,000 results and bounded concurrent cache lookups.
- Tag-driven Developer ID signing, notarization, and GitHub Release workflow.
- Homebrew source-build Formula template, safe app launcher, and tap CI seed.

### Changed

- Long diff lines use horizontal scrolling.
- Inline comments and optional approval are submitted as one GitHub review.
- Window titles react to the selected application language.
- CI and all targets now use Swift 6 language mode on macOS 15.
- The menu shows the next scheduled run and adds VoiceOver labels to icon controls.
- Release tags support ad-hoc ZIP/checksum output when Developer ID is not configured.
- App packaging supports an injected output directory and Homebrew sandbox mode.

### Fixed

- Renewed GitHub review requests are no longer hidden by an older review.
- Publishing is blocked when the PR head changed after analysis.

## [0.1.0] - 2026-07-24

### Added

- macOS menu-bar workflow for finding pull requests awaiting review.
- AI-assisted summaries and review drafts through the Claude and Codex CLIs.
- Editable inline comments, review preview, and explicit publishing controls.
- Review history, cached results, scheduling, notifications, and localization.

[Unreleased]: https://github.com/90ms/pr-review-reminder/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/90ms/pr-review-reminder/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/90ms/pr-review-reminder/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/90ms/pr-review-reminder/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/90ms/pr-review-reminder/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/90ms/pr-review-reminder/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/90ms/pr-review-reminder/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/90ms/pr-review-reminder/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/90ms/pr-review-reminder/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/90ms/pr-review-reminder/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/90ms/pr-review-reminder/releases/tag/v0.1.0
