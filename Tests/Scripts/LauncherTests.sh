#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prr-launcher-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

APP="$TEST_ROOT/Cellar/pr-review-reminder/0.0.0/libexec/PR Review Reminder.app"
APPLICATIONS="$TEST_ROOT/Applications"
EXECUTABLE="$APP/Contents/MacOS/PRReviewReminder"
mkdir -p "$(dirname "$EXECUTABLE")"
cp /usr/bin/true "$EXECUTABLE"

export PRR_APP_PATH="$APP"
export PRR_APPLICATIONS_DIR="$APPLICATIONS"

actual="$("$ROOT/Scripts/pr-review-reminder" --print-app-path)"
test "$actual" = "$APP"

"$ROOT/Scripts/pr-review-reminder" --doctor
"$ROOT/Scripts/pr-review-reminder" --install-app
test -L "$APPLICATIONS/PR Review Reminder.app"
test "$(readlink "$APPLICATIONS/PR Review Reminder.app")" = "$APP"

"$ROOT/Scripts/pr-review-reminder" --install-app

UPDATED_APP="$TEST_ROOT/Cellar/pr-review-reminder/0.0.1/libexec/PR Review Reminder.app"
UPDATED_EXECUTABLE="$UPDATED_APP/Contents/MacOS/PRReviewReminder"
mkdir -p "$(dirname "$UPDATED_EXECUTABLE")"
cp /usr/bin/true "$UPDATED_EXECUTABLE"
export PRR_APP_PATH="$UPDATED_APP"
"$ROOT/Scripts/pr-review-reminder" --install-app
test "$(readlink "$APPLICATIONS/PR Review Reminder.app")" = "$UPDATED_APP"

"$ROOT/Scripts/pr-review-reminder" --uninstall-app
test ! -e "$APPLICATIONS/PR Review Reminder.app"

"$ROOT/Scripts/pr-review-reminder" --help >/dev/null

echo "Launcher tests passed"
