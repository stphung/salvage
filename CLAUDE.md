# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`salvage` answers one question: *if I delete TARGET, what do I lose?* It lists files
under a target tree whose content appears in no reference tree. Matching is by
checksum, so renames and moves still count as matches.

The whole tool is one file: `salvage`, ~640 lines of bash. Nothing is sourced. The
repo directory is currently named `dupe-check` while the tool is named `salvage`.

## Commands

```sh
make test           # full suite (~16s); or ./tests/run.sh
./tests/run.sh -v   # print every passing assertion, not just failures
make lint           # shellcheck salvage + tests (skips cleanly if not installed)
make demo           # run against examples/, exits 1 by design
make deps           # verify rmlint and jq are present
make install        # → ~/.local; PREFIX=... to override; make uninstall reverses
make link           # symlink instead of copy, for development
bash -n salvage     # syntax check without executing
```

**There is no way to run a single test.** `tests/run.sh` is a linear script of 33
numbered groups. To iterate on one, comment out the others or copy the group into a
scratch file. If you add a filter mechanism, keep the default behaviour identical.

Requires `rmlint` >= 2.10 and `jq`. macOS ships bash 3.2 — see Constraints.

## Architecture

Data flows through five stages. Understanding stage 3 is most of understanding the
tool.

1. **rmlint scan** — `rmlint TARGET // REF... --keep-all-tagged --must-match-tagged
   --hidden -o json:FILE`. `--keep-all-tagged` makes reference files the "originals";
   `--must-match-tagged` discards groups that don't cross into a reference, so
   duplicates existing purely inside the target are ignored.
2. **Inventory** — `find` is run with cwd inside the target, so every path is
   relative and carries a `./` prefix. That prefix is load-bearing: it is what keeps
   a file named `-rf` from being read as an option by `stat`.
3. **Set difference in jq** — one jq program takes the rmlint JSON plus the inventory
   (via `--rawfile`, split on `\u0000`) and emits `result.json` with the unmatched
   list, counts, and per-directory totals.
4. **Sizes** — only unmatched files are `stat`ed, via `xargs -0`, relying on xargs
   preserving argument order so sizes zip back onto paths positionally. A count
   mismatch degrades to a sizeless report rather than a wrong one.
5. **Render** — a second jq program formats the stderr report; stdout is written
   separately from `result.json`.

### Invariants that must not be broken

**Stream contract.** stdout carries the manifest — relative paths, one per line,
sorted — and nothing else. Every human-readable byte goes to stderr. This is what
makes `salvage T -r R > manifest.txt` directly valid for `rsync --files-from`. Adding
a header to stdout would silently break that composition.

**Exit codes follow `diff`.** `0` fully covered, `1` uncovered files exist, `2` error.
An unreadable file is `2`, never `0` — an I/O failure must never be indistinguishable
from a clean bill of health.

**Overlap is fatal.** rmlint won't call a file a duplicate of itself, so a target
nested inside a reference reports *everything* as unmatched. The tool refuses rather
than emit that.

**Report-only, permanently.** No flag may copy, move or delete. `rsync` does that.

### Exclusion model

Three regex lists are passed to jq: basename patterns, path-component patterns
(matched against every directory in the path), and full-relative-path patterns.
`glob_to_regex` converts globs, where `*`/`?` do not cross `/` but `**` does. A
user `--exclude` with no `/` becomes a basename pattern; otherwise a path pattern.

Default exclusions are OS scratch space only (`.DS_Store`, `.Spotlight-V100`,
`Thumbs.db`, ...). Hidden *user* files are deliberately compared — that distinction
is the design, not an oversight.

## Traps

These cost real time during development. All are live hazards for future edits.

**Never write a literal NUL byte into the script.** jq programs need
`split("\u0000")` / `join("\u0000")` as the four-character escape. An actual 0x00
byte in the file truncates the jq program at that point when bash passes it as argv,
and `grep` will report the file as binary and silently print nothing. Check with
`LC_ALL=C tr -dc '\0' < salvage | wc -c` — it must be 0.

**jq's `any(gen; cond)` rebinds `.`.** `any($regexes[]; $base | test(.))` tests
`$base` against *itself*, because the pipe rebinds `.` before `test` sees it. This
silently matched every file. Always bind first: `any($regexes[]; . as $re | ($base |
test($re)))`.

**`stat` is not portable.** BSD wants `-f '%z'`, GNU wants `-c '%s'`, and on GNU
`-f` means `--file-system`. The tool probes both against a known-size file at
startup. Do not replace this with an OS-name check.

**rmlint never reports empty files as duplicates.** They come back as lint type
`emptyfile` regardless of flags, including `-s 0`. Empty files are therefore excluded
in our code, not via an rmlint option.

**rmlint's summary is inverted relative to ours.** It reports "duplicates which could
be removed"; we report "data you would lose". Its output is suppressed with `-VVV` —
don't surface it.

**BSD `comm` has no `-z` and BSD `awk` can't use NUL as `RS`.** This is why set
operations live in jq. Don't reintroduce `sort`/`comm`; it breaks on newlines in
filenames and depends on locale collation.

## Constraints

**bash 3.2** (the version macOS ships). No associative arrays, no `mapfile`, no
`${var,,}`. Empty arrays under `set -u` need `${arr[@]+"${arr[@]}"}`.

**BSD and GNU userlands both.** `find -empty`, `pwd -P`, `sed -n`, `date -u` and
`xargs -0` are fine on both; `stat` is the only divergence and is already handled.

## Tests

`tests/run.sh` generates all fixtures at runtime — empty files, symlinks and
newline-in-name files don't survive git faithfully, and the generating code documents
each case. `examples/` is a separate hand-inspectable demo, not test input.

The suite is weighted toward failures that would cost *data* rather than time:
same-size-different-content (the shape a false match takes), unreadable files exiting
`2`, hardlinks and intra-target duplicates, and a 2,500-file run that verifies sizes
stay aligned with paths across `xargs` batch boundaries.

Group 33 uses `stat` shims on `PATH` to exercise the GNU branch on macOS and the
degraded no-`stat` path. This shim technique is the way to test platform branches
here — prefer it over skipping.

When changing behaviour, add the regression test in the same commit; several existing
groups exist specifically because the predecessor script silently gave wrong answers.
