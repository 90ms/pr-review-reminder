# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Public repository community health files and macOS continuous integration.
- History detail/diff viewing, current-head re-review, retention, opt-out, and delete-all controls.
- Configurable Codex cost estimates and a rolling local review-token budget.
- Bundled application icon and localized diff/usage labels.
- Process timeouts and cancellation support for external commands.

### Changed

- Long diff lines use horizontal scrolling.
- Inline comments and optional approval are submitted as one GitHub review.
- Window titles react to the selected application language.

### Fixed

- Renewed GitHub review requests are no longer hidden by an older review.
- Publishing is blocked when the PR head changed after analysis.

## [0.1.0] - 2026-07-24

### Added

- macOS menu-bar workflow for finding pull requests awaiting review.
- AI-assisted summaries and review drafts through the Claude and Codex CLIs.
- Editable inline comments, review preview, and explicit publishing controls.
- Review history, cached results, scheduling, notifications, and localization.

[Unreleased]: https://github.com/90ms/pr-review-reminder/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/90ms/pr-review-reminder/releases/tag/v0.1.0
