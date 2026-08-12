# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=pod

Copyright (c) 2003-2026, Andrew Dunstan

See accompanying License file for license details

=head1 PGBuild::Modules::PatchStack

Apply an ordered series of patches from a separate "quilt-style" git
repository on top of the freshly checked-out PostgreSQL source tree
before the build runs, then restore the worktree to its pre-apply
upstream state after the run finishes.

The patches are expected to live on a dedicated branch of a separate
git repo, with a per-Postgres-branch subdirectory holding a C<series>
file and the patch files referenced by it (one per line, applied in
order).

Patches are applied with C<git apply>, one at a time in series order,
stopping at the first entry that is missing or fails to apply. No
commits are created and C<HEAD> never moves; the working tree is
restored after the run.

Patch files should still carry C<From:> and C<Subject:> headers (i.e.
be produced by C<git format-patch> or equivalent), because the subject
is extracted with C<git mailinfo> for the build report. Unlike
C<git quiltimport>, which this replaced, a bare diff will now apply --
it will simply be reported under its file name.

A patch shared unchanged across branches may be referenced rather than
copied, as a C<series> entry giving a relative path into another
branch's subdirectory -- commonly C<../master/foo.patch>. Symlinks into
another branch's subdirectory are also resolved, but are no longer used
in practice; the support remains so that existing stacks do not
regress.

Both forms are resolved via git's own tree and blob data, not the
checked-out working tree, so they work regardless of the platform's
filesystem symlink support (and of whether C<..> in the path has been
normalized -- a raw C<git show HEAD:path> silently returns empty
content for an unnormalized path instead of erroring, so paths are
normalized before being resolved). A patch listed in a branch's
C<series> with no entry in the patches branch is a broken patch stack
for that branch: the run stops there and reports C<PatchStackBroken>,
naming the entry. C<git quiltimport>, used before this, skipped such
an entry and exited zero, so a branch could build and report a green
result with a patch missing from its stack.

=head2 RUN TRIGGER

The module forces a run whenever the identity of this branch's patch
series differs from the value recorded on the previous run. That
identity is a digest over the resolved blob SHA of every patch the
series names, in order -- not the git tree SHA of the branch's
subdirectory.

The distinction matters when a patch is shared between branches. A
series entry may name a patch in another branch's subdirectory, as
C<../master/foo.patch>. Editing that patch does not change the
referring branch's subdirectory tree, because the C<series> blob still
holds the same text, so a tree-SHA trigger never fired and the branch
was neither rebuilt nor retested against the changed patch.

The series was still applied on every run -- the C<checkout> hook fires
unconditionally, and C<run_branches.pl> declines to prune branches when
this module is configured -- so a patch that had stopped applying was
still reported as C<PatchStackBroken>. What was missing was any
verification that the patched tree still built and passed its tests,
and any record of which stack content had been exercised.

Digesting resolved content instead tracks what the branch would
actually apply. Patches the branch does not name contribute nothing, so
an unrelated change elsewhere in the patches repo still does not cause
a build here.

This is in addition to the usual upstream-branch trigger, so a build
kicks off when either the upstream branch or the patch series moves.

The identity changed shape when content digests replaced subdirectory
tree SHAs. On the first run after upgrading from an earlier client,
the recorded value is a tree SHA and the computed one is a digest, so
each configured branch rebuilds once and then settles.

=head2 CONFIGURATION

In the animal's C<build-farm.conf>:

    patch_stack => {
        repo            => 'https://example.org/git/some-patches.git',
        patches_branch  => 'quilt',       # default: quilt
        local_repo      => undef,         # default: <buildroot>/patch_stack.<animal>
        subdir => {
            # map Postgres branch name to subdirectory name in the
            # patches branch. Default for unlisted branches is the
            # Postgres branch name itself.
            HEAD => 'master',
        },
    },

Add C<PatchStack> to the animal's C<modules> list. Branches whose
subdirectory is missing in the patches branch are silently skipped
(a message is printed in verbose mode).

=cut

package PGBuild::Modules::PatchStack;

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils       qw(:DEFAULT $st_prefix $branch_root $devnull);
use PGBuild::PatchSeries qw(series_manifest materialize_series apply_series);

use File::Path qw(mkpath);

use strict;
use warnings;

(my $MODULE = __PACKAGE__) =~ s/PGBuild::Modules:://;

our ($VERSION); $VERSION = 'REL_21';

