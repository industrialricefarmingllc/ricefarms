~/ci.sh "$@" && git add . && git commit --amend --no-edit && git push -u origin $(git branch --show-current)
