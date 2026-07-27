#!/usr/bin/env bash
#
# salvage test suite. Fixtures are generated rather than committed: empty
# files, symlinks and newline-in-name files do not survive git or a zip
# faithfully, and the code that builds each case documents the case.
#
# Each numbered group is a function named test_<NN>_<slug>. The runner at the
# bottom discovers them with `declare -F`, which sorts alphabetically, so the
# zero-padded prefix gives run order with no registry to keep in sync.
#
# Usage:
#   tests/run.sh                 run everything
#   tests/run.sh 5               run group 5
#   tests/run.sh 5 22 26         run several
#   tests/run.sh -k newline      run groups whose name matches a substring
#   tests/run.sh -l              list the groups
#   tests/run.sh -v              print passing assertions too

set -uo pipefail

SALVAGE=$(cd -- "$(dirname -- "$0")/.." && pwd)/salvage
VERBOSE=false
LIST=false
pattern=""
nums=""

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=true; shift ;;
        -l|--list)    LIST=true; shift ;;
        -k)           [[ $# -ge 2 ]] || { echo "-k needs a pattern" >&2; exit 2; }
                      pattern=$2; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        [0-9]*)       nums="$nums $1"; shift ;;
        *)            printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

pass=0
fail=0
failed_names=()

if [[ -t 1 ]]; then
    G=$'\033[32m'; R=$'\033[31m'; D=$'\033[2m'; Z=$'\033[0m'
else
    G=""; R=""; D=""; Z=""
fi

work=""
setup() {
    work=$(mktemp -d)
    target="$work/target"
    ref="$work/ref"
    mkdir -p "$target" "$ref"
}
teardown() { [[ -n $work ]] && rm -rf "$work"; work=""; }

# run salvage, capturing stdout, stderr and status separately
run() {
    out=$("$SALVAGE" "$@" 2>"$work/err")
    status=$?
    err=$(cat "$work/err")
    return 0
}

ok() {
    local name=$1
    pass=$((pass + 1))
    $VERBOSE && printf '%s  ok  %s%s\n' "$G" "$name" "$Z"
    return 0
}
no() {
    local name=$1 detail=$2
    fail=$((fail + 1))
    failed_names+=("$name")
    printf '%sFAIL%s %s\n' "$R" "$Z" "$name"
    printf '%s%s%s\n' "$D" "$(printf '%s' "$detail" | sed 's/^/       /')" "$Z"
    return 0
}

expect_eq() {
    local name=$1 expected=$2 actual=$3
    if [[ $expected == "$actual" ]]; then ok "$name"
    else no "$name" "expected: [$expected]
actual:   [$actual]"
    fi
}
expect_status() {
    local name=$1 expected=$2
    if [[ $status -eq $expected ]]; then ok "$name"
    else no "$name" "expected exit $expected, got $status
stderr: $err"
    fi
}
expect_contains() {
    local name=$1 needle=$2 hay=$3
    case $hay in
        *"$needle"*) ok "$name" ;;
        *) no "$name" "expected to contain: $needle
actual: $hay" ;;
    esac
}
expect_not_contains() {
    local name=$1 needle=$2 hay=$3
    case $hay in
        *"$needle"*) no "$name" "expected NOT to contain: $needle
actual: $hay" ;;
        *) ok "$name" ;;
    esac
}


# 1. Content match ignores name and path
test_01_content_match() {
setup
printf 'shared payload' > "$target/deep-name.txt"
mkdir -p "$ref/some/other/place"
printf 'shared payload' > "$ref/some/other/place/totally-different-name.dat"
printf 'only here' > "$target/unique.txt"
run "$target" -r "$ref"
expect_eq "1a content match ignores name and path" "unique.txt" "$out"
expect_status "1b exit 1 when something is unmatched" 1
teardown
}

# 2. Hidden files are compared (regression: rmlint skips them by default)
test_02_hidden_files_are_compared() {
setup
printf 'secret config' > "$target/.env"
printf 'secret config' > "$ref/.env"
run "$target" -r "$ref"
expect_eq "2a hidden file present in reference is matched" "" "$out"
expect_status "2b exit 0 when fully covered" 0

printf 'unbacked secret' > "$target/.env.local"
run "$target" -r "$ref"
expect_eq "2c hidden file absent from reference is reported" ".env.local" "$out"

run "$target" -r "$ref" --exclude-hidden
expect_eq "2d --exclude-hidden skips dotfiles" "" "$out"
teardown
}

