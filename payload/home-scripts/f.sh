#!/usr/bin/env bash
set -euo pipefail

q="${1:?usage: $0 <filename-or-pattern>}"

file="$(rg --files --hidden --no-ignore \
  | fzf --exact --query "$q" --select-1 | head -n1)"

[[ -n "${file}" ]] || { echo "No match found: $q" >&2; exit 1; }

if command -v bat >/dev/null 2>&1; then
  bat --style=plain --paging=always --color=always -- "$file"
elif command -v pygmentize >/dev/null 2>&1; then
  pygmentize -g -- "$file" | less -R
else
  less -R -- "$file"
fi

