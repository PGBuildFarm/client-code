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

Patches are imported with C<git quiltimport>, which creates a real
commit per patch and preserves authorship. This means the patch
files must carry C<From:> and C<Subject:> headers (i.e. be produced
by C<git format-patch> or equivalent) so that C<git mailinfo> can
extract the author. Bare diffs will not import.

A patch shared unchanged across branches may be referenced rather
than copied: either as a C<series> entry using a relative path into
another branch's subdirectory (commonly C<../master/foo.patch>), or
as a symlink into another branch's subdirectory. Both forms are
resolved via git's own tree/blob data, not the checked-out working
tree, so it works regardless of the platform's filesystem symlink
support (and of whether C<..> in the path has been normalized -- a
raw C<git show HEAD:path> silently returns empty content for an
unnormalized path instead of erroring, so paths are normalized
before being resolved). A patch listed in a branch's C<series> with
no entry at all in the patches branch (not even by relative path or
symlink) is a broken patch stack for that branch: it is logged and
left out of the import, which then fails loudly rather than silently
applying a substitute from elsewhere.

=head2 RUN TRIGGER

The module forces a run whenever the patch-stack subdirectory tree
identifier (the git tree SHA of C<< I<patches_branch>:I<subdir> >>)
differs from the value recorded on the previous run. This is in
addition to the usual upstream-branch trigger, so a build kicks off
when either the upstream branch or the patch series moves.

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
use PGBuild::Utils qw(:DEFAULT $st_prefix $branch_root $devnull);

use File::Path     qw(mkpath);
use File::Basename qw(dirname);

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
		pre_apply_sha => '',
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

# Stable identifier for "the patches as they exist right now" for
# this Postgres branch — the git tree SHA of the per-branch
# subdirectory. Empty string if the subdirectory doesn't exist.
# Using the subdirectory tree SHA rather than the patches repo's
# commit SHA means that a change to another branch's subdirectory
# does not trigger a rebuild for this branch.
sub _patches_id
{
	my $self = shift;
	my $local = $self->{local_repo};
	my $sub = $self->{subdir};

	my $id = `git -C $local rev-parse --verify --quiet "HEAD:$sub" 2>$devnull`;
	chomp $id;
	return $id;
}

