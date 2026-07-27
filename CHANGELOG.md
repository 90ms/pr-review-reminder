# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- An optional Synology worker that scans labeled issues, requests approval with
  a Slack Socket Mode button, runs the locally authenticated Codex CLI in an
  isolated checkout, and opens a Draft PR.
- SQLite leases, protected-path checks, timeout recovery, CI result
  notifications, dry-run mode, Docker Compose deployment, and NAS setup
  documentation for the issue worker.
- A versioned file-queue protocol and separate Codex Runner image with an
  internal network, an OpenAI/ChatGPT allowlisted egress proxy, and heartbeat
  health checks.
- Persistent Controller/Runner job phases, an independent in-job heartbeat,
  rate-limited live Slack status, authorized manual refresh, and one-time stale
  or timeout warnings.

### Fixed

- Pull request refresh now preserves completed analysis while updating current
  pull request metadata.
- Feedback issue status refresh continues updating other records when one issue
  lookup fails.
- The Synology image now installs GitHub CLI from its official signed apt
  repository and verifies persistent headless-login support instead of using
  Debian's outdated community package.
- The container now overrides the host-side `GH_CONFIG_DIR` mount source with
  its in-container path so `gh` can find the persisted login.
- Failed and blocked issue jobs now both retain a Slack retry action.
- Controller-side validation restores trusted Git configuration and rejects
  protected paths, changed symlinks, invalid ancestry, and generated credential
  material before pushing a branch.
- The default Synology Compose deployment no longer requires PID, CPU CFS, or
  memory cgroups that are unavailable on some DSM kernels.
- Synology issue workspaces now ignore bind-mount executable-bit drift instead
  of treating every `100644` file as a protected-path modification.

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

[Unreleased]: https://github.com/90ms/pr-review-reminder/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/90ms/pr-review-reminder/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/90ms/pr-review-reminder/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/90ms/pr-review-reminder/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/90ms/pr-review-reminder/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/90ms/pr-review-reminder/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/90ms/pr-review-reminder/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/90ms/pr-review-reminder/releases/tag/v0.1.0
