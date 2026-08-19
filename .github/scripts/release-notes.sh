#!/usr/bin/env bash
# Print markdown release notes for a tag to stdout.
#
# Usage: TAG=v0.0.2 REPO_URL=https://github.com/owner/repo .github/scripts/release-notes.sh
#
# Commits are listed as "- <title> — @handle". A trailing "(#123)" becomes a
# link to the PR; commits without one link to their SHA instead.
#
# A "New contributors" section lists authors whose email has no commit anywhere
# before this range.
#
# GitHub handles are resolved via `gh api`, so this needs an authenticated gh
# (GH_TOKEN in CI, `gh auth login` locally). Commits whose author can't be
# resolved to an account fall back to the plain git author name.
set -euo pipefail

TAG="${TAG:?TAG is required}"
REPO_URL="${REPO_URL:?REPO_URL is required}"

# "https://github.com/owner/repo" -> "owner/repo"
REPO=$(printf '%s' "$REPO_URL" | sed 's|^.*://[^/]*/||')

PREV_TAG=$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)

if [ -n "$PREV_TAG" ]; then
  RANGE="$PREV_TAG..$TAG"
else
  RANGE="$TAG"
fi

# Cache lookups so repeat authors cost one API call, not one per commit.
CACHE_DIR=$(mktemp -d)
trap 'rm -rf "$CACHE_DIR"' EXIT

# handle_for <sha> <email> <author name> -> "@login", or the name if unresolvable
handle_for() {
  sha=$1 email=$2 name=$3
  cache_key=$(printf '%s' "$email" | tr -c 'A-Za-z0-9' '_')
  cache_file="$CACHE_DIR/$cache_key"

  if [ ! -f "$cache_file" ]; then
    # On failure gh writes the error body to stdout, so only trust it on exit 0.
    if ! login=$(gh api "repos/$REPO/commits/$sha" --jq '.author.login // empty' 2>/dev/null); then
      login=""
    fi
    if [ -n "$login" ]; then
      printf '@%s' "$login" > "$cache_file"
    else
      printf '%s' "$name" > "$cache_file"
    fi
  fi

  cat "$cache_file"
}

# Emails that already appear in history before this range. Authors missing from
# it are first-time contributors.
PRIOR_EMAILS="$CACHE_DIR/prior-emails"
if [ -n "$PREV_TAG" ]; then
  git log --pretty=tformat:'%ae' "$PREV_TAG" | sort -u > "$PRIOR_EMAILS"
else
  : > "$PRIOR_EMAILS"
fi

# The commit loop runs in a subshell, so it records new contributors on disk.
NEW_CONTRIBUTORS="$CACHE_DIR/new-contributors"
: > "$NEW_CONTRIBUTORS"

echo "## What's changed"
echo

# tformat (not format) so the last line ends in a newline and `read` sees it.
git log --no-merges --pretty=tformat:'%s%x09%an%x09%ae%x09%h' "$RANGE" | while IFS=$'\t' read -r subject author email hash; do
  # [0-9][0-9]* rather than \+ so this works under BSD sed too.
  pr=$(printf '%s' "$subject" | sed -n 's/.*(#\([0-9][0-9]*\))$/\1/p')
  if [ -n "$pr" ]; then
    subject=$(printf '%s' "$subject" | sed "s|(#$pr)\$|([#$pr]($REPO_URL/pull/$pr))|")
  else
    subject="$subject ([\`$hash\`]($REPO_URL/commit/$hash))"
  fi
  handle=$(handle_for "$hash" "$email" "$author")
  echo "- $subject — $handle"

  if ! grep -qxF "$email" "$PRIOR_EMAILS"; then
    if [ -n "$pr" ]; then
      where="[#$pr]($REPO_URL/pull/$pr)"
    else
      where="[\`$hash\`]($REPO_URL/commit/$hash)"
    fi
    echo "$handle	$where" >> "$NEW_CONTRIBUTORS"
    echo "$email" >> "$PRIOR_EMAILS"
  fi
done

if [ -s "$NEW_CONTRIBUTORS" ]; then
  echo
  echo "## New contributors"
  echo
  while IFS=$'\t' read -r handle where; do
    echo "- $handle made their first contribution in $where"
  done < "$NEW_CONTRIBUTORS"
fi

echo
if [ -n "$PREV_TAG" ]; then
  echo "**Full changelog**: $REPO_URL/compare/$PREV_TAG...$TAG"
fi
