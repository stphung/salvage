#!/usr/bin/env bash
#
# salvage test suite. Fixtures are generated rather than committed: empty
# files, symlinks and newline-in-name files do not survive git or a zip
# faithfully, and the code that builds each case documents the case.
#
# Usage: tests/run.sh [-v]

set -uo pipefail

SALVAGE=$(cd -- "$(dirname -- "$0")/.." && pwd)/salvage
VERBOSE=false
[[ ${1:-} == "-v" ]] && VERBOSE=true

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

printf 'running salvage tests\n\n'

# ---------------------------------------------------------------------------
# 1. Content match ignores name and path
# ---------------------------------------------------------------------------
setup
printf 'shared payload' > "$target/deep-name.txt"
mkdir -p "$ref/some/other/place"
printf 'shared payload' > "$ref/some/other/place/totally-different-name.dat"
printf 'only here' > "$target/unique.txt"
run "$target" -r "$ref"
expect_eq "1a content match ignores name and path" "unique.txt" "$out"
expect_status "1b exit 1 when something is unmatched" 1
teardown

# ---------------------------------------------------------------------------
# 2. Hidden files are compared (regression: rmlint skips them by default)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 3. Empty files (rmlint classifies these as 'emptyfile', never as duplicates)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 4. Symlinks are not compared, and not silently dropped
# ---------------------------------------------------------------------------
setup
printf 'real' > "$target/real.txt"
printf 'real' > "$ref/real.txt"
ln -s real.txt "$target/pointer"
run "$target" -r "$ref"
expect_eq "4a symlinks are not reported as unmatched" "" "$out"
expect_contains "4b symlinks are named in a footnote" "1 symlink" "$err"
teardown

# ---------------------------------------------------------------------------
# 5. Filename containing a newline (regression: broke the sort/comm diff)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 6. Overlapping trees must be refused, not silently misreported
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 7. Multiple references
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 8. Exit codes
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 9. Default exclusions
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 10. User exclusions
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 11. Path forms
# ---------------------------------------------------------------------------
setup
mkdir -p "$target/sub"
printf 'x' > "$target/sub/f.txt"
run "$target" -r "$ref" --absolute
target_real=$(cd -- "$target" && pwd -P)
expect_eq "11a --absolute emits resolved absolute paths" "$target_real/sub/f.txt" "$out"
run "$target" -r "$ref"
expect_eq "11b default is relative to target" "sub/f.txt" "$out"
teardown

# ---------------------------------------------------------------------------
# 12. Filenames that look like options
# ---------------------------------------------------------------------------
setup
printf 'dash payload' > "$target/-rf"
run "$target" -r "$ref"
expect_eq "12a leading-dash filename is handled" "-rf" "$out"
teardown

# ---------------------------------------------------------------------------
# 13. Structured report
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 14. Stream separation
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 15. Rollup and listing
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 16. Help and version
# ---------------------------------------------------------------------------
setup
run --help
expect_status "16a --help exits 0" 0
expect_contains "16b --help goes to stdout" "USAGE" "$out"
run --version
expect_status "16c --version exits 0" 0
expect_contains "16d --version reports rmlint" "rmlint" "$out"
teardown

# ---------------------------------------------------------------------------
# 17. Paranoid mode agrees with the default
# ---------------------------------------------------------------------------
setup
printf 'identical bytes' > "$target/a"
printf 'identical bytes' > "$ref/b"
printf 'different' > "$target/c"
run "$target" -r "$ref" --paranoid
expect_eq "17a --paranoid agrees with blake2b" "c" "$out"
expect_contains "17b comparison method is stated" "paranoid" "$err"
teardown

# ---------------------------------------------------------------------------
# 18. Matching is by content, not by size. rmlint groups candidates by size
#     first, so same-size-different-content is the case that would expose a
#     false match — the only error mode here that loses data.
# ---------------------------------------------------------------------------
setup
printf 'AAAA' > "$target/a"
printf 'BBBB' > "$ref/b"
run "$target" -r "$ref"
expect_eq "18a same size, different content is not a match" "a" "$out"
printf 'AAAA' > "$ref/c"
run "$target" -r "$ref"
expect_eq "18b same size, same content is a match" "" "$out"
teardown

# ---------------------------------------------------------------------------
# 19. Duplicates within the target itself
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 20. The question is one-directional: reference-only files are never reported
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 21. Degenerate trees
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 22. Recursion depth — the tool must reach the bottom of a deep tree
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 23. Hardlinks — two paths, one inode, both must be accounted for
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 24. Filenames that break naive shell code
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 25. Argument path forms
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 26. An I/O failure must never look like a clean bill of health
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 27. Determinism
# ---------------------------------------------------------------------------
setup
for n in zebra alpha Mike 10-ten 2-two _under; do printf 'v-%s' "$n" > "$target/$n"; done
run "$target" -r "$ref"; first=$out
run "$target" -r "$ref"; second=$out
expect_eq "27a repeated runs agree" "$first" "$second"
expect_eq "27b stdout is sorted" "$(printf '%s\n' "$first" | LC_ALL=C sort)" "$first"
teardown

# ---------------------------------------------------------------------------
# 28. Scale — xargs batches the stat call, and misaligned batches would
#     silently attach the wrong size to the wrong file
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 29. Structured report for the covered case
# ---------------------------------------------------------------------------
setup
printf 'covered' > "$target/f"
printf 'covered' > "$ref/g"
run "$target" -r "$ref" --json "$work/covered.json"
expect_eq "29a covered report lists nothing" "0" "$(jq -r '.unmatched | length' "$work/covered.json")"
expect_eq "29b covered report has zero bytes at risk" "0" "$(jq -r '.bytes_at_risk' "$work/covered.json")"
expect_eq "29c report records the comparison method" "blake2b" "$(jq -r '.comparison' "$work/covered.json")"
expect_eq "29d report records every reference" "1" "$(jq -r '.references | length' "$work/covered.json")"
teardown

# ---------------------------------------------------------------------------
# 30. --save-scan output is genuinely replayable
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 31. No escape sequences leak into a non-terminal
# ---------------------------------------------------------------------------
setup
printf 'x' > "$target/f"
run "$target" -r "$ref"
esc=$(printf '\033')
expect_not_contains "31a no ANSI on stderr when not a terminal" "$esc" "$err"
expect_not_contains "31b no ANSI on stdout" "$esc" "$out"
run "$target" -r "$ref" --no-color
expect_not_contains "31c --no-color is clean too" "$esc" "$err"
teardown

# ---------------------------------------------------------------------------
# 33. stat(1) portability. The size probe is exercised here against a shim
#     rather than against the host, so the GNU branch is covered on a BSD
#     machine and vice versa. The shims compute sizes with wc so they work
#     on either platform.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 32. Optional lint
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
printf '\n'
if [[ $fail -eq 0 ]]; then
    printf '%s%d passed, 0 failed%s\n' "$G" "$pass" "$Z"
    exit 0
else
    printf '%s%d passed, %d failed%s\n' "$R" "$pass" "$fail" "$Z"
    for n in "${failed_names[@]}"; do printf '  - %s\n' "$n"; done
    exit 1
fi
