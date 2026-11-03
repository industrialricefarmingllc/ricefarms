#!/usr/bin/env bash
# build-template.sh — assemble the matugen input for the Lucid Discord theme.
#
# This theme is colour-only: it overrides Discord's own custom properties and
# leaves the base UI (layout, spacing, components) untouched. lucid-colors.css.in
# is the whole theme body; matugen renders it with the current palette.
#
# Run this only after editing lucid-colors.css.in.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
templates="$HOME/.config/matugen/templates"
out="$templates/lucid-discord.css"

mkdir -p "$templates"
{
    cat "$here/header.css"
    cat "$here/lucid-colors.css.in"
} > "$out.tmp"

# matugen fails on an unresolved placeholder much later, in the middle of a
# wallpaper change; catch a broken colours file here instead.
if ! rg -q '\{\{colors\.[a-z_]+\.default\.hex\}\}' "$out.tmp"; then
    echo "error: $here/lucid-colors.css.in has no matugen placeholders" >&2
    rm -f "$out.tmp"
    exit 1
fi

mv -f "$out.tmp" "$out"
echo "wrote $out"
