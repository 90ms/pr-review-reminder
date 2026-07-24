#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prr-formula-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

SHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
OUTPUT="$TEST_ROOT/Formula/pr-review-reminder.rb"

"$ROOT/Scripts/render-homebrew-formula.sh" "1.2.3" "$SHA" "$OUTPUT"

grep -q 'v1.2.3.tar.gz' "$OUTPUT"
grep -q "sha256 \"$SHA\"" "$OUTPUT"
if grep -q '^  version ' "$OUTPUT"; then
    echo "Formula should infer its version from the source URL" >&2
    exit 1
fi
if grep -q '__VERSION__\|__SHA256__' "$OUTPUT"; then
    echo "Formula placeholders were not fully rendered" >&2
    exit 1
fi

if "$ROOT/Scripts/render-homebrew-formula.sh" "not-a-version" "$SHA" "$OUTPUT"; then
    echo "Invalid version unexpectedly succeeded" >&2
    exit 1
fi
if "$ROOT/Scripts/render-homebrew-formula.sh" "1.2.3" "bad-sha" "$OUTPUT"; then
    echo "Invalid SHA unexpectedly succeeded" >&2
    exit 1
fi

echo "Homebrew Formula renderer tests passed"
