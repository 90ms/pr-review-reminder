# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/90ms/pr-review-reminder/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/90ms/pr-review-reminder/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/90ms/pr-review-reminder/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/90ms/pr-review-reminder/releases/tag/v0.1.0
