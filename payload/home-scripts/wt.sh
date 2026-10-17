#!/usr/bin/env bash
set -euo pipefail

# w: worktree helper (script form)
# Usage: w <subcommand> [args...]
# Subcommands: add <name>, cd, ls, merge, pull, remove, sh

usage() {
    cat <<EOF
Usage: $(basename "$0" | sed 's/\.sh$//') <subcommand> [args...]

Subcommands:
  add <name>    Create a worktree one level up from the current directory.
                New branches start from the current branch and merge back into it.
                Folder name = <package-name>-<name> with /,\\ -> '-'; then cd into it.
  cd            Select a worktree branch to cd into (uses fzf).
  ls            List all worktrees (alias for 'git worktree list').
  merge         Update from the parent branch, then merge back into it and delete the worktree.
  pull          Merge the recorded parent branch into the current worktree branch.
  remove        Delete the current worktree (does not delete main repo).
  sh <cmd>      Select a worktree and run <cmd> inside it.
EOF
    exit 1
}

err() { printf '%s\n' "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }
cyan() { printf '\033[36m%s\033[0m' "$1"; }

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

load_merge_input() {
    local file_path="$1"

    [[ -f "$file_path" ]] || return 1

    local saved_scope saved_description
    saved_scope=$(sed -n '1p' "$file_path")
    saved_description=$(sed -n '2p' "$file_path")

    saved_scope=$(trim "$saved_scope")
    saved_description=$(trim "$saved_description")

    [[ -n "$saved_scope" && -n "$saved_description" ]] || return 1

    MERGE_SCOPE="$saved_scope"
    MERGE_DESCRIPTION="$saved_description"
    return 0
}

save_merge_input() {
    local file_path="$1"
    local scope="$2"
    local description="$3"

    {
        printf '%s\n' "$scope"
        printf '%s\n' "$description"
    } > "$file_path"
}

clear_merge_input() {
    local file_path="$1"
    rm -f -- "$file_path"
}

prompt_required() {
    local prompt="$1"
    local value=""

    while [[ -z "$value" ]]; do
        read -r -p "$prompt" value
        value=$(trim "$value")
    done

    printf '%s\n' "$value"
}

force_delete_path() {
    local path="$1"

    [[ -e "$path" ]] || return 0

    if rm -rf -- "$path" 2>/dev/null; then
        return 0
    fi

    err "Removal needs elevated permissions for '$path'; retrying with sudo."
    sudo rm -rf -- "$path"
}

run_worktree_hook() {
    local parent_repo="$1"
    local wt_path="$2"
    local event="$3"
    local hook_name="$4"
    local hook_path=".githooks/${hook_name}"

    [[ -f "${wt_path}/${hook_path}" ]] || return 0

    info "Running worktree cleanup hook for ${event} ..."
    (
        cd "$wt_path" &&
        WT_EVENT="$event" \
        WT_PARENT_REPO="$parent_repo" \
        WT_WORKTREE_PATH="$wt_path" \
        sh "$hook_path"
    ) >&2
}

# sanitize a string for filesystem use: replace / and \ with '-', collapse hyphens, trim edges
sanitize() {
    local s="$1"
    printf '%s' "$s" | tr '/\\' '-' | sed 's/-\{2,\}/-/g; s/^-*//; s/-*$//'
}

project_name_from_package_json() {
    local repo_root package_json project_name

    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    package_json="${repo_root}/package.json"
    [[ -f "$package_json" ]] || return 1

    project_name=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$package_json" | head -n 1)
    [[ -n "$project_name" ]] || return 1

    printf '%s\n' "$project_name"
}

current_branch_name() {
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
    [[ "$branch" != "HEAD" ]] || return 1
    printf '%s\n' "$branch"
}

branch_parent_config_key() {
    local branch="$1"
    printf 'branch.%s.wt-parent\n' "$branch"
}

record_branch_parent() {
    local branch="$1"
    local parent_branch="$2"
    git config --local "$(branch_parent_config_key "$branch")" "$parent_branch"
}

record_branch_parent_if_missing() {
    local branch="$1"
    local parent_branch="$2"
    local key
    key=$(branch_parent_config_key "$branch")

    if ! git config --local --get "$key" >/dev/null 2>&1; then
        git config --local "$key" "$parent_branch"
    fi
}

parent_branch_for() {
    local branch="$1"
    local key
    key=$(branch_parent_config_key "$branch")
    git config --local --get "$key"
}

current_branch_name_at() {
    local repo_path="$1"
    local branch
    branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
    [[ "$branch" != "HEAD" ]] || return 1
    printf '%s\n' "$branch"
}

worktree_path_for_branch() {
    local repo_path="$1"
    local branch="$2"
    local line current_path current_branch

    current_path=""
    current_branch=""
    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                current_path=${line#worktree }
                current_branch=""
                ;;
            branch\ refs/heads/*)
                current_branch=${line#branch refs/heads/}
                if [[ "$current_branch" == "$branch" && -n "$current_path" ]]; then
                    printf '%s\n' "$current_path"
                    return 0
                fi
                ;;
        esac
    done < <(git -C "$repo_path" worktree list --porcelain)

    return 1
}

update_current_branch_from_upstream() {
    local branch="$1"
    local upstream

    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || upstream=""
    if [[ -z "$upstream" ]]; then
        info "No upstream configured for ${branch}; skipping pull."
        return 0
    fi

    if ! git pull --ff-only >&2; then
        err "Error: failed to update ${branch} from ${upstream}."
        return 1
    fi
}

resolve_parent_branch() {
    local branch="$1"
    local parent_branch

    parent_branch=$(parent_branch_for "$branch" 2>/dev/null) || parent_branch=""
    if [[ -n "$parent_branch" ]]; then
        printf '%s\n' "$parent_branch"
        return 0
    fi

    if git show-ref --verify --quiet "refs/heads/main"; then
        printf 'main\n'
        return 0
    fi

    return 1
}

# cmd: add <name>
cmd_add() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        err "Usage: w add <name>"
        exit 1
    fi

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        err "Error: run 'w add' from a git repository or worktree."
        exit 1
    fi

    local parent_branch
    parent_branch=$(current_branch_name) || {
        err "Error: w add requires the current branch to be checked out."
        exit 1
    }

    local parent_repo
    parent_repo=$(git rev-parse --show-toplevel 2>/dev/null) || {
        err "Error: cannot determine repository root."
        exit 1
    }

    local project_name safe_part worktree_dir worktree_path
    project_name=$(project_name_from_package_json) || {
        err "Error: could not read project name from package.json at the repository root."
        exit 1
    }

    safe_part=$(sanitize "$name")
    if [[ -z "$safe_part" ]]; then
        err "Error: resulting directory suffix is empty"
        exit 1
    fi

    worktree_dir=$(sanitize "${project_name}-${safe_part}")
    worktree_path="../worktrees/${worktree_dir}"

    if [[ -e "$worktree_path" ]]; then
        err "Error: destination '$worktree_path' already exists"
        exit 1
    fi

    # If branch exists, reuse it; otherwise create new branch at HEAD and add worktree.
    if git show-ref --verify --quiet "refs/heads/${name}"; then
        git worktree add "$worktree_path" "$name"
        record_branch_parent_if_missing "$name" "$parent_branch"
    else
        # create the new branch from the current branch and remember where it should merge back
        git worktree add -b "$name" "$worktree_path" HEAD
        record_branch_parent "$name" "$parent_branch"
    fi

    worktree_path=$(cd "$worktree_path" && pwd) || {
        err "Error: failed to resolve created worktree path."
        exit 1
    }

    if ! run_worktree_hook "$parent_repo" "$worktree_path" create "worktree-create.sh"; then
        err "Error: worktree create hook failed."
        exit 1
    fi

    echo "__WT_CD__:$worktree_path"
}

# helper: find parent repo path from a worktree .git file (expects to be run inside worktree)
parent_repo_from_worktree() {
    local gitfile=".git"
    if [[ ! -f $gitfile ]]; then
        return 1
    fi
    local gitdir
    gitdir=$(sed -n 's/^gitdir: //p' "$gitfile") || return 1
    (cd "${gitdir}/../../.." 2>/dev/null && pwd) || return 1
}

ensure_worktree_merge_ready() {
    local this_branch="$1"
    local commit_message="${2:-Complete ${this_branch}}"
    local auto_commit_changes="${3:-1}"

    if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        if [[ -n $(git diff --name-only --diff-filter=U) ]]; then
            err "Error: this worktree already has an in-progress merge with unresolved conflicts."
            err "Resolve conflicts here, commit the result, then run 'w merge' again."
            exit 1
        fi

        info "Finishing in-progress merge in ${this_branch} before continuing ..."
        git commit --no-edit >&2
    elif [[ "$auto_commit_changes" == "1" && -n $(git status --porcelain) ]]; then
        info "Committing local worktree changes on ${this_branch} before merge ..."
        git add -A
        git commit -m "$commit_message" >&2
    fi
}

merge_parent_into_worktree() {
    local this_branch="$1"
    local parent_repo="$2"
    local target_branch="$3"

    if ! git -C "$parent_repo" show-ref --verify --quiet "refs/heads/${target_branch}"; then
        err "Error: parent repository does not have a '${target_branch}' branch"
        exit 1
    fi

    info "Updating worktree branch ${this_branch} with ${target_branch} ..."
    if ! git merge --no-ff --no-edit "$target_branch" >&2; then
        err "Error: merge conflicted in the worktree."
        err "Resolve conflicts here, commit the result, then run 'w merge' again."
        exit 1
    fi

    printf '%s\n' "$target_branch"
}

# cmd: merge
cmd_merge() {
    # must be inside a worktree ('.git' is a file)
    if [[ -d .git ]]; then
        err "Error: you are in the main repository; run 'w merge' from a worktree."
        exit 1
    fi
    if [[ ! -f .git ]]; then
        err "Error: cannot find .git in this directory."
        exit 1
    fi

    local this_branch
    this_branch=$(current_branch_name) || { err "Error: cannot determine current branch"; exit 1; }

    if [[ -n $(git diff --name-only) || -n $(git ls-files --others --exclude-standard) ]]; then
        err "You have unstaged changes or untracked files. Stage and commit them before merging."
        exit 1
    fi

    local parent_repo gitdir wt_head target_branch wt_path target_checkout
    parent_repo=$(parent_repo_from_worktree) || { err "Error: cannot locate parent repository"; exit 1; }
    gitdir=$(sed -n 's/^gitdir: //p' .git) || { err "Error: failed to read gitdir from .git"; exit 1; }
    wt_path=$(git rev-parse --show-toplevel 2>/dev/null) || { err "Error: cannot determine worktree path."; exit 1; }
    target_branch=$(resolve_parent_branch "$this_branch") || target_branch=""

    local scope description merge_input_file
    merge_input_file="${gitdir}/wt-merge-input"

    if load_merge_input "$merge_input_file"; then
        scope="$MERGE_SCOPE"
        description="$MERGE_DESCRIPTION"
        info "Using saved merge input: [${scope}] ${description}"
    else
        scope=$(prompt_required "Scope: ")
        description=$(prompt_required "Description: ")
    fi

    save_merge_input "$merge_input_file" "$scope" "$description"

    local commit_message
    commit_message="[${scope}] ${description} (${this_branch})"

    if [[ -z "$target_branch" ]]; then
        err "Error: no recorded parent branch for ${this_branch}."
        err "Create the worktree with 'w add' so it can merge back into its source branch."
        exit 1
    fi

    target_checkout=$(worktree_path_for_branch "$parent_repo" "$target_branch") || target_checkout="$parent_repo"

    if ! run_worktree_hook "$parent_repo" "$wt_path" merge "worktree-merge.sh"; then
        err "Error: worktree merge hook failed in ${wt_path}."
        exit 1
    fi

    ensure_worktree_merge_ready "$this_branch" "$commit_message"

    pushd "$target_checkout" >/dev/null || exit 1

    if [[ -n $(git status --porcelain) ]]; then
        popd >/dev/null
        err "Error: target branch checkout has local changes."
        err "Commit or stash them in ${target_checkout}, then run 'w merge' again."
        exit 1
    fi

    if ! git show-ref --verify --quiet "refs/heads/${target_branch}"; then
        popd >/dev/null
        err "Error: parent repository does not have a '${target_branch}' branch"
        exit 1
    fi

    if [[ "$target_checkout" == "$parent_repo" ]]; then
        if ! git switch "$target_branch" >&2; then
            popd >/dev/null
            err "Error: failed to switch parent repository to ${target_branch}."
            exit 1
        fi
    else
        if [[ $(current_branch_name_at "$target_checkout") != "$target_branch" ]]; then
            popd >/dev/null
            err "Error: target worktree at ${target_checkout} is not on ${target_branch}."
            exit 1
        fi
    fi

    if ! update_current_branch_from_upstream "$target_branch"; then
        popd >/dev/null
        exit 1
    fi

    popd >/dev/null

    merge_parent_into_worktree "$this_branch" "$parent_repo" "$target_branch" >/dev/null

    pushd "$target_checkout" >/dev/null || exit 1

    # ensure branch exists in parent; if not, create it pointing at the worktree HEAD
    if ! git show-ref --verify --quiet "refs/heads/${this_branch}"; then
        wt_head=$(git --git-dir="$gitdir" rev-parse HEAD 2>/dev/null) || wt_head=""
        if [[ -z "$wt_head" ]]; then
            popd >/dev/null
            err "Error: cannot determine worktree HEAD to create branch in parent repo"
            exit 1
        fi
        git branch "$this_branch" "$wt_head" || { popd >/dev/null; err "Error: failed to create branch in target checkout"; exit 1; }
    fi

    info "Merging worktree branch ${this_branch} into ${target_branch} ..."
    if ! git merge --no-ff -m "$commit_message" "$this_branch" >&2; then
        popd >/dev/null
        err "Error: merge failed; resolve conflicts in the parent repo."
        err "The worktree was left intact because the merge did not complete."
        exit 1
    fi

    if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        popd >/dev/null
        err "Error: merge did not complete cleanly in ${target_checkout}."
        err "Resolve conflicts there, commit, then run 'w merge' again."
        exit 1
    fi

    popd >/dev/null

    clear_merge_input "$merge_input_file"

    WT_SKIP_HOOK=1 WT_CD_TARGET="$target_checkout" cmd_remove
}

# cmd: cd
cmd_cd() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { err "Error: not in a git repository"; exit 1; }

    local project_name
    project_name=$(project_name_from_package_json) || project_name=""

    local line path branch
    local -a items paths
    while IFS= read -r line; do
        path=$(awk '{print $1}' <<< "$line")
        branch=$(awk '{print $NF}' <<< "$line")
        branch=${branch#[}
        branch=${branch%]}
        [[ -z "$branch" ]] && continue
        if [[ "$branch" == *"HEAD"* ]]; then
            branch=$(basename "$path")
            [[ -n "$project_name" && "$branch" == "$project_name-"* ]] && branch="${branch#"$project_name"-}"
        fi
        items+=("$branch")
        paths+=("$path")
    done < <(git worktree list 2>/dev/null) || { err "Error: cannot list worktrees"; exit 1; }

    if [[ ${#items[@]} -eq 0 ]]; then
        err "No worktree branches found."
        exit 1
    fi

    local choice
    if command -v fzf &>/dev/null; then
        choice=$(
            for ((i=0; i<${#items[@]}; i++)); do
                printf '◆ %s\n' "${items[$i]}"
            done | fzf --color 'fg+:magenta,hl+:magenta' --prompt 'Select work branch > '
        ) || return 1
        choice=${choice#◆ }
    else
        err "fzf is required for 'w cd'"
        exit 1
    fi

    for ((i=0; i<${#items[@]}; i++)); do
        if [[ "${items[$i]}" == "$choice" ]]; then
            echo "__WT_CD__:${paths[$i]}"
            return
        fi
    done
}

# cmd: ls
cmd_ls() {
    git worktree list
}

# cmd: remove
cmd_remove() {
    local cd_target="${WT_CD_TARGET:-}"

    # must be inside a worktree
    if [[ -d .git ]]; then
        err "Error: this is the main repository – nothing to remove."
        exit 1
    fi
    if [[ ! -f .git ]]; then
        err "Error: cannot find .git in this directory."
        exit 1
    fi

    local wt_path gitdir parent_repo this_branch parent_branch
    wt_path=$(git rev-parse --show-toplevel 2>/dev/null) || { err "Error: cannot determine worktree path."; exit 1; }

    gitdir=$(sed -n 's/^gitdir: //p' .git) || { err "Error: failed to read gitdir"; exit 1; }
    parent_repo=$(cd "${gitdir}/../../.." 2>/dev/null && pwd) || { err "Error: cannot determine parent repository path"; exit 1; }

    if [[ "$wt_path" == "$parent_repo" ]]; then
        err "Error: refusing to remove the main repository."
        exit 1
    fi

    if [[ -z "$cd_target" ]]; then
        this_branch=$(current_branch_name) || this_branch=""
        if [[ -n "$this_branch" ]]; then
            parent_branch=$(resolve_parent_branch "$this_branch") || parent_branch=""
            if [[ -n "$parent_branch" ]]; then
                cd_target=$(worktree_path_for_branch "$parent_repo" "$parent_branch") || cd_target=""
            fi
        fi
    fi

    if [[ "${WT_SKIP_HOOK:-0}" != "1" ]]; then
        if ! run_worktree_hook "$parent_repo" "$wt_path" remove "worktree-remove.sh"; then
            err "Error: worktree remove hook failed."
            exit 1
        fi
    fi

    info "Removing worktree at ${wt_path} ..."
    if ! (cd "$parent_repo" && git worktree remove "$wt_path" --force >&2); then
        info "git worktree remove failed; deleting worktree directory directly and pruning registration ..."
        force_delete_path "$wt_path" || { err "Error: failed to fully delete worktree directory"; exit 1; }
        (cd "$parent_repo" && git worktree prune --expire now >&2) || { err "Error: failed to prune stale worktree metadata"; exit 1; }
    elif [[ -e "$wt_path" ]]; then
        force_delete_path "$wt_path" || { err "Error: failed to fully delete worktree directory"; exit 1; }
    fi

    if [[ -z "$cd_target" ]]; then
        cd_target="$parent_repo"
    fi

    echo "__WT_CD__:$cd_target"
}

# cmd: pull
cmd_pull() {
    if [[ -d .git ]]; then
        err "Error: you are in the main repository; run 'w pull' from a worktree."
        exit 1
    fi
    if [[ ! -f .git ]]; then
        err "Error: cannot find .git in this directory."
        exit 1
    fi

    local this_branch parent_repo target_branch
    this_branch=$(current_branch_name) || { err "Error: cannot determine current branch"; exit 1; }
    ensure_worktree_merge_ready "$this_branch" "Complete ${this_branch}" 0

    parent_repo=$(parent_repo_from_worktree) || { err "Error: cannot locate parent repository"; exit 1; }
    target_branch=$(resolve_parent_branch "$this_branch") || target_branch=""

    if [[ -z "$target_branch" ]]; then
        err "Error: no recorded parent branch for ${this_branch}."
        err "Create the worktree with 'w add' so it can merge back into its source branch."
        exit 1
    fi

    merge_parent_into_worktree "$this_branch" "$parent_repo" "$target_branch" >/dev/null
}

# cmd: sh <command...>
cmd_sh() {
    if [[ $# -eq 0 ]]; then
        err "Usage: w sh <command> [args...]"
        exit 1
    fi
    [[ "$1" == "--" ]] && shift

    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { err "Error: not in a git repository"; exit 1; }

    local project_name
    project_name=$(project_name_from_package_json) || project_name=""

    local line path branch
    local -a items paths
    while IFS= read -r line; do
        path=$(awk '{print $1}' <<< "$line")
        branch=$(awk '{print $NF}' <<< "$line")
        branch=${branch#[}
        branch=${branch%]}
        [[ -z "$branch" ]] && continue
        if [[ "$branch" == *"HEAD"* ]]; then
            branch=$(basename "$path")
            [[ -n "$project_name" && "$branch" == "$project_name-"* ]] && branch="${branch#"$project_name"-}"
        fi
        items+=("$branch")
        paths+=("$path")
    done < <(git worktree list 2>/dev/null) || { err "Error: cannot list worktrees"; exit 1; }

    if [[ ${#items[@]} -eq 0 ]]; then
        err "No worktree branches found."
        exit 1
    fi

    local choice
    if command -v fzf &>/dev/null; then
        choice=$(
            for ((i=0; i<${#items[@]}; i++)); do
                printf '◆ %s\n' "${items[$i]}"
            done | fzf --color 'fg+:magenta,hl+:magenta' --prompt 'Select work branch > '
        ) || return 1
        choice=${choice#◆ }
    else
        err "fzf is required for 'w sh'"
        exit 1
    fi

    for ((i=0; i<${#items[@]}; i++)); do
        if [[ "${items[$i]}" == "$choice" ]]; then
            (cd "${paths[$i]}" && "$@")
            return
        fi
    done
}

# main dispatcher
main() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    local cmd="$1"; shift

    case "$cmd" in
        add)    cmd_add "$@" ;;
        cd)     cmd_cd "$@" ;;
        ls)     cmd_ls "$@" ;;
        merge)  cmd_merge "$@" ;;
        pull)   cmd_pull "$@" ;;
        remove) cmd_remove "$@" ;;
        sh)     cmd_sh "$@" ;;
        -h|--help) usage ;;
        *) err "w: unknown subcommand '$cmd'"; err "Available subcommands: add, cd, ls, merge, pull, remove"; exit 1 ;;
    esac
}

main "$@"
