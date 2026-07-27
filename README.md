# salvage

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
comparison: blake2b

4,212 of 51,830 files have no content match — 88.4 GB

  Photos/2019/         1,842/1,842 files   61.2 GB  ← nothing matched
  Photos/2020/           312/2,904 files    9.8 GB
  Documents/scans/        88/  120 files    4.1 GB
  ... 34 more directories

  (full list on stdout — 4,212 paths; use --all to print here)
  (1,204 OS metadata files excluded; --no-default-excludes to include)
```

That rollup is the point: `Photos/2019` was never backed up at all, and it's 61 GB.
A flat list of 4,212 filenames would not have told you that.

## Install

`salvage` is a single self-contained shell script. It needs `rmlint` (≥ 2.10) and
`jq` at runtime, and nothing else.

```sh
brew install rmlint jq
make install                    # → ~/.local, no sudo
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
make lint              # shellcheck, if installed
```

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
