#!/bin/bash

# Script to uppercase the first letter of unpushed commit messages

# Get the current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Get the remote tracking branch
REMOTE_BRANCH="origin/$CURRENT_BRANCH"

# Check if remote branch exists
if ! git rev-parse --verify "$REMOTE_BRANCH" > /dev/null 2>&1; then
  echo "Remote branch $REMOTE_BRANCH does not exist"
  exit 1
fi

# Get unpushed commits
UNPUSHED_COMMITS=$(git rev-list "$REMOTE_BRANCH..HEAD")

if [ -z "$UNPUSHED_COMMITS" ]; then
  echo "No unpushed commits found"
  exit 0
fi

# Interactive rebase to edit commit messages
GIT_SEQUENCE_EDITOR="sed -i 's/^pick /reword /' " git rebase -i "$REMOTE_BRANCH"

# Function to uppercase first letter
uppercase_first() {
  echo "$1" | sed 's/^\(.\)/\U\1/'
}

# Process each commit
while IFS= read -r commit; do
  MESSAGE=$(git log -1 --format=%B "$commit")
  FIRST_CHAR=$(echo "$MESSAGE" | head -c 1)

  if [[ "$FIRST_CHAR" =~ [a-z] ]]; then
    NEW_MESSAGE=$(uppercase_first "$MESSAGE")
    git commit --amend -m "$NEW_MESSAGE" --no-edit
  fi
done <<< "$UNPUSHED_COMMITS"

echo "Done! First letters of unpushed commits have been uppercased."
