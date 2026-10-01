# Maintaining a Patch Repository for the PatchStack Module

The `PatchStack` buildfarm module applies an ordered series of patches from a
separate git repository on top of a fresh PostgreSQL checkout before each
build.  This document explains how to create and maintain that patches
repository.


## Repository layout

You need one git repository that animals will clone.  Inside it, create a
dedicated branch (conventionally named `quilt`).  On that branch, create one
subdirectory per PostgreSQL branch you want to cover:

```
quilt branch/
├── REL_17_STABLE/
│   ├── series
│   ├── 0001-first-fix.patch
│   └── 0002-second-fix.patch
├── REL_16_STABLE/
│   ├── series
│   └── 0001-backport.patch
└── master/
    ├── series
    ├── 0001-feature.patch
    └── 0002-follow-on.patch
```

The subdirectory name must match the PostgreSQL branch name as the buildfarm
knows it — `REL_17_STABLE`, `REL_16_STABLE`, etc.  The development branch is
tracked as `HEAD` by the buildfarm but animals are typically configured to map
`HEAD` → `master` (or `main`) in their `subdir` config, so name your
development subdirectory accordingly.

A missing subdirectory is not an error, but it is not the same as "build
without patches" either — the animal skips the build for that branch
entirely (a message is printed, and the module exits before any build step
runs). If the subdirectory exists but has no `series` file (or an empty
one), the build does proceed normally with no patches applied.


## The `series` file

`series` is a plain-text file that lists the patch filenames in application
order, one per line.  Blank lines and lines beginning with `#` are ignored
(quilt convention):

```
# fixes for the connection-reuse path
0001-fix-connection-leak.patch
0002-add-regression-test.patch
```

The module reads this file to determine which patches to apply and in what
order.


## Patch file format

Patches should still carry mail-style headers (`From:`, `Date:`, `Subject:`)
so that `git mailinfo` can extract the subject for the build report.  The
standard way to produce them is `git format-patch`:

```sh
# Single commit:
git format-patch -1 <commit>

# A series of commits:
git format-patch <base>..<tip>
```

Bare unified diffs (output of `diff -u` or `git diff`) apply when the
buildfarm applies the series itself, but they carry no subject, so they
are reported under their filename instead.  If the repository supplies a
driver (see the next section) they do not apply at all: a driver applies
with `git am`, which needs `From:` and `Subject:` to build a commit.
Producing patches with `git format-patch` avoids the question either way.


## Applying the stack the way a release wrap does

By default the buildfarm applies the series itself, one patch at a time
with `git apply`, creating no commits and leaving `HEAD` where it was.
For a stack that exists only to be tested, that is all you need and the
rest of this section does not apply to you.

It is not enough when the same stack is also applied by something else
for real — a release wrap that turns the stack into commits and ships
them.  Then there are two appliers, and what the farm tests is only
something resembling what the wrap produces.  A patch that `git apply`
takes and `git am` does not — one with no usable `From:` or `Subject:`,
say — passes on every animal and fails on wrap day, which is the most
expensive day to find out.

The fix is to put the applier in the patches repository and let both
callers run it.  Name it `import-series.pl`, at the top of the `quilt`
branch (not inside a per-branch subdirectory), and animals will use it
in place of their own loop:

```
quilt branch/
├── import-series.pl
├── REL_17_STABLE/
│   ├── series
│   └── 0001-first-fix.patch
└── master/
    ├── series
    └── 0001-feature.patch
```

The script has to accept two invocations.

`import-series.pl SERIES_DIR` applies the series in `SERIES_DIR` to the
current working directory, which is a clean git working tree sitting at
the commit the series belongs on top of.

`import-series.pl --list SERIES_DIR` prints its own reading of
`SERIES_DIR/series` and exits without touching anything: one line per
entry, in series order, the patch name and the strip level separated by
a tab, `-` where the line gives no level.

It must use these exit statuses:

| Status | Meaning |
| --- | --- |
| 0 | Everything applied, or `--list` printed the series. |
| 1 | One or more patches named in `series` are missing; nothing applied. |
| 2 | Usage or setup error — not a git tree, tree not clean, no `series`. |
| 3 | An entry failed to apply. |

Anything nonzero is reported as `PatchStackBroken`.

The animal does everything around the script and nothing inside it.  It
fetches the patches repository, works out whether the branch needs
rebuilding at all, resolves any shared `../master/foo.patch` entries and
symlinks into a directory of ordinary files, and hands that directory to
the script — so the script only ever opens plain files, exactly as it
does on wrap day against a real checkout.  Afterwards the animal resets
the source tree, so a driver is free to create commits and move `HEAD`;
`git am` state left behind by a failed entry is cleared too.

