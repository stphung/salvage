#!/usr/bin/env bash
#
# find-missing-data.sh — find files in TARGET whose content does not exist
# anywhere in REFERENCE, using rmlint's content (checksum) based duplicate
# detection rather than filenames or paths.
#
# Usage:
#   ./find-missing-data.sh <target_dir> <reference_dir>
#
# Exit codes:
#   0  ran successfully (files needing review may or may not exist)
#   1  bad usage / missing dependency / bad input

set -euo pipefail

usage() {
    echo "Usage: $0 <target_dir> <reference_dir>" >&2
    exit 1
}

[[ $# -eq 2 ]] || usage

target_dir=$1
reference_dir=$2

for cmd in rmlint jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' is required but not installed." >&2; exit 1; }
done

[[ -d "$target_dir" ]] || { echo "Error: target dir '$target_dir' does not exist." >&2; exit 1; }
[[ -d "$reference_dir" ]] || { echo "Error: reference dir '$reference_dir' does not exist." >&2; exit 1; }

target_dir=$(cd "$target_dir" && pwd)
reference_dir=$(cd "$reference_dir" && pwd)

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

json_out="$workdir/rmlint.json"
matched_list="$workdir/matched.txt"
all_target_list="$workdir/all_target.txt"

# Tag reference as the authoritative side (--keep-all-tagged) and only
# report groups that actually cross-match into it (--must-match-tagged),
# so incidental duplicates that exist purely within target are ignored.
rmlint "$target_dir" // "$reference_dir" \
    --keep-all-tagged \
    --must-match-tagged \
    -o json:"$json_out" \
    -o summary >&2

jq -r --arg prefix "$target_dir/" '
    .[] | select(.type == "duplicate_file" and .is_original == false and (.path | startswith($prefix))) | .path
' "$json_out" | sort > "$matched_list"

find "$target_dir" -type f | sort > "$all_target_list"

review_list=$(comm -23 "$all_target_list" "$matched_list")

echo
if [[ -z "$review_list" ]]; then
    echo "No files to review — every file in '$target_dir' has matching content in '$reference_dir'."
else
    count=$(printf '%s\n' "$review_list" | wc -l | tr -d ' ')
    echo "Files to review ($count) — present in '$target_dir' but no matching content found in '$reference_dir':"
    printf '%s\n' "$review_list"
fi
