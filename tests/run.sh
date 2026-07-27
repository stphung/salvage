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
printf '\n'
if [[ $fail -eq 0 ]]; then
    printf '%s%d passed, 0 failed%s\n' "$G" "$pass" "$Z"
    exit 0
else
    printf '%s%d passed, %d failed%s\n' "$R" "$pass" "$fail" "$Z"
    for n in "${failed_names[@]}"; do printf '  - %s\n' "$n"; done
    exit 1
fi
