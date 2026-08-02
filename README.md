# salvage

[![ci](https://github.com/stphung/salvage/actions/workflows/ci.yml/badge.svg)](https://github.com/stphung/salvage/actions/workflows/ci.yml)

**If I delete this, what do I lose?**

`salvage` compares a directory against one or more backups *by content* — checksums,
via [rmlint](https://rmlint.readthedocs.io) — and lists the files that exist nowhere
else. Renamed, moved, and reorganised files still count as matches. Names, paths and
directory layout are irrelevant on both sides.

It only reports. It never copies, moves, or deletes anything.

```console
$ salvage ./old-drive -r ./backup
target:     /Users/me/old-drive
references: /Users/me/backup
comparison: blake2b · 51,830 files · 2.1 TB · scanned in 14m 32s

✗ 88.4 GB AT RISK — 4,212 of 51,830 files exist nowhere else.

  files  ██████████████████░░   91.9% covered   4,212 unmatched
  bytes  ████░░░░░░░░░░░░░░░░   20.1% covered   88.4 GB at risk

  Photos/2019/       ░░░░░░░░░░    0%  1,842/1,842 files   61.2 GB
  Photos/2020/       █████████░   89%    312/2,904 files    9.8 GB
  Documents/scans/   ███████░░░   73%     88/  120 files    4.1 GB

  largest at risk
    38.2 GB  Photos/2019/raw/wedding-master.mov
     9.4 GB  Video/2018-holiday.mp4
     4.1 GB  Documents/scans/archive-2003.tiff

  (full list on stdout — 4,212 paths; use --all to print here)
  (1,204 OS metadata files excluded; --no-default-excludes to include)
```

**92% of files but 20% of bytes** is the line that changes your decision — the
classic backup failure, where thousands of small files copied and the video library
didn't. An empty bar means a directory was never backed up at all. And `largest at
risk` is usually five entries that account for most of the total.

In a terminal those paths are clickable (⌘-click opens them in Finder). Bars, colour
and links appear only on a terminal — redirect stderr and you get the same report in
plain text, with stdout untouched either way.

## Install

`salvage` is a single self-contained shell script. It needs `rmlint` (≥ 2.10) and
`jq` at runtime, and nothing else.

```sh
brew install rmlint jq
make install                    # → ~/.local, no sudo
```

Or take a [release](https://github.com/stphung/salvage/releases) — the script alone is
the whole tool:

```sh
curl -fsSLo ~/.local/bin/salvage \
  https://github.com/stphung/salvage/releases/latest/download/salvage
chmod +x ~/.local/bin/salvage
```

`make install` places the script, its man page, and shell completions under `PREFIX`,
which defaults to `~/.local` and can be overridden:

```sh
make install PREFIX=/opt/homebrew        # alongside your other brew tools
sudo make install PREFIX=/usr/local      # system-wide
make uninstall                           # removes all four files
```

For development, `make link` symlinks the script instead of copying it, so edits take
effect immediately. The repo then has to stay where it is or the symlink dangles.

If you'd rather not use `make`, the script stands alone:

```sh
cp salvage ~/bin/salvage && chmod +x ~/bin/salvage
```

`make deps` reports whether `rmlint` and `jq` are present. `make help` lists every
target.

## Usage

```
salvage [OPTIONS] TARGET -r REFERENCE [-r REFERENCE ...]
```

The target is the first positional argument. References are given with `-r` and may
be repeated — a file counts as matched if its content appears in *any* of them. Bare
positional references are rejected, so a mistyped path can never silently become a
reference and make your coverage look better than it is.

Target and reference trees may not overlap. rmlint won't call a file a duplicate of
itself, so an overlapping run would report everything as unmatched; `salvage` refuses
rather than answer wrongly.

Full details in `man salvage`.

### Two streams

**stdout** is the manifest: unmatched paths, one per line, relative to the target,
sorted. Nothing else.

**stderr** is the report you read: header, totals, per-directory rollup, footnotes,
and a progress bar while scanning if it's a terminal.

So one run serves both the reader and the pipeline:

```sh
salvage ./old-drive -r ./backup > manifest.txt     # report on screen, list in file
rsync -av --files-from=manifest.txt ./old-drive/ ./rescued/
```

Relative paths are the default precisely because that's the form `rsync --files-from`
takes.

### Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Every file in the target has a content match |
| `1`  | Some files have no match |
| `2`  | Error — usage, missing dependency, bad input, unreadable file, interrupt |

```sh
salvage ./old-drive -r ./backup >/dev/null && echo "fully covered"
```

An unreadable file is always a `2`, never a `0`. A permissions error must not be able
to masquerade as a clean bill of health.

Since `1` is a normal outcome rather than a failure, callers under `set -e` need
`|| true` or an explicit check. This follows `diff` and `grep`.

## Where should it go? (`--suggest`)

Once you know a file exists nowhere else, the next question is where in the backup it
belongs. `salvage` infers that — and the destination is **learned, not guessed**.

rmlint pairs every matched file with its reference twin, so each match reveals where
that directory's contents already live. If your backup reorganised `src/` into `lib/`,
the suggestion follows the reorganisation instead of mirroring the target:

```console
$ salvage ./project -r ./backup --suggest

  suggested placement
    src/new_module.rs      →  backup/src/new_module.rs
                              siblings 1/1
    vendor/pkg/sub/dep.rs  →  backup/vendor/pkg/sub/dep.rs
                              inherited from ./ (siblings 1/1) · confidence 70%
    src/lib.rs             →  backup/src/lib.rs
                              same name already in the reference, with different content  ⚠ would overwrite
```

Every suggestion says how it was reached:

| Reason | Meaning |
|---|---|
| `siblings n/m` | *n* of *m* matched files in that directory landed here. Unanimous = full confidence. |
| `inherited from DIR/` | No matched file in this directory; used the nearest mapped ancestor. Reduced confidence. |
| `mirrored` | No signal anywhere above it. Reproduces the target layout. Zero confidence. |
| `same name … different content` | Not a new file — a **changed** one. Copying would overwrite the backup's copy. |

With several references, placement follows whichever one the matched siblings used.

### Moving files in

`salvage` still never touches your data. `--plan` writes a shell script for you to
read and run:

```sh
salvage ./project -r ./backup --plan rescue.sh
less rescue.sh          # every line commented with its reason
sh rescue.sh
salvage ./project -r ./backup && echo "now fully covered — safe to delete"
```

Overwrites and collisions are emitted **commented out**, so the default run can't
clobber anything. The plan copies rather than moves: rerunning is harmless, the target
stays intact, and you verify with a second `salvage` run before deleting anything.

## What gets compared

**Hidden files are compared.** `.env`, `.gitignore`, `.git/` — all of it. They're
your data.

**Empty files and symlinks are not.** Neither carries content you could lose. Both
are counted in a footnote so the omission is never silent.

**OS bookkeeping is excluded by default** — `.DS_Store`, `._*`, `.Spotlight-V100`,
`.fseventsd`, `.Trashes`, `.TemporaryItems`, `.DocumentRevisions-V100`, `Thumbs.db`,
`desktop.ini`, `$RECYCLE.BIN`, `System Volume Information`, `.Trash-*`. It's
regenerated automatically and would otherwise bury the files you care about under
thousands of lines. The count is always reported; `--no-default-excludes` turns it
off.

The distinction: hidden *user data* is included; filesystem *scratch space* is not.

## Options

| Option | Effect |
|---|---|
| `-r`, `--reference DIR` | Reference tree. Repeatable. |
| `--absolute` | Absolute paths instead of relative to the target |
| `--print0` | NUL-delimit stdout — for `xargs -0`, and for filenames containing newlines |
| `--all` | Always print the full list on stderr, however long |
| `--no-rollup` | Omit the per-directory summary |
| `-p`, `--paranoid` | Byte-for-byte comparison instead of blake2b |
| `--exclude GLOB` | Additional exclusion. Repeatable. No `/` matches basenames; otherwise the relative path |
| `--no-default-excludes` | Include OS metadata |
| `--exclude-hidden` | Skip dotfiles entirely |
| `--suggest` | Show where each unmatched file belongs in the reference |
| `--suggest-json PATH` | Those suggestions as JSON, with reason and confidence |
| `--plan PATH` | Reviewable shell script that copies them into place (never run by salvage) |
| `--json PATH` | Structured report — counts, bytes at risk, per-file sizes |
| `--save-scan PATH` | Raw rmlint JSON, replayable with `rmlint --replay` |
| `-v`, `--verbose` | Pass rmlint's output through |
| `-q`, `--quiet` | Suppress progress and the report |
| `--no-color` | Disable colour (`NO_COLOR` is honoured too) |

### Hashing

The default is blake2b (512-bit). A collision would produce a *false match* — the tool
telling you a file is safely backed up when it isn't — which is the only error mode
here that loses data. At 512 bits you are many orders of magnitude more likely to hit
a silent disk read error. `--paranoid` does true byte-for-byte comparison if you want
it anyway; it uses noticeably more memory. Whichever ran is printed in the header, so
a saved report says how it reached its verdict.

### Large scans

Hashing a multi-terabyte drive takes hours. `--save-scan` keeps rmlint's raw output so
`rmlint --replay` can re-answer follow-up questions in seconds instead of re-reading
the disk. `--json` gives a dated, structured record — diff two of them to see what
became newly unbacked without touching either drive.

## Examples

```sh
# is everything on the old drive somewhere in either backup?
salvage /Volumes/Old -r /Volumes/BackupA -r /Volumes/BackupB

# ignore build output and logs
salvage ./project -r ./backup --exclude 'node_modules/**' --exclude '*.log'

# safe for any filename
salvage ./old -r ./backup --print0 | xargs -0 -n1 ls -l

# try it on the bundled example
make demo
```

## Development

```sh
make test              # 118 assertions in 33 groups, generated fixtures, ~16s
make test T="5 22"     # just those groups
make test T="-k stat"  # groups whose name matches
make list-tests        # what's available
./tests/run.sh -v      # show every passing assertion
make lint              # static analysis — the exact command CI runs
make lint-tools        # brew install shellcheck actionlint
```

### Static analysis

`make lint` is the only entry point, and CI invokes it verbatim. The file list lives
in the `Makefile` and the severity and suppressions live in `.shellcheckrc`, so there
is no command line to keep in sync between a laptop and a runner.

- **`bash -n`** on every shell file — zero dependencies, always runs
- **shellcheck** at `severity=style`, its strictest level, not the default `warning`
- **actionlint** on the workflows

A missing tool is an **error**, not a skip: a linter that quietly does nothing is
worse than no linter, because CI stays green while checking less than you think.
`make lint SKIP_MISSING=1` downgrades that to a warning when you genuinely want it.

One suppression is configured, `SC2329` ("function never invoked"), which is wrong
here in two places by design — `cleanup`/`on_signal` are reached through `trap`, and
the test functions are dispatched by name from `declare -F`. Both are invisible to
static analysis. The reasoning is written into `.shellcheckrc`.

Fixtures are generated rather than committed: empty files, symlinks and
newline-in-name files don't survive git or a zip faithfully, and the code that builds
each case documents the case.

The suite leans hardest on cases where a wrong answer would cost data rather than
time — same-size-different-content (the shape a false match would take), unreadable
files exiting `2` rather than `0`, hardlinks and intra-target duplicates being fully
accounted for, and a 2,500-file run checking that sizes stay aligned with paths across
`xargs` batch boundaries. Both the BSD and GNU `stat` branches are exercised on
whichever platform you run, using a shim.

`examples/project` and `examples/backup` are a hand-inspectable demo — a small Rust
project partially backed up, with a moved file, a renamed file, changed content and
several files missing entirely.

### Releasing

CI runs the suite on macOS for every push.

A Linux job was tried and removed: dependencies installed and the version check
passed, but the suite then hung with no output and was cancelled after 15 minutes.
The cause is unidentified. So the GNU `stat` branch is currently covered only by the
shim in test group 33 — that proves the branch is selected and returns correct sizes,
but not that a real GNU userland behaves as assumed.

To cut a release, bump the version in **two** places — `VERSION=` in `salvage` and the
`.TH` line of `doc/salvage.1` — then tag:

```sh
make check-version          # refuses if the two disagree
git tag v1.1.0 && git push origin v1.1.0
```

The release workflow re-checks that the tag agrees with both, runs the suite, builds
the artifacts, then **extracts the tarball, installs it, and runs the installed copy**
before publishing — a release nobody installed is how broken releases ship.

Artifacts: the bare `salvage` script, a tarball with the man page and completions, and
`SHA256SUMS`.

### Portability

Targets bash 3.2, the version macOS ships, so it runs on a stock Mac with no Homebrew
bash. `stat` is probed at startup rather than sniffed from the OS name, so BSD, GNU
and busybox userlands all work; if none does, the report loses its size column rather
than reporting anything wrong.

Set operations run inside `jq` rather than `sort`/`comm`, which keeps them safe
against newlines in filenames and independent of locale collation. BSD `comm` has no
`-z`, so this was the only correct option available.

## Layout

```
salvage                  the tool — one file, no includes
doc/salvage.1            man page
completions/             zsh and bash completions
tests/run.sh             the suite
examples/{project,backup}  demo fixtures
Makefile                 install, uninstall, test, lint
```
