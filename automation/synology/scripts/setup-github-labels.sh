#!/bin/sh
set -eu

repository=${GITHUB_REPOSITORY:-${1:-}}
if [ -z "$repository" ]; then
  echo "usage: GITHUB_REPOSITORY=owner/repository $0" >&2
  exit 2
fi

create_label() {
  name=$1
  color=$2
  description=$3
  gh label create "$name" \
    --repo "$repository" \
    --color "$color" \
    --description "$description" \
    --force
}

create_label codex-ready 0E8A16 "Approved for Slack-gated Codex implementation"
create_label codex-notified 1D76DB "Slack approval message sent"
create_label codex-running FBCA04 "Codex implementation is running"
create_label codex-pr-open 5319E7 "Draft PR created by approved automation"
create_label codex-failed D73A4A "Automation failed; explicit retry required"
create_label codex-blocked B60205 "Automation requires a maintainer decision"
