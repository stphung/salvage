# salvage

Find the files in a directory whose content isn't present anywhere in your backups.

`salvage` answers one question: **if I delete this, what do I lose?** It compares by
content — checksums, via [rmlint](https://rmlint.readthedocs.io) — so renamed, moved
and reorganised files still count as matches. Names, paths and directory layout are
irrelevant on both sides.

It only reports. It never copies, moves, or deletes anything.

```
$ salvage ./old-drive -r ./backup
target:     /Users/me/old-drive
references: /Users/me/backup
comparison: blake2b

4,212 of 51,830 files have no content match — 88.4 GB

  Photos/2019/         1,842/1,842 files   61.2 GB  ← nothing matched
  Photos/2020/           312/2,904 files    9.8 GB
  Documents/scans/        88/  120 files    4.1 GB
  ...

  (full list on stdout — 4,212 paths; use --all to print here)
  (1,204 OS metadata files excluded; --no-default-excludes to include)
```

## Install

Requires `rmlint` (≥ 2.10) and `jq`.

```sh
brew install rmlint jq
git clone <this repo> ~/src/salvage
ln -s ~/src/salvage/salvage /usr/local/bin/salvage
```

The symlink means `git pull` updates the installed command. It also means the repo
has to stay where it is — move it and the symlink dangles.

## Usage

```
salvage [OPTIONS] TARGET -r REFERENCE [-r REFERENCE ...]
```

The target is the first positional argument. References are given with `-r` and may
be repeated; a file counts as matched if its content appears in *any* of them. Bare
positional references are rejected, so a mistyped path can never silently become a
reference and make your coverage look better than it is.

Target and reference trees may not overlap. rmlint won't call a file a duplicate of
itself, so an overlapping run would report everything as unmatched — `salvage` refuses
rather than lying.

### Two streams

**stdout** is the manifest: unmatched paths, one per line, relative to the target,
sorted. Nothing else — no header, no counts.

**stderr** is the report you read: header, totals, per-directory rollup, footnotes,
and a progress bar while scanning if it's a terminal.

That split means the same run serves both purposes:

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

An unreadable file is a `2`, never a `0`. A permissions error must not be able to
masquerade as a clean bill of health.

## What gets compared

**Hidden files are compared.** `.env`, `.gitignore`, `.git/` — all of it. They're
your data.

**Empty files and symlinks are not.** Neither carries content you could lose. Both
are counted in a footnote so the omission is never silent.

**OS bookkeeping is excluded by default** — `.DS_Store`, `._*`, `.Spotlight-V100`,
`.fseventsd`, `.Trashes`, `.TemporaryItems`, `.DocumentRevisions-V100`, `Thumbs.db`,
`desktop.ini`, `$RECYCLE.BIN`, `System Volume Information`, `.Trash-*`. It's
regenerated automatically and would otherwise bury the files you care about under
thousands of lines. `--no-default-excludes` turns that off.

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
salvage examples/project -r examples/backup
```

## Development

```sh
tests/run.sh        # 59 assertions, generated fixtures
tests/run.sh -v     # show each one
```

Fixtures are generated rather than committed: empty files, symlinks and
newline-in-name files don't survive git or a zip faithfully, and the code that builds
each case documents the case.

`examples/project` and `examples/backup` are a hand-inspectable demo — a small Rust
project partially backed up, with a moved file, a renamed file, changed content and
several files missing entirely.

Targets bash 3.2, the version macOS ships, so it runs on a stock Mac with no Homebrew
bash. Set operations run inside `jq` rather than `sort`/`comm`, which keeps them safe
against newlines in filenames and independent of locale collation.