# 3. Empty files (rmlint classifies these as 'emptyfile', never as duplicates)
test_03_empty_files() {
setup
: > "$target/empty-one"
: > "$target/empty-two"
printf 'real' > "$target/real.txt"
printf 'real' > "$ref/real.txt"
run "$target" -r "$ref"
expect_eq "3a empty files are not reported as unmatched" "" "$out"
expect_status "3b empty files do not affect the exit code" 0
expect_contains "3c empty files are named in a footnote" "2 empty files" "$err"
teardown
}

# 4. Symlinks are not compared, and not silently dropped
test_04_symlinks() {
setup
printf 'real' > "$target/real.txt"
printf 'real' > "$ref/real.txt"
ln -s real.txt "$target/pointer"
run "$target" -r "$ref"
expect_eq "4a symlinks are not reported as unmatched" "" "$out"
expect_contains "4b symlinks are named in a footnote" "1 symlink" "$err"
teardown
}

# 5. Filename containing a newline (regression: broke the sort/comm diff)
test_05_filename_containing_a_newline() {
setup
nl_name=$(printf 'two\nlines.txt')
printf 'unmatched payload' > "$target/$nl_name"
printf 'matched' > "$target/fine.txt"
printf 'matched' > "$ref/fine.txt"
run "$target" -r "$ref"
expect_eq "5a newline filename is reported" "$nl_name" "$out"
expect_contains "5b ambiguous manifest is flagged" "contain a newline" "$err"
out0=$("$SALVAGE" "$target" -r "$ref" --print0 2>/dev/null | tr '\0' '@')
expect_eq "5c --print0 delimits with NUL" "$nl_name@" "$out0"
teardown
}

# 6. Overlapping trees must be refused, not silently misreported
test_06_overlapping_trees() {
setup
mkdir -p "$ref/inner"
printf 'x' > "$ref/inner/f"
run "$ref/inner" -r "$ref"
expect_status "6a target inside reference is a fatal error" 2
expect_contains "6b overlap error explains why" "inside reference" "$err"
run "$ref" -r "$ref/inner"
expect_status "6c reference inside target is a fatal error" 2
run "$ref" -r "$ref"
expect_status "6d identical target and reference is a fatal error" 2
teardown
}

# 7. Multiple references
test_07_multiple_references() {
setup
ref2="$work/ref2"; mkdir -p "$ref2"
printf 'alpha' > "$target/a"
printf 'beta'  > "$target/b"
printf 'gamma' > "$target/c"
printf 'alpha' > "$ref/x"
printf 'beta'  > "$ref2/y"
run "$target" -r "$ref" -r "$ref2"
expect_eq "7a matches spread across references" "c" "$out"
run "$target" -r "$ref"
expect_eq "7b one reference alone leaves more unmatched" "b
c" "$out"
teardown
}

# 8. Exit codes
test_08_exit_codes() {
setup
printf 'same' > "$target/f"
printf 'same' > "$ref/f"
run "$target" -r "$ref"
expect_status "8a exit 0 — fully covered" 0
printf 'new' > "$target/g"
run "$target" -r "$ref"
expect_status "8b exit 1 — uncovered files" 1
run "$target" -r "$work/does-not-exist"
expect_status "8c exit 2 — nonexistent reference" 2
run "$work/does-not-exist" -r "$ref"
expect_status "8d exit 2 — nonexistent target" 2
run "$target"
expect_status "8e exit 2 — no reference given" 2
run
expect_status "8f exit 2 — no arguments" 2
run "$target" "$ref"
expect_status "8g exit 2 — bare positional reference rejected" 2
expect_contains "8h rejection suggests the -r form" "-r" "$err"
run "$target" -r "$ref" --nonsense
expect_status "8i exit 2 — unknown option" 2
teardown
}

# 9. Default exclusions
test_09_default_exclusions() {
setup
printf 'kept' > "$target/real.txt"
printf 'kept' > "$ref/real.txt"
printf 'finder junk' > "$target/.DS_Store"
mkdir -p "$target/.Spotlight-V100/store"
printf 'index' > "$target/.Spotlight-V100/store/idx"
printf 'thumbs' > "$target/Thumbs.db"
run "$target" -r "$ref"
expect_eq "9a OS metadata excluded by default" "" "$out"
expect_contains "9b exclusions are counted in a footnote" "3 OS metadata files excluded" "$err"
run "$target" -r "$ref" --no-default-excludes
expect_eq "9c --no-default-excludes includes them" ".DS_Store
.Spotlight-V100/store/idx
Thumbs.db" "$out"
teardown
}