# Log the patch series we are about to import, one line per patch:
# the file name (as listed in series) followed by the subject. We
# derive the subject the same way quiltimport does for the commit it
# creates -- via "git mailinfo", which unwraps the header and strips
# any "[PATCH ...]" prefix -- falling back to the file name minus a
# trailing ".patch" when the patch carries no Subject: header.
#
# Returns the parsed list as an arrayref of { name => , subject => }
# hashrefs, so callers can reuse it (e.g. to write patch_stack.log)
# without re-deriving the subjects.
sub _log_series
{
	my $self = shift;
	my $log = shift;
	my $patchdir = shift;

	open(my $fh, '<', "$patchdir/series") or return [];
	my @patches;
	while (my $line = <$fh>)
	{
		chomp $line;

		# mirror quiltimport's parsing: skip blanks and comments, and
		# take the first whitespace-delimited token as the file name.
		next if $line =~ /^\s*(#|$)/;
		my ($name) = split(/\s+/, $line);
		push(@patches, $name) if defined $name && $name ne '';
	}
	close $fh;

	push(@$log, "$MODULE: series (" . scalar(@patches) . " patches):\n");
	my @parsed;
	foreach my $name (@patches)
	{
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
		push(@$log, "    $name: $subject\n");
		push(@parsed, { name => $name, subject => $subject });
	}
	return \@parsed;
}

# Return the git mode ('100644', '120000', ...) of a path in the
# patches repo at HEAD, or '' if it doesn't exist there.
sub _git_mode
{
	my $self = shift;
	my $path = shift;
	my $local = $self->{local_repo};

	my $line = `git -C $local ls-tree HEAD -- "$path" 2>$devnull`;
	chomp $line;
	return '' unless $line;
	my ($mode) = split(/\s+/, $line);
	return $mode // '';
}

# Return the raw content of the blob at the given path in the patches
# repo at HEAD.
sub _git_blob
{
	my $self = shift;
	my $path = shift;
	my $local = $self->{local_repo};

	return `git -C $local show "HEAD:$path" 2>$devnull`;
}

# Collapse "." and ".." segments in a git-style forward-slash path
# without touching the filesystem -- the target may not exist as a
# real file on this platform (e.g. behind an unmaterialized symlink).
sub _normalize_git_path
{
	my $path = shift;
	my @out;
	foreach my $part (split(m{/+}, $path))
	{
		next if $part eq '' || $part eq '.';
		if   ($part eq '..') { pop @out; }
		else                 { push @out, $part; }
	}
	return join('/', @out);
}

# Resolve a path in the patches repo to its real file content, following
# git symlinks (mode 120000) by hand via git's tree/blob data rather
# than the checked-out working tree. Patches repos may share an
# unmodified patch across branches via a symlink; Windows without
# core.symlinks enabled checks such a symlink out as a plain text file
# containing the link target, which is useless to quiltimport. Reading
# through git's plumbing instead sidesteps that platform limitation
# entirely, and works the same way regardless of how (or whether) the
# platform materializes real filesystem symlinks.
sub _resolve_patch_content
{
	my $self = shift;
	my $log = shift;
	my $path = shift;

	# A series entry may reference a patch in another branch's
	# subdirectory via a relative path (e.g. "../master/foo.patch")
	# rather than a symlink. "git ls-tree" resolves "." / ".." path
	# segments itself, but "git show HEAD:<path>" does not -- it
	# silently returns empty content for an unnormalized path instead
	# of erroring, which would otherwise materialize a blank, useless
	# patch file. Normalize up front so both plumbing calls agree on
	# the same path.
	$path = _normalize_git_path($path);

	for (1 .. 5)
	{
		my $mode = $self->_git_mode($path);
		return undef if $mode eq '';
		if ($mode eq '120000')
		{
			my $target = $self->_git_blob($path);
			$target =~ s/\s+$//;
			my ($dir) = $path =~ m{^(.*)/[^/]*$};
			$dir //= '';
			$path = _normalize_git_path("$dir/$target");
			next;
		}
		return $self->_git_blob($path);
	}
	push(@$log, "$MODULE: symlink chain too deep resolving $path\n");
	return undef;
}

# Materialize a plain-file copy of the patch series with any symlinks
# resolved to their real content (see _resolve_patch_content), so
# quiltimport and our own mailinfo parsing operate on real patch
# content regardless of the platform's symlink support.
sub _build_resolved_dir
{
	my $self = shift;
	my $log = shift;
	my $sub = $self->{subdir};

	my $dest = "$self->{local_repo}.resolved/$sub";
	rmtree($dest) if -d $dest;
	mkpath($dest);

	my $series_content = $self->_resolve_patch_content($log, "$sub/series");
	die "resolving $sub/series\n" unless defined $series_content;
	open(my $sfh, '>', "$dest/series") or die "writing $dest/series: $!\n";
	binmode $sfh;
	print $sfh $series_content;
	close $sfh;

	# Derive the patch list from the just-resolved series content, not
	# a fresh read of the checked-out series file: if the series file
	# itself is shared via symlink (as this module allows -- see the
	# module docs), the two can disagree on a platform without
	# filesystem symlink support, where the raw checkout is just a
	# text file holding the link target.
	my @names;
	foreach my $line (split /\n/, $series_content)
	{
		next if $line =~ /^\s*(#|$)/;
		my ($name) = split(/\s+/, $line);
		push(@names, $name) if defined $name && $name ne '';
	}

	foreach my $name (@names)
	{
		my $content = $self->_resolve_patch_content($log, "$sub/$name");
		unless (defined $content)
		{
			push(@$log, "$MODULE: could not resolve $sub/$name, skipping\n");
			next;
		}

		# $name may itself be a relative path out of this branch's
		# subdirectory (e.g. "../master/foo.patch", used to share a
		# patch unchanged across branches without a symlink), so its
		# parent directory may not be $dest itself and may not exist
		# yet.
		my $target_file = "$dest/$name";
		mkpath(dirname($target_file));
		open(my $pfh, '>', $target_file)
		  or die "writing $target_file: $!\n";
		binmode $pfh;
		print $pfh $content;
		close $pfh;
	}
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

	# Capture the upstream HEAD before importing so cleanup (and
	# error recovery below) can rewind past the commits quiltimport
	# is about to create.
	my $sha = `git -C $srcdir rev-parse --verify --quiet HEAD 2>$devnull`;
	chomp $sha;
	if ($? >> 8 || $sha eq '')
	{
		push(@$log, "$MODULE: cannot determine HEAD of $srcdir\n");
		$self->{series_status} = 'broken';
		return 0;
	}
	$self->{pre_apply_sha} = $sha;

	# quiltimport uses git-am internally; abort any interrupted state
	# left by a previous run before starting fresh. A rebase-apply
	# directory left behind by a run that failed before git-am finished
	# writing its full state (e.g. an empty-patch mailsplit error) can
	# be incomplete enough that "am --abort" itself silently fails to
	# remove it, so fall back to forcibly clearing it -- otherwise the
	# next quiltimport's internal git-am fails at mkdir because the
	# directory still exists.
	if (-d "$srcdir/.git/rebase-apply")
	{
		push(@$log, "$MODULE: aborting stale rebase-apply state\n");
		run_log("git -C $srcdir am --abort");
		if (-d "$srcdir/.git/rebase-apply")
		{
			push(@$log,
					"$MODULE: am --abort left rebase-apply state behind,"
				  . " removing it directly\n");
			rmtree("$srcdir/.git/rebase-apply");
		}
	}

	push(@$log, "$MODULE: importing patch series from $patchdir\n");

	my @out = run_log(qq{git -C $srcdir quiltimport --patches "$patchdir"});
	my $status = $? >> 8;
	push(@$log, "------ quiltimport (status=$status) ------\n", @out);

	if ($status)
	{
		# quiltimport leaves a partial commit history on failure;
		# rewind to a known state so a later cleanup or rerun starts
		# from the upstream tip rather than a half-applied series.
		run_log("git -C $srcdir reset --hard --quiet $sha");
		$self->{series_status} = 'broken';
		return 0;
	}

	$self->{applied} = 1;
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
sub _write_patch_stack_log
{
	my $self = shift;

	my @lines;
	push(@lines, "patch_stack_id: " . ($self->{patches_id} // '') . "\n");
	push(@lines,
		"patch_stack_source: $self->{patches_branch}:$self->{subdir}\n");
	push(@lines,
		"patch_stack_status: " . ($self->{series_status} // '') . "\n");
	foreach my $p (@{ $self->{series_patches} // [] })
	{
		push(@lines, "$p->{name}\t$p->{subject}\n");
	}
	writelog('patch_stack', \@lines);
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

	$self->{patches_id} = $self->_patches_id();
	push(@$savescmlog,
			"$MODULE: $self->{patches_branch}:$self->{subdir} = "
		  . ($self->{patches_id} || '(absent)')
		  . "\n");

	unless ($self->{patches_id})
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

	return unless $self->{applied};

	# When rm_worktrees is on the END block has already wiped the
	# worktree files; running git reset here would just resurrect them.
	# The imported commits left at HEAD are harmless: the next run's
	# SCM update (PGBuild::SCM::_update_target) restores the worktree
	# with "git checkout ." and then "git reset --hard origin/<branch>",
	# which discards them and returns the tree to pristine upstream
	# before any build happens.
	return if $self->{bfconf}->{rm_worktrees};

	my $srcdir = $self->{srcdir};
	return unless -d "$srcdir/.git";

	# Reset to the upstream tip captured before quiltimport so the
	# imported commits are discarded and the worktree is back to
	# pristine upstream state for the next run.
	my $target = $self->{pre_apply_sha} || 'HEAD';
	print time_str(), "$MODULE: resetting $srcdir to $target\n"
	  if $verbose > 1;
	run_log("git -C $srcdir reset --hard --quiet $target");
	return;
}

1;
