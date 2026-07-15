#!/usr/bin/perl

=pod

Copyright (c) 2003-2026, Andrew Dunstan

See accompanying License file for license details

=head1 check_patch_stack.pl

Given a "quilt-style" patch-stack repository (as consumed by
C<PGBuild::Modules::PatchStack>) and a buildfarm buildroot, discover
which patches in which series apply cleanly to the matching
PostgreSQL source tree.

The patch-stack repo is expected to hold one subdirectory per series,
each containing a C<series> file (quilt convention: one patch file per
line, blank lines and C<#> comments ignored, an optional C<-pN> token
selects the strip level for that patch) plus the patch files it lists.
Each series subdirectory is matched to a buildfarm branch and tested
against C<< <buildroot>/<branch>/pgsql >>.

By default each patch is dry-run independently with C<git apply
--check> against the pristine base tree (the tree is never modified).
Because every patch is checked against the unpatched base, a patch
that only applies on top of an earlier patch in the series will be
reported as failing here even though it would apply in a real
sequential C<quiltimport>.

With C<--sequential> the patches are instead applied cumulatively, in
series order, inside a throwaway C<git worktree> checked out from the
tree's HEAD (so the real source tree is never touched and the base is
pristine regardless of the working tree's state). Application stops at
the first patch that fails to apply -- mirroring C<quiltimport>, which
also halts on the first bad patch -- and the remaining patches are
reported as skipped.

A series entry may reference a patch shared unchanged with another
branch's subdirectory rather than a copy: either as a relative path
(commonly C<../master/foo.patch>) or as a symlink. Both are resolved
via C<git ls-tree>/C<git show> against the patch-stack repo's C<HEAD>
rather than the checked-out working tree, mirroring how
C<PGBuild::Modules::PatchStack> resolves them -- so this script sees
exactly what a buildfarm animal would apply, including on platforms
where a checked-out symlink is just a text file holding its target
path. For this reason C<< <patch_stack_repo> >> must itself be a git
repository (a plain directory of files is not enough).

=head1 USAGE

    check_patch_stack.pl [options] <patch_stack_repo> <buildroot>

Options:

    --branch NAME      only test this series subdirectory (repeatable)
    --map SUB=BRANCH   map series subdir SUB to buildroot branch BRANCH
                       (repeatable; 'master' defaults to 'HEAD')
    --strip N          default strip level when a series line gives none
                       (default 1)
    --sequential       apply patches cumulatively in series order (in a
                       scratch worktree), stopping at the first failure
    --verbose          show git apply diagnostics for failing patches
    --help             this message

Exit status is 0 when every tested patch applies cleanly, 1 when any
patch fails or is missing, 2 on a usage/setup error.

=cut

use strict;
use warnings;

use Getopt::Long;
use File::Spec;
use File::Temp     qw(tempdir);
use File::Path     qw(mkpath);
use File::Basename qw(dirname);
use Cwd            qw(abs_path);

# Platform-correct null device (e.g. 'nul' on Windows), matching how
# PGBuild::Utils derives $devnull -- hardcoding '/dev/null' would defeat
# the point of resolving patches via git plumbing for Windows support.
my $devnull = File::Spec->devnull;

my @only_branches;
my @map_args;
my $default_strip = 1;
my $sequential = 0;
my $verbose = 0;
my $help = 0;

GetOptions(
	'branch=s' => \@only_branches,
	'map=s' => \@map_args,
	'strip=i' => \$default_strip,
	'sequential' => \$sequential,
	'verbose' => \$verbose,
	'help' => \$help,
) or usage(2);

usage(0) if $help;

my ($repo, $buildroot) = @ARGV;
usage(2) unless defined $repo && defined $buildroot;

$repo = abs_path($repo) // fail("no such patch-stack repo: $ARGV[0]\n");
$buildroot = abs_path($buildroot) // fail("no such buildroot: $ARGV[1]\n");

fail("patch-stack repo is not a directory: $repo\n") unless -d $repo;
fail("buildroot is not a directory: $buildroot\n") unless -d $buildroot;

# Symlinked/shared-path patches are resolved via git plumbing against
# HEAD (see resolve_patch_content), so the repo must actually be a git
# checkout -- a plain directory of files isn't enough.
system("git -C '$repo' rev-parse --git-dir >$devnull 2>&1") == 0
  or fail("patch-stack repo is not a git repository: $repo\n");