my $hooks = {
	'checkout' => \&checkout,
	'post-checkout-log' => \&_write_patch_stack_log,
	'need-run' => \&need_run,
	'cleanup' => \&cleanup,
};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;
	my $branch = shift;
	my $conf = shift;
	my $pgsql = shift;

	# git-only — quiltimport has no equivalent in other SCMs
	return if defined $conf->{scm} && $conf->{scm} ne 'git';

	my $stackconf = $conf->{patch_stack};
	return unless ref($stackconf) eq 'HASH';
	return unless $stackconf->{repo};

	my $subdir_map = $stackconf->{subdir} || {};
	my $subdir =
	  exists $subdir_map->{$branch} ? $subdir_map->{$branch} : $branch;
	return unless defined $subdir && $subdir ne '';

	my $local_repo = $stackconf->{local_repo}
	  || "$buildroot/patch_stack.$conf->{animal}";

	my $self = {
		buildroot => $buildroot,
		pgbranch => $branch,
		bfconf => $conf,
		pgsql => $pgsql,
		srcdir => "$buildroot/$branch/pgsql",
		repo => $stackconf->{repo},
		patches_branch => $stackconf->{patches_branch} || 'quilt',
		subdir => $subdir,
		local_repo => $local_repo,
		applied => 0,
		patches_id => '',
		stack_commit => '',
		manifest => undef,
	};
	bless($self, $class);

	register_module_hooks($self, $hooks);
	return;
}

sub _fetch_or_clone
{
	my $self = shift;
	my $log = shift;
	my $local = $self->{local_repo};
	my $br = $self->{patches_branch};

	if (-d "$local/.git")
	{
		my @out = run_log("git -C $local fetch --quiet --prune origin");
		push(@$log, @out);
		die "fetching $self->{repo}\n" if $? >> 8;
	}
	else
	{
		mkpath($local);
		my @out = run_log("git clone --quiet $self->{repo} $local");
		push(@$log, @out);
		die "cloning $self->{repo}\n" if $? >> 8;
	}

	# Sync the local checkout with the upstream tip of the patches
	# branch so we always pick up the latest series. Fetch $br by
	# name: a single-ref fetch rewrites FETCH_HEAD to the tip of
	# exactly that ref, so the checkout below is guaranteed to land
	# on the patches branch regardless of what any earlier fetch
	# (e.g. the --prune one above) left in FETCH_HEAD.
	#
	# We use FETCH_HEAD rather than origin/$br to stay agnostic
	# about how the patches branch is named: it may contain slashes
	# that some git versions handle awkwardly in remote-tracking
	# refs. For the same reason the local working branch gets a
	# fixed name (patch_stack_local) instead of mirroring $br.
	my @out = run_log("git -C $local fetch --quiet origin $br");
	push(@$log, @out);
	die "fetching $br from $self->{repo}\n" if $? >> 8;

	@out = run_log(
		"git -C $local checkout --quiet -B patch_stack_local " . "FETCH_HEAD");
	push(@$log, @out);
	die "checking out $br at FETCH_HEAD\n" if $? >> 8;
	return;
}

# Tree SHA of this branch's subdirectory in the patches branch, or empty
# string if the subdirectory is not there at all. Used only to decide
# whether this branch has a stack; the identity that decides whether the
# stack has *changed* is the content digest from series_manifest(),
# because a subdirectory tree SHA does not move when a patch reached by
# a "../master/foo.patch" series entry is edited.
sub _subdir_tree
{
	my $self = shift;
	my $local = $self->{local_repo};
	my $sub = $self->{subdir};

	my $id = `git -C $local rev-parse --verify --quiet "HEAD:$sub" 2>$devnull`;
	chomp $id;
	return $id;
}

# Log the patch series from the manifest computed in checkout(), rather
# than a fresh read of series, one line per patch: the file name (as
# listed in series) followed by the subject. We derive the subject the
# same way quiltimport does for the commit it creates -- via
# "git mailinfo", which unwraps the header and strips any "[PATCH ...]"
# prefix -- falling back to the file name minus a trailing ".patch" when
# the patch carries no Subject: header.
#
# Returns the parsed list as an arrayref of { name => , sha => ,
# subject => } hashrefs, so callers can reuse it (e.g. to write
# patch_stack.log) without re-deriving the subjects.
sub _log_series
{
	my $self = shift;
	my $log = shift;
	my $patchdir = shift;

	my $entries = $self->{manifest} ? $self->{manifest}{entries} : [];

	push(@$log, "$MODULE: series (" . scalar(@$entries) . " patches):\n");
	my @parsed;
	foreach my $e (@$entries)
	{
		my $name = $e->{name};
		my $file = "$patchdir/$name";
		my $subject = '';
		if (-f $file)
		{
			my $info = `git mailinfo $devnull $devnull < "$file" 2>$devnull`;
			($subject) = $info =~ /^Subject:[ \t]*(.*)$/m;
		}
		else
		{
			$subject = '(missing)';
		}
		if (!defined $subject || $subject eq '')
		{
			($subject = $name) =~ s/\.patch$//;
		}

		my $short = substr(defined $e->{sha} ? $e->{sha} : '', 0, 7);
		push(@$log, "    $name [$short]: $subject\n");
		push(@parsed, { name => $name, sha => $e->{sha}, subject => $subject });
	}
	return \@parsed;
}

