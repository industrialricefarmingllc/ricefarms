#!/bin/bash
clear

STASHED=0
STASH_REF=""

# Stash all changes first. Unlike direct lint/test runs, this script will assume the last commit is to be analyzed.
# Format changes are then also automatically applied to this last commit.
# Why? Because that's the only way to reasonably ensure format changes are actually committed. I forgot once
# and it left a failed CI test on github and that made me feel bad :(
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  unstaged=0
  git diff --quiet -- || unstaged=1
  if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    unstaged=1
  fi

  if [[ $unstaged -eq 1 ]]; then
    if [ -t 0 ]; then
      read -r -p "Working changes found. This script will only analyze the last commit. Stash and continue? [yes/no] " ANSWER
    else
      echo "Working changes found, but no TTY available to prompt. Exiting."
      exit 1
    fi

    case "${ANSWER,,}" in
      y|yes)
        echo "Stashing unstaged/untracked changes (keeping staged changes)..."
        STASH_REF=$(git stash push --keep-index -u -m "pre-nx-format-$(date -u +%Y%m%d%H%M%S)" 2>/dev/null || true)
        if [[ -n "$STASH_REF" && "$STASH_REF" != "No local changes to save" ]]; then
          echo "Stashed: $STASH_REF"
          STASHED=1
        fi
        ;;
      n|no)
        exit 1
        ;;
      *)
        echo "Unrecognized answer. Aborting."
        exit 1
        ;;
    esac
  fi
fi

cleanup() {
  if [[ $STASHED -eq 1 ]]; then
    echo "Restoring stashed changes..."
    if ! git stash pop -q; then
      echo "git stash pop failed; attempting git stash apply..."
      if ! git stash apply -q; then
        echo "Failed to restore stash automatically. Run 'git stash list' and apply/pop manually."
      fi
    fi
  fi
}
trap cleanup EXIT

set -e

~/lint.sh "$@" && ~/amend.sh && ~/test.sh "$@"