# subdir -> branch overrides. 'master' maps to HEAD by default, mirroring
# the common PatchStack subdir map (HEAD => 'master'); --map can override.
my %subdir_to_branch = (master => 'HEAD');
foreach my $m (@map_args)
{
	my ($sub, $br) = split(/=/, $m, 2);
	fail("bad --map value '$m' (expected SUB=BRANCH)\n")
	  unless defined $sub && defined $br && $sub ne '' && $br ne '';
	$subdir_to_branch{$sub} = $br;
}

my %only = map { $_ => 1 } @only_branches;

# Discover series: immediate subdirectories of the repo holding a
# 'series' file (the documented per-branch layout).
opendir(my $dh, $repo) or fail("cannot read $repo: $!\n");
my @subdirs =
  sort grep { -d "$repo/$_" && -f "$repo/$_/series" }
  grep { $_ ne '.' && $_ ne '..' } readdir($dh);
closedir $dh;

fail("no series subdirectories found under $repo\n") unless @subdirs;

# Shared destination for resolved (symlink-free) copies of each series
# tested below, so relative-path series entries that point at another
# subdirectory (e.g. "../master/foo.patch") resolve to a sibling
# directory here, the same way they resolve to a sibling of
# local_repo.resolved/<subdir> in PatchStack.pm.
my $resolved_root =
  tempdir("patchstack-check.XXXXXX", TMPDIR => 1, CLEANUP => 1);

my $exit = 0;
my ($tot_clean, $tot_fail, $tot_miss, $tot_series) = (0, 0, 0, 0);

foreach my $sub (@subdirs)
{
	next if %only && !$only{$sub};

	my $branch = $subdir_to_branch{$sub} // $sub;
	my $tree = "$buildroot/$branch/pgsql";

	# Fall back to the subdir name as a branch if the mapped branch has
	# no tree but the literal subdir does.
	if (!-d "$tree/.git" && $branch ne $sub && -d "$buildroot/$sub/pgsql/.git")
	{
		$branch = $sub;
		$tree = "$buildroot/$branch/pgsql";
	}

	print "=== series: $sub  (branch $branch) ===\n";

	unless (-d "$tree/.git")
	{
		print "  SKIP: no source tree at $tree\n\n";
		next;
	}

	# In independent mode a dirty tree means we are not checking against
	# pristine upstream; warn but proceed. Sequential mode is immune --
	# it builds a fresh worktree from HEAD -- so the warning is skipped.
	unless ($sequential)
	{
		my $dirty = `git -C '$tree' status --porcelain 2>$devnull`;
		print "  WARNING: source tree has uncommitted changes\n"
		  if defined $dirty && $dirty ne '';
	}

	$tot_series++;

	my ($resolved_dir, $patches) =
	  eval { build_resolved_dir($repo, $sub, $resolved_root) };
	if ($@)
	{
		print "  BROKEN: $@";
		$exit = 1;
		next;
	}
	my @patches = @$patches;

	my ($clean, $fail, $miss) =
	  $sequential
	  ? test_sequential($tree, $resolved_dir, \@patches)
	  : test_independent($tree, $resolved_dir, \@patches);

	printf "  %d patches: %d clean, %d failed, %d missing\n\n",
	  scalar(@patches), $clean, $fail, $miss;

	$tot_clean += $clean;
	$tot_fail  += $fail;
	$tot_miss  += $miss;
	$exit = 1 if $fail || $miss;
}

printf "TOTAL across %d series: %d clean, %d failed, %d missing\n",
  $tot_series, $tot_clean, $tot_fail, $tot_miss;

exit $exit;

#---------------------------------------------------------------------

# Return the git mode ('100644', '120000', ...) of a path in the
# patch-stack repo at HEAD, or '' if it doesn't exist there.
sub git_mode
{
	my ($repo, $path) = @_;

	my $line = `git -C '$repo' ls-tree HEAD -- '$path' 2>$devnull`;
	chomp $line;
	return '' unless $line;
	my ($mode) = split(/\s+/, $line);
	return $mode // '';
}

# Return the raw content of the blob at the given path in the
# patch-stack repo at HEAD.
sub git_blob
{
	my ($repo, $path) = @_;

	return `git -C '$repo' show 'HEAD:$path' 2>$devnull`;
}

# Collapse "." and ".." segments in a git-style forward-slash path
# without touching the filesystem -- the target may not exist as a
# real file on this platform (e.g. behind an unmaterialized symlink).
sub normalize_git_path
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