# Materialize a plain-file copy of the patch series with any symlinks
# resolved to their real content (see PGBuild::PatchSeries::series_manifest),
# so quiltimport and our own mailinfo parsing operate on real patch
# content regardless of the platform's symlink support.
sub _build_resolved_dir
{
	my $self = shift;
	my $log = shift;
	my $sub = $self->{subdir};
	my $local = $self->{local_repo};
	my $manifest = $self->{manifest};

	die "resolving $sub/series\n" unless $manifest;

	my $dest = "$local.resolved/$sub";
	rmtree($dest) if -d $dest;
	my $skipped = materialize_series($local, $manifest, $dest);
	push(@$log, "$MODULE: could not resolve $sub/$_, skipping\n")
	  foreach @$skipped;
	return $dest;
}

sub _apply_patches
{
	my $self = shift;
	my $log = shift;
	my $local = $self->{local_repo};
	my $sub = $self->{subdir};
	my $srcdir = $self->{srcdir};
	my $patchdir = "$local/$sub";

	unless (-f "$patchdir/series")
	{
		push(@$log, "$MODULE: no series file at $patchdir/series\n");
		$self->{series_status} = 'no-series';
		return 1;
	}

	my $resolved = eval { $self->_build_resolved_dir($log) };
	if ($@)
	{
		push(@$log, "$MODULE: $@");
		$self->{series_status} = 'broken';
		return 0;
	}
	$patchdir = $resolved;

	$self->{series_patches} = $self->_log_series($log, $patchdir);

	# A partially applied series must still be cleaned up, so record
	# that the tree has been touched before the first patch lands.
	$self->{applied} = 1;

	push(@$log, "$MODULE: applying patch series from $patchdir\n");

	my $result = apply_series($self->{manifest}, $patchdir, $srcdir, undef);

	# git apply reports context reduction on a SUCCESSFUL apply, so
	# carry the output of every entry, not just a failing one.
	foreach my $a (@{ $result->{applied} })
	{
		push(@$log, "  $a->{name}\n");
		push(@$log, $a->{output}) if defined $a->{output} && $a->{output} ne '';
	}

	unless ($result->{ok})
	{
		my $f = $result->{failure};
		push(@$log,
			"$MODULE: $f->{reason}: $sub/$f->{name}\n",
			defined $f->{detail} ? $f->{detail} : '');
		$self->{series_status} = 'broken';
		return 0;
	}

	$self->{series_status} = 'applied';
	return 1;
}

# Write patch_stack.log: a small structured record of the patch series
# just processed, separate from the free-form checkout log, so the
# server can parse and render it distinctly (mirroring the githead.log
# precedent) without needing a new webtxn field or DB column.
#
# checkout() runs before run_build.pl's cleanlogs() empties and
# recreates lastrun-logs, so a write from there would normally be lost
# as soon as cleanlogs() ran. When the series applies cleanly, checkout()
# returns and the run continues on to cleanlogs(), so this is registered
# as the 'post-checkout-log' hook, which run_build.pl fires after
# cleanlogs(), once lastrun-logs is settled for the run. When the series
# is broken, checkout() calls send_result(), which reports and exits the
# process well before cleanlogs() would run -- so that path writes the
# log directly, right before send_result(), instead of relying on the
# hook.
# Build the contents of patch_stack.log as a list of lines. Split out
# from _write_patch_stack_log so the format can be exercised without a
# lastrun-logs directory to write into.
#
# Header lines must not contain a tab. A server that does not know a key
# skips it precisely because it matches neither the "key: value" pattern
# nor the tab-delimited patch pattern, so a tab in a header would be
# parsed as a bogus patch entry by older servers.
sub _patch_stack_log_lines
{
	my $self = shift;

	my @lines;
	push(@lines, "patch_stack_format: 2\n");
	push(@lines,
			"patch_stack_id: "
		  . (defined $self->{patches_id} ? $self->{patches_id} : '')
		  . "\n");
	push(@lines,
			"patch_stack_commit: "
		  . (defined $self->{stack_commit} ? $self->{stack_commit} : '')
		  . "\n");
	push(@lines,
		"patch_stack_source: $self->{patches_branch}:$self->{subdir}\n");
	push(@lines,
			"patch_stack_status: "
		  . (defined $self->{series_status} ? $self->{series_status} : '')
		  . "\n");

	foreach my $p (@{ $self->{series_patches} || [] })
	{
		push(
			@lines,
			join("\t",
				$p->{name},
				(defined $p->{sha}     ? $p->{sha}     : ''),
				(defined $p->{subject} ? $p->{subject} : ''))
			  . "\n"
		);
	}
	return \@lines;
}

