#!/bin/bash

# Get recently written files in specified directory or current directory (last 10 minutes)
# Usage: ./recent_writes.sh [directory] [number_of_files]

DIR="${1:-$(pwd)}"
NUM_FILES="${2:-10}"

if [ ! -d "$DIR" ]; then
    echo "Error: Directory '$DIR' does not exist"
    exit 1
fi

echo "Recently written files in '$DIR' (last 10 minutes, showing $NUM_FILES files):"

# Spinning loader
spinner="/-\|"
i=0
show_spinner() {
    printf "\r${spinner:$((i++ % 4)):1} Scanning files..."
}

# Start spinner in background
while true; do
    show_spinner
    sleep 0.1
done &
SPINNER_PID=$!

# Get timestamp for 10 minutes ago
TEN_MIN_AGO=$(date -d "10 minutes ago" +%s)

# Find files and check modification time, excluding node_modules
RESULTS=$(find "$DIR" -type f -not -path "*/node_modules/*" -exec stat --format="%Y %n" {} \; 2>/dev/null | \
while read timestamp file; do
    if [ "$timestamp" -gt "$TEN_MIN_AGO" ]; then
        date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S" | tr -d '\n'
        echo " - $file"
    fi
done | sort -r | head -n "$NUM_FILES")

# Stop spinner
kill $SPINNER_PID 2>/dev/null
printf "\r\033[K"

# Display results
echo "$RESULTS"