Before applying anything, the animal runs `--list` and compares it
against its own reading of the same `series` file, and reports a
disagreement instead of proceeding.  Two programs parse that file — the
animal because the identity that decides whether a branch rebuilds comes
out of it, the script because its reading is what gets applied — and
nothing else would notice if they read a line differently.  They have:
a strip level written after the `#` that carries a redmine id was once a
level to one reader and comment text to the other, which would have
applied a patch at a level no wrap would use, and reported green.  A
script that does not understand `--list` is reported as broken rather
than skipping the check.

Animals need no configuration for any of this: the default is to use
`import-series.pl` if the repository has one and the built-in loop if it
does not.  The `driver` setting in `patch_stack` exists for a repository
that keeps its applier under another name, and for an owner who wants
the built-in loop regardless:

```perl
    patch_stack => {
        ...
        driver => 'apply-stack.pl',   # another name
        # driver => '',               # never use a driver
    },
```

A name set here has to be there.  Naming one says the repository has an
applier of its own, so falling back from a name that turned out to be
wrong — applying the stack with something other than what the config
asked for, and still reporting a green build — is the failure this whole
arrangement exists to prevent.  Only the default name may be absent.


## Setting up the repository from scratch

```sh
# Create the patches repo (or use an existing one)
git init patches.git
cd patches.git

# Create an initial empty commit on the quilt branch
git checkout --orphan quilt
git commit --allow-empty -m "Initial quilt branch"

# Create the per-branch subdirectory
mkdir -p REL_17_STABLE
touch REL_17_STABLE/series
git add REL_17_STABLE/series
git commit -m "Add REL_17_STABLE stack skeleton"
```


## Adding a patch to the stack

1. Produce the patch with `git format-patch` from a PostgreSQL working tree:

   ```sh
   cd /path/to/postgres
   git format-patch -1 <commit> -o /path/to/patches.git/REL_17_STABLE/
   ```

2. Add the new filename to the end of `series`:

   ```sh
   echo "0003-new-fix.patch" >> REL_17_STABLE/series
   ```

3. Commit both the patch file and the updated `series`:

   ```sh
   cd /path/to/patches.git
   git add REL_17_STABLE/
   git commit -m "REL_17_STABLE: add fix for <description>"
   ```

4. Push to the remote so animals pick it up on their next run:

   ```sh
   git push origin quilt
   ```

Animals detect the change by comparing an identity computed from the patches
themselves — the blob SHA of every patch the branch's `series` names, in
order, plus the blob SHA of the `series` file itself — against their
recorded value.  Folding in the `series` blob is what makes a reordering or
a comment-only edit to `series` register, even though no patch file
changed.  Any push that changes the content a branch would apply triggers
a rebuild of that branch automatically,
including when the changed patch lives in another branch's subdirectory and
is reached by a relative path (see "Sharing a patch between branches"
below).  Patches a branch does not list contribute nothing, so a push
touching only one branch's stack does not rebuild the others.


## Removing or reordering patches

Edit `series` to remove or reorder entries, remove any patch files that are no
longer needed, then commit and push:

```sh
# remove a patch
git rm REL_17_STABLE/0001-reverted.patch
# edit series to remove the line
git add REL_17_STABLE/series
git commit -m "REL_17_STABLE: drop reverted patch"
git push origin quilt
```


## Rebasing the stack after upstream moves

When patches stop applying because upstream PostgreSQL has moved:

1. In a PostgreSQL working tree, apply the patches by hand on top of current
   upstream, resolve any conflicts, and re-export with `git format-patch`.

2. Replace the old patch files in the subdirectory with the new ones.  Rename
   files or update `series` if the set changed.

3. Commit and push.

Until the stack is rebased, animals will report `PatchStackBroken` for that
branch rather than a generic build failure, making it easy to tell "stack needs
maintenance" apart from "PostgreSQL broke something."

A `series` entry naming a patch file that is not present now stops the run and reports
`PatchStackBroken`, naming the entry. Until this changed the entry was
silently skipped and the branch built and reported green without it, so a
typo in `series` could hide a patch from testing indefinitely.


## Supporting multiple PostgreSQL branches

Each subdirectory is independent, so patches for REL_16_STABLE and
REL_17_STABLE can diverge freely.  When backporting a fix:

```sh
# Export from the REL_17_STABLE stack
cp REL_17_STABLE/0002-fix.patch REL_16_STABLE/0002-fix.patch
# verify it still applies; adjust if needed
echo "0002-fix.patch" >> REL_16_STABLE/series
git add REL_16_STABLE/
git commit -m "REL_16_STABLE: backport fix from 17"
git push origin quilt
```


### Sharing a patch between branches

When a patch applies unchanged to more than one branch, you can store it
once and reference it from the other branches' `series` files by relative
path, instead of keeping duplicate copies in sync:

```
# REL_16_STABLE/series
0001-local-fix.patch
../master/0002-cve.patch
```

