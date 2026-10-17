#!/usr/bin/env bash
# restore-old.sh
# Restores a file OR the *contents* of a directory from a given commit.
# For a directory the result is   <path>.old/   containing only the
# files/sub‑folders that were inside the original directory.

set -euo pipefail

# ------------------------------------------------------------
# 1️⃣  Argument handling
# ------------------------------------------------------------
if (( $# != 2 )); then
    echo "Usage: $0 <commit> <repo‑relative‑path>"
    exit 1
fi

commit=$1
rel_path=$2   # e.g. services/clotho/src/routes/proto/g/[stimulusId]

# ------------------------------------------------------------
# 2️⃣  Find out what Git stores at that path (blob = file, tree = dir)
# ------------------------------------------------------------
git_obj_type=$(git cat-file -t "${commit}:${rel_path}" 2>/dev/null || true)

if [[ -z "$git_obj_type" ]]; then
    echo "ERROR: Path \"$rel_path\" does not exist in commit $commit."
    exit 2
fi

# ------------------------------------------------------------
# 3️⃣  Build destination path
# ------------------------------------------------------------
if [[ "$git_obj_type" == "blob" ]]; then
    # --------- FILE ----------
    dir=$(dirname "$rel_path")
    fname=$(basename "$rel_path")
    base="${fname%.*}"
    ext="${fname##*.}"

    if [[ "$base" == "$fname" ]]; then   # no extension
        new_fname="${fname}.old"
    else
        new_fname="${base}.old.${ext}"
    fi
    dest="${dir}/${new_fname}"
else
    # --------- DIRECTORY ----------
    parent=$(dirname "$rel_path")
    leaf=$(basename "$rel_path")
    dest="${parent}/${leaf}.old"
fi

# ------------------------------------------------------------
# 4️⃣  Safety checks
# ------------------------------------------------------------
mkdir -p "$(dirname "$dest")"

if [[ -d "$dest" ]]; then
    echo "ERROR: Destination \"$dest\" already exists as a directory."
    exit 3
fi
if [[ -e "$dest" && ! -d "$dest" ]]; then
    echo "WARNING: File \"$dest\" already exists and will be overwritten."
fi

# ------------------------------------------------------------
# 5️⃣  Extraction
# ------------------------------------------------------------
if [[ "$git_obj_type" == "blob" ]]; then
    # Single file – use git show
    git show "${commit}:${rel_path}" > "$dest"
else
    # Directory – extract ONLY its contents
    mkdir -p "$dest"

    # Count how many components the input path has.
    # Example: "a/b/c" → 3 components → strip 3.
    IFS='/' read -ra parts <<< "$rel_path"
    strip_count=${#parts[@]}

    git archive --format=tar "${commit}" "${rel_path}" |
        tar -x -C "$dest" --strip-components=$strip_count
fi

# ------------------------------------------------------------
# 6️⃣  Completion message
# ------------------------------------------------------------
echo " → saved as $dest"