# 10. User exclusions
test_10_user_exclusions() {
setup
mkdir -p "$target/logs"
printf 'noise' > "$target/logs/a.log"
printf 'noise2' > "$target/b.log"
printf 'data' > "$target/keep.txt"
run "$target" -r "$ref" --exclude '*.log'
expect_eq "10a bare glob matches basenames at any depth" "keep.txt" "$out"
run "$target" -r "$ref" --exclude 'logs/*'
expect_eq "10b glob with a slash matches the relative path" "b.log
keep.txt" "$out"
teardown
}

# 11. Path forms
test_11_path_forms() {
setup
mkdir -p "$target/sub"
printf 'x' > "$target/sub/f.txt"
run "$target" -r "$ref" --absolute
target_real=$(cd -- "$target" && pwd -P)
expect_eq "11a --absolute emits resolved absolute paths" "$target_real/sub/f.txt" "$out"
run "$target" -r "$ref"
expect_eq "11b default is relative to target" "sub/f.txt" "$out"
teardown
}

# 12. Filenames that look like options
test_12_option_like_filenames() {
setup
printf 'dash payload' > "$target/-rf"
run "$target" -r "$ref"
expect_eq "12a leading-dash filename is handled" "-rf" "$out"
teardown
}

# 13. Structured report
test_13_structured_report() {
setup
printf 'aaa' > "$target/unmatched.txt"
printf 'bbb' > "$target/matched.txt"
printf 'bbb' > "$ref/elsewhere.txt"
run "$target" -r "$ref" --json "$work/report.json"
expect_eq "13a --json unmatched count"  "1" "$(jq -r '.counts.unmatched' "$work/report.json")"
expect_eq "13b --json matched count"    "1" "$(jq -r '.counts.matched' "$work/report.json")"
expect_eq "13c --json bytes at risk"    "3" "$(jq -r '.bytes_at_risk' "$work/report.json")"
expect_eq "13d --json path listed"      "unmatched.txt" "$(jq -r '.unmatched[0].path' "$work/report.json")"
run "$target" -r "$ref" --save-scan "$work/scan.json"
if [[ -s $work/scan.json ]] && jq -e 'type == "array"' "$work/scan.json" >/dev/null 2>&1; then
    ok "13e --save-scan writes replayable rmlint JSON"
else
    no "13e --save-scan writes replayable rmlint JSON" "file missing or not a JSON array"
fi
teardown
}

# 14. Stream separation
test_14_stream_separation() {
setup
printf 'x' > "$target/only.txt"
run "$target" -r "$ref"
expect_eq "14a stdout carries paths and nothing else" "only.txt" "$out"
expect_contains "14b header goes to stderr" "target:" "$err"
expect_not_contains "14c header does not leak to stdout" "target:" "$out"
run "$target" -r "$ref" -q
expect_eq "14d --quiet leaves stdout intact" "only.txt" "$out"
expect_eq "14e --quiet silences stderr" "" "$err"
teardown
}

# 15. Rollup and listing
test_15_rollup_and_listing() {
setup
mkdir -p "$target/whole"
printf 'a' > "$target/whole/1"
printf 'b' > "$target/whole/2"
mkdir -p "$target/partial"
printf 'c' > "$target/partial/kept"
printf 'd' > "$target/partial/lost"
printf 'c' > "$ref/copy-of-kept"
run "$target" -r "$ref"
expect_contains "15a fully unmatched directory is flagged" "nothing matched" "$err"
expect_contains "15b partial directory shows the ratio" "1/2 files" "$err"
run "$target" -r "$ref" --no-rollup
expect_not_contains "15c --no-rollup omits the summary" "nothing matched" "$err"

i=0
while [[ $i -lt 60 ]]; do printf 'v%s' "$i" > "$target/many-$i"; i=$((i + 1)); done
run "$target" -r "$ref"
expect_contains "15d long lists are summarised on stderr" "full list on stdout" "$err"
expect_eq "15e long lists are complete on stdout" "63" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
run "$target" -r "$ref" --all
expect_contains "15f --all prints the full list on stderr" "many-42" "$err"
teardown
}

# 16. Help and version
test_16_help_and_version() {
setup
run --help
expect_status "16a --help exits 0" 0
expect_contains "16b --help goes to stdout" "USAGE" "$out"
run --version
expect_status "16c --version exits 0" 0
expect_contains "16d --version reports rmlint" "rmlint" "$out"
teardown
}

# 17. Paranoid mode agrees with the default
test_17_paranoid_mode() {
setup
printf 'identical bytes' > "$target/a"
printf 'identical bytes' > "$ref/b"
printf 'different' > "$target/c"
run "$target" -r "$ref" --paranoid
expect_eq "17a --paranoid agrees with blake2b" "c" "$out"
expect_contains "17b comparison method is stated" "paranoid" "$err"
teardown
}