The referenced patch is read from `master/` at build time, so editing it
updates every branch that names it, and every one of those branches is
rebuilt on the next run.  Keeping copies instead means remembering to update
each one.

Symlinks into another branch's subdirectory also work and are still
supported, but relative paths are preferred: they are visible in the
`series` file itself, and they behave identically on platforms without
filesystem symlink support.

Note that a shared patch is applied with more tolerance for drifting
context than one stored in the branch's own subdirectory.  A patch
written for a branch should apply to that branch exactly; if it stops
doing so, upstream has moved beneath the stack and you want to be told,
not to have it quietly absorbed.  A patch written against `master` and
reached from a stable branch is a different case: the surrounding code
legitimately differs, so it is allowed to match on less context.  If a
shared patch drifts far enough that even that fails, it has stopped
being the same patch for both branches and wants splitting into
per-branch copies.


## Viewing what was applied on the web dashboard

Each run writes a `patch_stack.log` artifact — separate from the main
checkout log — recording the series identity, the patches-repo commit
that was used, whether the series applied cleanly, which applier ran,
and the filename, content SHA, and subject of every patch it attempted.
The server renders it as its own table on the build's report page, with
a diff against the previous run showing patches added, removed, **and
modified** — a patch whose content changed under an unchanged filename
is now visible, which it was not before.  The stack identity and
patches-repo commit are shown alongside, so a given run can be tied to
an exact revision of the patches repo.  There's nothing to configure for
this — it's automatic whenever `PatchStack` is enabled — but it means
the `series` file's patch order and each patch's `Subject:` line are now
user-visible, so keep them meaningful.

## Verifying the repository locally

Before pushing, `check_patch_stack.pl` (in the buildfarm client repo)
reports whether each series applies to the matching source tree:

```sh
check_patch_stack.pl --sequential /path/to/patches.git /path/to/buildroot
```

`--manifest` instead checks that every `series` entry resolves to a patch
that is actually there, and prints what each one resolves to. It reads only
the patches repository, so unlike the modes above it needs no buildroot and
no PostgreSQL source tree:

```sh
check_patch_stack.pl --manifest /path/to/patches.git
```

```
=== series: REL_16_STABLE ===
  series                       4f2a9c1
  0001-local-fix.patch         8b3e77d
  ../master/0002-cve.patch     a91c204  -> master/0002-cve.patch
  patch_stack_id: 3d9f1ab400112233445566778899aabbccddeeff
```

The per-patch SHAs above are shown truncated to 7 characters, as `git log`
does; `patch_stack_id` is printed in full (40 characters), since that is
the exact value animals compare and there is no shorter form of it to
recognize.

An entry whose patch file is missing is reported as `(missing)` and the exit
status is 1. That is what this mode is for: a `series` naming a file that
is not there means the patch is not tested on that branch, and the mistake
is easy to make and easy to miss — a patch renamed but not renamed in
`series`, or added to one branch's `series` under the wrong name. Run it
before pushing and the farm never sees the mistake.

The `->` column shows where an entry resolved when that differs from the
entry itself, so shared patches are visible at a glance, and two branches
carrying the same blob SHA are demonstrably testing the same content.

`--manifest` reads the patches repo at its current `HEAD`, so uncommitted
changes there are invisible to it — including right before you push, which
is exactly when you are most likely to run it.  Commit first, then run
`--manifest`, to be sure it's reporting what you're about to push.

You can also apply the series by hand the same way an animal does:

```sh
git clone --branch REL_17_STABLE https://git.postgresql.org/git/postgresql.git /tmp/pg-test
cd /tmp/pg-test
while read -r patch rest; do
  case "$patch" in ''|\#*) continue;; esac
  git apply --index -C3 "/path/to/patches.git/REL_17_STABLE/$patch" || break
done < /path/to/patches.git/REL_17_STABLE/series
```

`check_patch_stack.pl --sequential` does exactly this, and reports which
patch failed.

If the repository has a driver, run that instead, which is both shorter
and the thing an animal will actually do:

```sh
git clone --branch REL_17_STABLE https://git.postgresql.org/git/postgresql.git /tmp/pg-test
cd /tmp/pg-test
perl /path/to/patches.git/import-series.pl /path/to/patches.git/REL_17_STABLE
```

`--list` is also the quick way to settle what a `series` line means:

```sh
perl /path/to/patches.git/import-series.pl --list /path/to/patches.git/REL_17_STABLE
```

Note that a driver run by hand reads the subdirectory as it stands, with
`../master/foo.patch` entries pointing at real files on disk and symlinks
followed by the filesystem.  An animal hands it a resolved copy instead.
The two agree except on a platform where a checked-out symlink is a text
file holding its target path, which is why animals resolve rather than
trusting the checkout.