sub _write_patch_stack_log
{
	my $self = shift;

	writelog('patch_stack', $self->_patch_stack_log_lines());
	return;
}

sub checkout
{
	my $self = shift;
	my $savescmlog = shift;

	print time_str(), "$MODULE: preparing patch stack for $self->{pgbranch}\n"
	  if $verbose;

	push(@$savescmlog, "------------- $MODULE checkout ----------------\n");

	eval { $self->_fetch_or_clone($savescmlog); };
	if ($@)
	{
		push(@$savescmlog, "$MODULE: $@");
		send_result("$MODULE-fetch", 1, $savescmlog);
	}

	my $subdir_tree = $self->_subdir_tree();
	push(@$savescmlog,
			"$MODULE: $self->{patches_branch}:$self->{subdir} = "
		  . ($subdir_tree || '(absent)')
		  . "\n");

	unless ($subdir_tree)
	{
		print time_str(),
		  "$MODULE: subdirectory '$self->{subdir}' absent in"
		  . " patches branch, skipping build\n";

		# We exit here rather than trying to inhibit via need_run because
		# the need-run hook can only force a run (by setting $$run_needed=1);
		# it cannot suppress a run triggered by upstream file changes. The
		# checkout hook runs before need-run, so exit 0 is the only way to
		# prevent the build without modifying run_build.pl.
		exit 0;
	}

	# Compute the series identity before applying anything, so that a
	# series which fails to apply still has an identity to report.
	my $manifest = series_manifest($self->{local_repo}, $self->{subdir});
	$self->{manifest} = $manifest;
	$self->{patches_id} = $manifest ? $manifest->{id} : '';

	my $commit =
	  `git -C $self->{local_repo} rev-parse --verify --quiet HEAD 2>$devnull`;
	chomp $commit;
	$self->{stack_commit} = $commit;

	push(@$savescmlog,
			"$MODULE: patches commit $commit, series id "
		  . ($self->{patches_id} || '(none)')
		  . "\n");

	my $ok = $self->_apply_patches($savescmlog);

	unless ($ok)
	{
		$self->_write_patch_stack_log();
		send_result('PatchStackBroken', 1, $savescmlog);
	}

	return;
}

sub need_run
{
	my $self = shift;
	my $run_needed = shift;

	my $stfile = "$branch_root/${st_prefix}last.patch_stack";
	my $last_id = '';
	if (open(my $fh, '<', $stfile))
	{
		my $line = <$fh>;
		close $fh;
		if (defined $line)
		{
			chomp $line;
			$last_id = $line;
		}
	}
	my $cur_id = $self->{patches_id};

	if ($cur_id ne $last_id)
	{
		print time_str(),
		  "$MODULE: patches changed ('$last_id' -> '$cur_id'),"
		  . " forcing run\n"
		  if $verbose;
		$$run_needed = 1;
	}

	# Always rewrite, even if empty, so a transition from
	# "had patches" to "no patches" is recorded and only triggers
	# a single rebuild rather than every subsequent run.
	if (open(my $fh, '>', $stfile))
	{
		print $fh "$cur_id\n";
		close $fh;
	}
	return;
}

sub cleanup
{
	my $self = shift;

	# When rm_worktrees is on the END block has already wiped the
	# worktree files; running git commands here would just resurrect
	# them. The next run's SCM update restores the tree anyway.
	return if $self->{bfconf}->{rm_worktrees};

	my $srcdir = $self->{srcdir};
	return unless -d "$srcdir/.git";

	return unless $self->{applied};

	# HEAD never moved, so this restores pristine upstream. Because the
	# patches were applied with --index, it also removes files they
	# added. The clean sweeps anything that escaped: the buildfarm never
	# builds in the source tree, so nothing untracked there is ours to
	# keep, and one leaked file would otherwise be compiled on every
	# subsequent run. -fd rather than -fdx: ignored files are left
	# alone.
	print time_str(), "$MODULE: restoring $srcdir\n" if $verbose > 1;
	run_log("git -C $srcdir reset --hard --quiet HEAD");
	run_log("git -C $srcdir clean -qfd");
	return;
}

1;