# 18. Matching is by content, not by size. rmlint groups candidates by size
#     first, so same-size-different-content is the case that would expose a
#     false match — the only error mode here that loses data.
test_18_content_not_size() {
setup
printf 'AAAA' > "$target/a"
printf 'BBBB' > "$ref/b"
run "$target" -r "$ref"
expect_eq "18a same size, different content is not a match" "a" "$out"
printf 'AAAA' > "$ref/c"
run "$target" -r "$ref"
expect_eq "18b same size, same content is a match" "" "$out"
teardown
}

# 19. Duplicates within the target itself
test_19_intra_target_duplicates() {
setup
printf 'twinned' > "$target/one"
printf 'twinned' > "$target/two"
run "$target" -r "$ref"
expect_eq "19a intra-target duplicates with no reference: both reported" "one
two" "$out"
printf 'twinned' > "$ref/single-copy"
run "$target" -r "$ref"
expect_eq "19b one reference copy covers both target copies" "" "$out"
teardown
}

# 20. The question is one-directional: reference-only files are never reported
test_20_one_directional() {
setup
printf 'shared' > "$target/t"
printf 'shared' > "$ref/r"
printf 'reference has extra content' > "$ref/extra-1"
mkdir -p "$ref/whole/extra/tree"
printf 'more' > "$ref/whole/extra/tree/file"
run "$target" -r "$ref"
expect_eq "20a reference-only files are not reported" "" "$out"
expect_status "20b reference-only files do not affect the exit code" 0
expect_not_contains "20c reference-only names never appear" "extra-1" "$err"
teardown
}

# 21. Degenerate trees
test_21_degenerate_trees() {
setup
run "$target" -r "$ref"
expect_status "21a empty target is fully covered" 0
expect_contains "21b empty target says so" "No files to compare" "$err"
printf 'orphan' > "$target/lonely"
run "$target" -r "$ref"
expect_eq "21c empty reference leaves everything unmatched" "lonely" "$out"
expect_status "21d empty reference exits 1" 1
teardown
setup
: > "$target/nothing"
ln -s nothing "$target/pointer"
run "$target" -r "$ref"
expect_status "21e target of only empty files and symlinks is covered" 0
expect_contains "21f and says nothing was comparable" "No files to compare" "$err"
teardown
}

# 22. Recursion depth — the tool must reach the bottom of a deep tree
test_22_recursion_depth() {
setup
deep="a/b/c/d/e/f/g/h/i/j/k/l"
mkdir -p "$target/$deep" "$ref/somewhere/else"
printf 'buried treasure' > "$target/$deep/found.txt"
printf 'buried treasure' > "$ref/somewhere/else/renamed.txt"
printf 'buried and lost'  > "$target/$deep/lost.txt"
run "$target" -r "$ref"
expect_eq "22a depth-12 match found regardless of path" "$deep/lost.txt" "$out"
expect_contains "22b deep directory appears in the rollup" "$deep/" "$err"
teardown
}

# 23. Hardlinks — two paths, one inode, both must be accounted for
test_23_hardlinks() {
setup
printf 'linked content' > "$target/original"
ln "$target/original" "$target/hardlink"
run "$target" -r "$ref"
expect_eq "23a both hardlink paths reported when unmatched" "hardlink
original" "$out"
printf 'linked content' > "$ref/copy"
run "$target" -r "$ref"
expect_eq "23b both hardlink paths matched by one reference copy" "" "$out"
teardown
}

# 24. Filenames that break naive shell code
test_24_exotic_filenames() {
setup
names=(
    "plain.txt"
    "with spaces.txt"
    "it's a \"quoted\" file.txt"
    "back\\slash.txt"
    "percent-%s-format.txt"
    "dollar\$sign.txt"
    "café-unicode.txt"
    "日本語.txt"
    "trailing.space .txt"
    "-leading-dash.txt"
    "semi;colon&amp.txt"
)
for n in "${names[@]}"; do printf 'unique-%s' "$n" > "$target/$n"; done
count=$("$SALVAGE" "$target" -r "$ref" --print0 2>/dev/null | LC_ALL=C tr -dc '\0' | LC_ALL=C wc -c | tr -d ' ')
expect_eq "24a every exotic filename is reported" "${#names[@]}" "$count"
run "$target" -r "$ref"
for n in "${names[@]}"; do
    expect_contains "24b reported verbatim: $n" "$n" "$out"
done
teardown
}