# Resolve a path in the patch-stack repo to its real file content,
# following git symlinks (mode 120000) by hand via git's tree/blob
# data rather than the checked-out working tree. Mirrors
# PGBuild::Modules::PatchStack::_resolve_patch_content: a patches repo
# may share an unmodified patch across branches via a symlink, and on
# platforms without filesystem symlink support (e.g. Windows without
# core.symlinks) a checked-out symlink is just a text file containing
# the link target, which git apply cannot use as patch content. Reading
# through git's plumbing instead works the same way regardless of how
# (or whether) the platform materializes real filesystem symlinks.
sub resolve_patch_content
{
	my ($repo, $path) = @_;

	$path = normalize_git_path($path);

	for (1 .. 5)
	{
		my $mode = git_mode($repo, $path);
		return undef if $mode eq '';
		if ($mode eq '120000')
		{
			my $target = git_blob($repo, $path);
			$target =~ s/\s+$//;
			(my $dir = $path) =~ s{/[^/]*$}{};
			$path = normalize_git_path("$dir/$target");
			next;
		}
		return git_blob($repo, $path);
	}
	return undef;    # symlink chain too deep
}

# Materialize a plain-file copy of a series subdirectory's series file
# and the patches it lists, with any symlinks resolved to their real
# content (see resolve_patch_content), so the same checks run below
# operate on real patch content regardless of the platform's symlink
# support -- exactly what PatchStack.pm's quiltimport will actually
# see. Dies if the series file itself can't be resolved; a patch entry
# that can't be resolved is left out of $dest so the caller's normal
# "file not found" [MISS] handling reports it, mirroring how a broken
# patch stack fails quiltimport rather than silently substituting
# something else. Returns (resolved_dir, \@patches).
sub build_resolved_dir
{
	my ($repo, $sub, $resolved_root) = @_;
	my $dest = "$resolved_root/$sub";
	mkpath($dest) unless -d $dest;

	my $series_content = resolve_patch_content($repo, "$sub/series");
	die "cannot resolve $sub/series\n" unless defined $series_content;

	open(my $sfh, '>', "$dest/series") or die "writing $dest/series: $!\n";
	binmode $sfh;
	print $sfh $series_content;
	close $sfh;

	my @patches = parse_series("$dest/series");

	foreach my $p (@patches)
	{
		my $name = $p->{name};
		my $content = resolve_patch_content($repo, "$sub/$name");
		next unless defined $content;

		# $name may itself be a relative path out of this subdirectory
		# (e.g. "../master/foo.patch", used to share a patch unchanged
		# across branches without a symlink), so its parent directory
		# may not be $dest itself and may not exist yet.
		my $target_file = "$dest/$name";
		mkpath(dirname($target_file));
		open(my $pfh, '>', $target_file)
		  or die "writing $target_file: $!\n";
		binmode $pfh;
		print $pfh $content;
		close $pfh;
	}
	return ($dest, \@patches);
}

# Default mode: dry-run each patch independently against the pristine
# tree with git apply --check. Returns (clean, failed, missing).
sub test_independent
{
	my ($tree, $dir, $patches) = @_;
	my ($clean, $fail, $miss) = (0, 0, 0);

	foreach my $p (@$patches)
	{
		my $name = $p->{name};
		my $strip = defined $p->{strip} ? $p->{strip} : $default_strip;
		my $file = "$dir/$name";

		unless (-f $file)
		{
			printf "  %-7s %s\n", '[MISS]', "$name (file not found)";
			$miss++;
			next;
		}

		my ($ok, $used_strip, $err) = check_apply($tree, $file, $strip);
		if ($ok)
		{
			my $note = $used_strip == $strip ? '' : " (-p$used_strip)";
			printf "  %-7s %s%s\n", '[ ok ]', $name, $note;
			$clean++;
		}
		else
		{
			printf "  %-7s %s\n", '[FAIL]', $name;
			$fail++;
			print_diag($err);
		}
	}
	return ($clean, $fail, $miss);
}

