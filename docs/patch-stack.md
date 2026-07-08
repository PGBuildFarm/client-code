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

Patches **must** carry mail-style headers (`From:`, `Date:`, `Subject:`) so
that `git mailinfo` can extract the author and subject.  The standard way to
produce them is `git format-patch`:

```sh
# Single commit:
git format-patch -1 <commit>

# A series of commits:
git format-patch <base>..<tip>
```

Bare unified diffs (output of `diff -u` or `git diff`) will not work — they
lack the authorship information that the importer requires.


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

Animals detect the change by comparing the git tree SHA of the subdirectory
against their recorded value.  Any push that changes the subdirectory tree
triggers a rebuild automatically.


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


## Viewing what was applied on the web dashboard

Each run writes a `patch_stack.log` artifact — separate from the main
checkout log — recording the series identity, whether it applied
cleanly, and the filename/subject of every patch it attempted. This
travels to the server the same way `githead.log` does, and the server
renders it as its own table on the build's report page (with an
added/removed diff against the previous run when the series changed),
instead of it being buried in the raw `SCM-checkout` log text. There's
nothing to configure for this — it's automatic whenever `PatchStack` is
enabled — but it means the `series` file's patch order and each patch's
`Subject:` line are now user-visible, so keep them meaningful.

## Verifying the repository locally

Before pushing, you can verify that the series applies cleanly by running
`git quiltimport` in a throw-away clone of PostgreSQL:

```sh
git clone --branch REL_17_STABLE https://git.postgresql.org/git/postgresql.git /tmp/pg-test
git -C /tmp/pg-test quiltimport --patches /path/to/patches.git/REL_17_STABLE
```

A zero exit code means every patch applied; a non-zero exit code (plus the
reject output) shows what needs attention before you push.
