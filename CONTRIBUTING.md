# Contributing

Thank you for helping improve PR Review Reminder.

## Before you start

- Search existing issues before opening a new one.
- For substantial behavior or architecture changes, open an issue first.
- Never include access tokens, private repository content, or other secrets in
  issues, test fixtures, logs, screenshots, or commits.
- Follow the repository guidance in `AGENTS.md` and
  `.harness/generated/AGENTS.md`.

## Development

The project requires macOS 14 or later and a Swift toolchain compatible with
the package manifest.

```bash
swift build
swift test
./Scripts/build-app.sh
```

The last command assembles `dist/PR Review Reminder.app` for local testing.
Authentication remains delegated to the installed `gh`, `claude`, and
`codex` CLIs.

## Pull requests

1. Keep each change focused and preserve unrelated work.
2. Add or update tests for behavior changes.
3. Run the build and test commands above.
4. Update documentation and `CHANGELOG.md` when the user-visible behavior
   changes.
5. Explain the motivation, validation performed, and any remaining tradeoffs
   in the pull request.

By contributing, you agree that your contributions will be licensed under the
MIT License.