# --sequential mode: apply the patches cumulatively, in order, inside a
# throwaway worktree checked out from the tree's HEAD. Stops at the
# first failure (or missing file), the way quiltimport does, and marks
# the rest skipped. Returns (clean, failed, missing); a stop counts the
# offending patch as failed/missing and the rest as neither.
sub test_sequential
{
	my ($tree, $dir, $patches) = @_;
	my ($clean, $fail, $miss) = (0, 0, 0);

	my $scratch = tempdir("patchstack.XXXXXX", TMPDIR => 1, CLEANUP => 1);
	my $wt = "$scratch/wt";
	my @out = `git -C '$tree' worktree add --detach -q '$wt' HEAD 2>&1`;
	if (($? >> 8) != 0)
	{
		print "  SKIP: cannot create scratch worktree from HEAD\n";
		print_diag(join('', @out)) if $verbose;
		return (0, 0, 0);
	}

	my $stopped = 0;
	foreach my $p (@$patches)
	{
		my $name = $p->{name};

		if ($stopped)
		{
			printf "  %-7s %s\n", '[SKIP]', "$name (earlier patch failed)";
			next;
		}

		my $strip = defined $p->{strip} ? $p->{strip} : $default_strip;
		my $file = "$dir/$name";

		unless (-f $file)
		{
			printf "  %-7s %s\n", '[MISS]', "$name (file not found)";
			$miss++;
			$stopped = 1;
			next;
		}

		# pick the working strip level without mutating the tree, then
		# apply for real at that level so later patches build on it.
		my ($ok, $used_strip, $err) = check_apply($wt, $file, $strip);
		unless ($ok)
		{
			printf "  %-7s %s\n", '[FAIL]', $name;
			$fail++;
			$stopped = 1;
			print_diag($err);
			next;
		}

		my $aerr = `git -C '$wt' apply -p$used_strip -- '$file' 2>&1`;
		if (($? >> 8) != 0)
		{
			printf "  %-7s %s\n", '[FAIL]', "$name (apply failed)";
			$fail++;
			$stopped = 1;
			print_diag($aerr);
			next;
		}

		my $note = $used_strip == $strip ? '' : " (-p$used_strip)";
		printf "  %-7s %s%s\n", '[ ok ]', $name, $note;
		$clean++;
	}

	# Remove the worktree registration; CLEANUP unlinks the files.
	system("git -C '$tree' worktree remove --force '$wt' " . ">$devnull 2>&1");
	system("git -C '$tree' worktree prune >$devnull 2>&1");

	return ($clean, $fail, $miss);
}

sub print_diag
{
	my $err = shift;
	return unless $verbose && defined $err && $err ne '';
	$err =~ s/^/        /mg;
	print $err;
	print "\n" unless $err =~ /\n$/;
	return;
}

sub parse_series
{
	my $path = shift;
	open(my $fh, '<', $path) or die "cannot read $path: $!\n";
	my @out;
	while (my $line = <$fh>)
	{
		chomp $line;
		$line =~ s/^\s+//;

		# quilt convention: skip blanks and comments
		next if $line =~ /^(#|$)/;
		my @tok = split(/\s+/, $line);
		my $name = shift @tok;
		next unless defined $name && $name ne '';

		# an optional -pN token sets this patch's strip level
		my $strip;
		foreach my $t (@tok)
		{
			$strip = $1 if $t =~ /^-p(\d+)$/;
		}
		push(@out, { name => $name, strip => $strip });
	}
	close $fh;
	return @out;
}

# Try git apply --check at the requested strip level. If the series
# line gave no explicit level and -p1 fails, also try -p0, since plain
# quilt diffs are sometimes generated without a/ b/ prefixes.
sub check_apply
{
	my ($tree, $file, $strip) = @_;

	my @levels = ($strip);
	push(@levels, 0) if $strip == 1;    # only auto-fallback for the default

	my $last_err = '';
	foreach my $lvl (@levels)
	{
		my $err = `git -C '$tree' apply --check -p$lvl -- '$file' 2>&1`;
		return (1, $lvl, '') if ($? >> 8) == 0;
		$last_err = $err;
	}
	return (0, $strip, $last_err);
}

# Report a setup/usage error and exit 2, per the documented contract.
# A plain "die" won't do -- its exit status is $! or $? if either is
# nonzero at the time (e.g. inherited from a just-run git/system call,
# as happens for the git-repository check above) and 255 otherwise,
# neither of which is the documented code.
sub fail
{
	print STDERR @_;
	exit 2;
}

sub usage
{
	my $code = shift // 0;
	my $fh = $code ? \*STDERR : \*STDOUT;
	print $fh <<'EOT';
Usage: check_patch_stack.pl [options] <patch_stack_repo> <buildroot>

  Report which patches in which series apply cleanly to the matching
  <buildroot>/<branch>/pgsql source tree. Each patch is dry-run
  independently with `git apply --check`; the source tree is never
  modified.

Options:
  --branch NAME      only test this series subdirectory (repeatable)
  --map SUB=BRANCH   map series subdir SUB to buildroot branch BRANCH
                     (repeatable; 'master' defaults to 'HEAD')
  --strip N          default strip level when a series line gives none
                     (default 1)
  --sequential       apply patches cumulatively in series order (in a
                     scratch worktree), stopping at the first failure
  --verbose          show git apply diagnostics for failing patches
  --help             this message

Exit: 0 = all clean, 1 = some patch failed/missing, 2 = usage error.
EOT
	exit $code;
}
