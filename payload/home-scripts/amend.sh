#!/bin/bash
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add -A

  # Determine if there is anything to commit
  CHANGES_TO_COMMIT=0
  # If repo has commits, compare index to HEAD; otherwise check if index has contents
  if git rev-parse --verify --quiet HEAD >/dev/null; then
    if ! git diff --cached --quiet --exit-code HEAD --; then
      CHANGES_TO_COMMIT=1
    fi
  else
    # No HEAD yet — if there's anything staged, we should commit
    if ! git diff --cached --quiet --exit-code --; then
      CHANGES_TO_COMMIT=1
    fi
  fi

  if [[ $CHANGES_TO_COMMIT -eq 1 ]]; then
    echo "Amending changes into the last commit..."
    git commit --no-verify --no-edit --amend
  fi
fi