# 25. Argument path forms
test_25_argument_path_forms() {
setup
printf 'x' > "$target/f"
run "$target/" -r "$ref/"
expect_eq "25a trailing slashes on arguments" "f" "$out"
( cd "$work" && "$SALVAGE" target -r ref >"$work/rel.out" 2>/dev/null )
expect_eq "25b relative path arguments" "f" "$(cat "$work/rel.out")"
ln -s "$target" "$work/target-link"
run "$work/target-link" -r "$ref"
expect_eq "25c symlinked directory as target" "f" "$out"
run "$target" -r "$ref" -r "$ref"
expect_eq "25d the same reference given twice is harmless" "f" "$out"
run -r "$ref" -- "$target"
expect_eq "25e -- terminates option parsing" "f" "$out"
teardown
}

# 26. An I/O failure must never look like a clean bill of health
test_26_unreadable_files() {
setup
printf 'readable' > "$target/fine.txt"
printf 'readable' > "$ref/fine.txt"
mkdir -p "$target/locked"
printf 'unreadable' > "$target/locked/secret"
chmod 000 "$target/locked"
run "$target" -r "$ref"
chmod 755 "$target/locked"
expect_status "26a unreadable directory exits 2, not 0" 2
expect_contains "26b and explains that coverage is unverified" "coverage cannot be verified" "$err"
expect_eq "26c and emits no manifest" "" "$out"
teardown
}

# 27. Determinism
test_27_determinism() {
setup
for n in zebra alpha Mike 10-ten 2-two _under; do printf 'v-%s' "$n" > "$target/$n"; done
run "$target" -r "$ref"; first=$out
run "$target" -r "$ref"; second=$out
expect_eq "27a repeated runs agree" "$first" "$second"
expect_eq "27b stdout is sorted" "$(printf '%s\n' "$first" | LC_ALL=C sort)" "$first"
teardown
}

# 28. Scale — xargs batches the stat call, and misaligned batches would
#     silently attach the wrong size to the wrong file
test_28_scale() {
setup
n=2500
i=0
while [[ $i -lt $n ]]; do printf 'payload-%s' "$i" > "$target/f$i"; i=$((i + 1)); done
printf 'payload-7' > "$ref/one-match"
run "$target" -r "$ref" --json "$work/scale.json"
expect_status "28a scale run exits 1" 1
expect_eq "28b every file accounted for" "$((n - 1))" "$(jq -r '.counts.unmatched' "$work/scale.json")"
expect_eq "28c the single match is found" "1" "$(jq -r '.counts.matched' "$work/scale.json")"
expected_bytes=0
i=0
while [[ $i -lt $n ]]; do
    [[ $i -eq 7 ]] || expected_bytes=$((expected_bytes + ${#i} + 8))
    i=$((i + 1))
done
expect_eq "28d sizes stay aligned across xargs batches" \
    "$expected_bytes" "$(jq -r '.bytes_at_risk' "$work/scale.json")"
expect_eq "28e no file is missing a size" "0" \
    "$(jq -r '[.unmatched[] | select(.size == null)] | length' "$work/scale.json")"
teardown
}

# 29. Structured report for the covered case
test_29_json_covered_case() {
setup
printf 'covered' > "$target/f"
printf 'covered' > "$ref/g"
run "$target" -r "$ref" --json "$work/covered.json"
expect_eq "29a covered report lists nothing" "0" "$(jq -r '.unmatched | length' "$work/covered.json")"
expect_eq "29b covered report has zero bytes at risk" "0" "$(jq -r '.bytes_at_risk' "$work/covered.json")"
expect_eq "29c report records the comparison method" "blake2b" "$(jq -r '.comparison' "$work/covered.json")"
expect_eq "29d report records every reference" "1" "$(jq -r '.references | length' "$work/covered.json")"
teardown
}

# 30. --save-scan output is genuinely replayable
test_30_save_scan_replay() {
setup
printf 'matched' > "$target/m"; printf 'matched' > "$ref/m2"
printf 'missing' > "$target/x"
run "$target" -r "$ref" --save-scan "$work/scan.json"
if rmlint --replay "$work/scan.json" -o "json:$work/replayed.json" >/dev/null 2>&1 \
   && jq -e 'type == "array"' "$work/replayed.json" >/dev/null 2>&1; then
    ok "30a rmlint --replay accepts the saved scan"
else
    no "30a rmlint --replay accepts the saved scan" "replay failed"
fi
teardown
}

# 31. No escape sequences leak into a non-terminal
test_31_no_ansi_escapes() {
setup
printf 'x' > "$target/f"
run "$target" -r "$ref"
esc=$(printf '\033')
expect_not_contains "31a no ANSI on stderr when not a terminal" "$esc" "$err"
expect_not_contains "31b no ANSI on stdout" "$esc" "$out"
run "$target" -r "$ref" --no-color
expect_not_contains "31c --no-color is clean too" "$esc" "$err"
teardown
}

# 33. stat(1) portability. The size probe is exercised here against a shim
#     rather than against the host, so the GNU branch is covered on a BSD
#     machine and vice versa. The shims compute sizes with wc so they work
#     on either platform.
test_33_stat_portability() {
setup
shim="$work/shim"; mkdir -p "$shim"

# GNU-like: -c '%s' works, -f is --file-system and fails on a format string
cat > "$shim/stat" <<'SHIM'
#!/bin/sh
if [ "$1" = "-c" ] && [ "$2" = "%s" ]; then
    shift 2
    for f in "$@"; do wc -c < "$f" | tr -d ' '; done
    exit 0
fi
echo "stat: cannot read file system information" >&2
exit 1
SHIM
chmod +x "$shim/stat"

printf 'twelve bytes' > "$target/a"
printf 'seven!!' > "$target/b"
PATH="$shim:$PATH" "$SALVAGE" "$target" -r "$ref" --json "$work/gnu.json" >/dev/null 2>"$work/err"
status=$?; err=$(cat "$work/err")
expect_status "33a runs with a GNU-style stat" 1
expect_eq "33b GNU-style stat yields correct sizes" "19" "$(jq -r '.bytes_at_risk' "$work/gnu.json")"
expect_not_contains "33c and does not claim sizes are unavailable" "sizes unavailable" "$err"

# stat unusable entirely: the verdict must survive, only the sizes drop
cat > "$shim/stat" <<'SHIM'
#!/bin/sh
echo "stat: unavailable" >&2
exit 1
SHIM
chmod +x "$shim/stat"
out=$(PATH="$shim:$PATH" "$SALVAGE" "$target" -r "$ref" --json "$work/nostat.json" 2>"$work/err")
status=$?; err=$(cat "$work/err")
expect_status "33d unusable stat does not change the verdict" 1
expect_eq "33e unusable stat still lists every file" "a
b" "$out"
expect_eq "33f unusable stat reports sizes as unknown" "null" "$(jq -r '.bytes_at_risk' "$work/nostat.json")"
expect_contains "33g and says so on stderr" "sizes unavailable" "$err"
teardown
}

# 32. Optional lint
test_32_optional_lint() {
if command -v shellcheck >/dev/null 2>&1; then
    lint_out=$(mktemp)
    shellcheck -S warning "$SALVAGE" "$0" >"$lint_out" 2>&1 || true
    if [[ -s $lint_out ]]; then
        no "32a shellcheck reports no warnings" "$(cat "$lint_out")"
    else
        ok "32a shellcheck reports no warnings"
    fi
    rm -f "$lint_out"
else
    printf '%s  skip  32a shellcheck not installed%s\n' "$D" "$Z"
fi
}

# 34. Report presentation: the verdict line, the header totals, the
#     largest-at-risk section, and byte accounting. Bars and hyperlinks are
#     TTY-only and are covered by group 31 asserting they never leak.
test_34_report_presentation() {
setup
printf 'covered' > "$target/a"
printf 'covered' > "$ref/elsewhere"
run "$target" -r "$ref"
expect_contains "34a covered runs get a positive verdict" "SAFE TO DELETE" "$err"
expect_not_contains "34b covered runs do not say at risk" "AT RISK" "$err"

printf 'lost data here' > "$target/b"
run "$target" -r "$ref"
expect_contains "34c uncovered runs lead with what is at risk" "AT RISK" "$err"
expect_not_contains "34d uncovered runs do not claim safety" "SAFE TO DELETE" "$err"
expect_contains "34e header states the file count" "2 files" "$err"
expect_contains "34f header states the elapsed time" "scanned in" "$err"
teardown

# byte accounting: total must be matched + at-risk, so the coverage
# percentages the meters draw cannot disagree with the file list
setup
printf '0123456789' > "$target/ten"          # 10 bytes, matched
printf '0123456789' > "$ref/ten-copy"
printf '01234'      > "$target/five"         # 5 bytes, unmatched
run "$target" -r "$ref" --json "$work/b.json"
expect_eq "34g bytes matched"  "10" "$(jq -r '.bytes_matched'  "$work/b.json")"
expect_eq "34h bytes at risk"  "5"  "$(jq -r '.bytes_at_risk'  "$work/b.json")"
expect_eq "34i bytes total is the sum" "15" "$(jq -r '.bytes_total' "$work/b.json")"
expect_eq "34j totals reconcile" "true" \
    "$(jq -r '.bytes_total == (.bytes_matched + .bytes_at_risk)' "$work/b.json")"
teardown

# largest-at-risk appears only once the list is too long to eyeball
setup
i=0
while [[ $i -lt 12 ]]; do printf 'small-%s' "$i" > "$target/s$i"; i=$((i + 1)); done
printf '%0*d' 5000 0 > "$target/whale.bin"
run "$target" -r "$ref"
expect_contains "34k largest-at-risk shown for long lists" "largest at risk" "$err"
expect_contains "34l and names the biggest file" "whale.bin" "$err"
teardown
setup
printf 'only' > "$target/one"
run "$target" -r "$ref"
expect_not_contains "34m largest-at-risk omitted for short lists" "largest at risk" "$err"
teardown
}

# 35. Placement suggestions. The directory mapping is *learned* from where
#     matched files landed, so a reference that was reorganised is followed
#     rather than mirrored.
test_35_placement_suggestions() {
setup
refabs=$(cd -- "$ref" && pwd -P)

# the reference keeps src/ under a differently named directory
mkdir -p "$target/src" "$ref/lib"
printf 'shared code' > "$target/src/known.rs"
printf 'shared code' > "$ref/lib/known.rs"
printf 'brand new'   > "$target/src/new.rs"
run "$target" -r "$ref" --suggest-json "$work/s.json"
expect_eq "35a destination is learned, not mirrored" \
    "$refabs/lib/new.rs" "$(jq -r '.[] | select(.path=="src/new.rs") | .destination' "$work/s.json")"
expect_contains "35b reason cites the sibling vote" "siblings" \
    "$(jq -r '.[] | select(.path=="src/new.rs") | .reason' "$work/s.json")"
expect_eq "35c a unanimous vote is full confidence" "1" \
    "$(jq -r '.[] | select(.path=="src/new.rs") | .confidence' "$work/s.json")"

# a subtree with no matched file inherits from the nearest mapped ancestor
mkdir -p "$target/src/deep/deeper"
printf 'orphan' > "$target/src/deep/deeper/lost.rs"
run "$target" -r "$ref" --suggest-json "$work/s2.json"
expect_eq "35d unmatched subtree inherits its ancestor's mapping" \
    "$refabs/lib/deep/deeper/lost.rs" \
    "$(jq -r '.[] | select(.path|endswith("lost.rs")) | .destination' "$work/s2.json")"
expect_contains "35e inheritance is stated as such" "inherited from" \
    "$(jq -r '.[] | select(.path|endswith("lost.rs")) | .reason' "$work/s2.json")"
expect_eq "35f inherited placement is less confident" "true" \
    "$(jq -r '.[] | select(.path|endswith("lost.rs")) | .confidence < 1' "$work/s2.json")"
teardown

# nothing matched anywhere: mirror the target layout, and say so
setup
refabs=$(cd -- "$ref" && pwd -P)
mkdir -p "$target/a/b"
printf 'nothing in common' > "$target/a/b/x.txt"
run "$target" -r "$ref" --suggest-json "$work/s.json"
expect_eq "35g with no signal the layout is mirrored" \
    "$refabs/a/b/x.txt" "$(jq -r '.[0].destination' "$work/s.json")"
expect_contains "35h and the absence of signal is stated" "mirrored" \
    "$(jq -r '.[0].reason' "$work/s.json")"
expect_eq "35i mirrored placement has no confidence" "0" "$(jq -r '.[0].confidence' "$work/s.json")"
teardown

# same name, different content — the overwrite case
setup
printf 'version two' > "$target/notes.txt"
printf 'version one' > "$ref/notes.txt"
printf 'anchor' > "$target/anchor"
printf 'anchor' > "$ref/anchor"
run "$target" -r "$ref" --suggest-json "$work/s.json" --plan "$work/plan.sh"
expect_eq "35j occupied destination is detected" "true" \
    "$(jq -r '.[] | select(.path=="notes.txt") | .occupied' "$work/s.json")"
expect_contains "35k and named as an overwrite risk" "different content" \
    "$(jq -r '.[] | select(.path=="notes.txt") | .reason' "$work/s.json")"
expect_contains "35l the plan warns about it" "WOULD OVERWRITE" "$(cat "$work/plan.sh")"
if grep -qE "^cp .*notes\.txt" "$work/plan.sh"; then
    no "35m the plan does not copy over it" "an active cp line was emitted for notes.txt"
else
    ok "35m the plan does not copy over it"
fi
teardown

# Two unmatched files landing on the same destination. This needs two
# distinct target directories that both map onto one reference directory —
# which is what a flattened backup looks like.
setup
mkdir -p "$target/one" "$target/two"
printf 'anchor one' > "$target/one/a1"; printf 'anchor one' > "$ref/a1"
printf 'anchor two' > "$target/two/a2"; printf 'anchor two' > "$ref/a2"
printf 'first'  > "$target/one/dup.txt"
printf 'second' > "$target/two/dup.txt"
run "$target" -r "$ref" --suggest-json "$work/s.json" --plan "$work/plan.sh"
expect_eq "35n collisions are detected" "2" \
    "$(jq -r '[.[] | select(.collision)] | length' "$work/s.json")"
expect_contains "35o the plan flags the collision" "COLLIDES" "$(cat "$work/plan.sh")"
teardown

# the plan is a real script, and salvage does not run it
setup
printf 'anchor' > "$target/anchor"; printf 'anchor' > "$ref/anchor"
printf 'new file' > "$target/fresh.txt"
before=$(find "$ref" -type f | wc -l | tr -d ' ')
run "$target" -r "$ref" --plan "$work/plan.sh"
after=$(find "$ref" -type f | wc -l | tr -d ' ')
expect_eq "35p salvage does not touch the reference" "$before" "$after"
if sh -n "$work/plan.sh" 2>/dev/null; then ok "35q the plan is valid sh"
else no "35q the plan is valid sh" "sh -n rejected it"; fi
expect_contains "35r the report points at the plan" "plan written to" "$err"

# running it achieves coverage — the end-to-end claim
sh "$work/plan.sh" >/dev/null 2>&1
run "$target" -r "$ref"
expect_status "35s running the plan achieves full coverage" 0
expect_eq "35t and nothing is left unmatched" "" "$out"
teardown

# suggestions are opt-in, and pointless when everything is covered
setup
printf 'covered' > "$target/a"; printf 'covered' > "$ref/b"
run "$target" -r "$ref" --suggest
expect_not_contains "35u no suggestions when fully covered" "suggested placement" "$err"
printf 'missing' > "$target/c"
run "$target" -r "$ref"
expect_not_contains "35v suggestions are off by default" "suggested placement" "$err"
run "$target" -r "$ref" --suggest
expect_contains "35w --suggest turns them on" "suggested placement" "$err"
teardown

# with several references, placement follows whichever one the siblings used
setup
ref2="$work/ref2"; mkdir -p "$ref2/archive"
mkdir -p "$target/photos"
printf 'photo one' > "$target/photos/p1.jpg"
printf 'photo one' > "$ref2/archive/p1.jpg"
printf 'photo two' > "$target/photos/p2.jpg"
run "$target" -r "$ref" -r "$ref2" --suggest-json "$work/s.json"
expect_eq "35x placement follows the reference the siblings landed in" \
    "$(cd -- "$ref2" && pwd -P)/archive/p2.jpg" \
    "$(jq -r '.[] | select(.path|endswith("p2.jpg")) | .destination' "$work/s.json")"
teardown
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
all_tests=$(declare -F | awk '{print $3}' | grep '^test_[0-9]')

label() { printf '%s' "${1#test_}"; }

if $LIST; then
    for t in $all_tests; do printf '  %s\n' "$(label "$t")"; done
    exit 0
fi

selected=""
for t in $all_tests; do
    keep=false
    if [[ -z $nums && -z $pattern ]]; then
        keep=true
    else
        for n in $nums; do
            [[ $t == test_$(printf '%02d' "$n")_* ]] && keep=true
        done
        if [[ -n $pattern ]]; then
            case $t in *"$pattern"*) keep=true ;; esac
        fi
    fi
    $keep && selected="$selected $t"
done

if [[ -z ${selected// /} ]]; then
    printf 'no groups matched. try: %s -l\n' "$0" >&2
    exit 2
fi

total=$(printf '%s\n' $selected | grep -c .)
if [[ -z $nums && -z $pattern ]]; then
    printf 'running salvage tests\n\n'
else
    printf 'running %d of %d groups\n\n' "$total" "$(printf '%s\n' $all_tests | grep -c .)"
fi

for t in $selected; do
    $VERBOSE && printf '%s· %s%s\n' "$D" "$(label "$t")" "$Z"
    "$t"
    teardown            # safety net: a group that returns early still cleans up
done

printf '\n'
if [[ $fail -eq 0 ]]; then
    printf '%s%d passed, 0 failed%s\n' "$G" "$pass" "$Z"
    exit 0
else
    printf '%s%d passed, %d failed%s\n' "$R" "$pass" "$fail" "$Z"
    for n in "${failed_names[@]}"; do printf '  - %s\n' "$n"; done
    exit 1
fi
