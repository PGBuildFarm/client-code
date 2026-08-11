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
sequential run.

With C<--sequential> the patches are instead applied cumulatively, in
series order, inside a throwaway C<git worktree> checked out from the
tree's HEAD (so the real source tree is never touched and the base is
pristine regardless of the working tree's state). That mode calls
C<PGBuild::PatchSeries::apply_series>, the same code the buildfarm
itself uses, so what it reports is what an animal will do rather than
an approximation of it. Application stops at the first patch that is
missing or fails to apply, and the remaining patches are reported as
skipped.

Note that C<--sequential> therefore does not fall back from C<-p1> to
C<-p0> the way the default mode does: C<apply_series> applies at the
strip level the C<series> line gives and does not guess. The default
mode keeps the fallback, since it is checking each patch in isolation
rather than predicting a real run.

A series entry may reference a patch shared unchanged with another
branch's subdirectory rather than a copy, by giving a relative path --
commonly C<../master/foo.patch>. Symlinks are also resolved, but are no
longer used in practice and are supported only so existing stacks do
not regress. Both are resolved via git plumbing against the patch-stack
repo's C<HEAD> rather than the checked-out working tree, mirroring
C<PGBuild::Modules::PatchStack> -- so this script sees exactly what a
buildfarm animal would apply, including on platforms where a
checked-out symlink is just a text file holding its target path. For
this reason C<< <patch_stack_repo> >> must itself be a git repository
(a plain directory of files is not enough).

=head1 USAGE

    check_patch_stack.pl [options] <patch_stack_repo> [<buildroot>]

Options:

    --branch NAME      only test this series subdirectory (repeatable)
    --map SUB=BRANCH   map series subdir SUB to buildroot branch BRANCH
                       (repeatable; 'master' defaults to 'HEAD')
    --strip N          default strip level when a series line gives none
                       (default 1)
    --sequential       apply patches cumulatively in series order (in a
                       scratch worktree), stopping at the first failure
    --manifest         check that every series entry resolves to a patch
                       that is present, printing what each resolves to;
                       reads only the patches repo, so <buildroot> is not
                       required. Exit 1 if any entry is missing
    --verbose          show git apply diagnostics for failing patches
    --help             this message

Exit status is 0 when every tested patch applies cleanly, 1 when any
patch fails or is missing, 2 on a usage/setup error.

=cut

use strict;
use warnings;

use Getopt::Long;
use File::Temp qw(tempdir);
use Cwd        qw(abs_path);

use FindBin;
use lib $FindBin::RealBin;
use PGBuild::PatchSeries qw(series_manifest materialize_series apply_series);
use PGBuild::Utils       qw($devnull);

my @only_branches;
my @map_args;
my $default_strip = 1;
my $sequential = 0;
my $verbose = 0;
my $manifest_only = 0;
my $help = 0;

GetOptions(
	'branch=s' => \@only_branches,
	'map=s' => \@map_args,
	'strip=i' => \$default_strip,
	'sequential' => \$sequential,
	'verbose' => \$verbose,
	'manifest' => \$manifest_only,
	'help' => \$help,
) or usage(2);

usage(0) if $help;

my ($repo, $buildroot) = @ARGV;

# --manifest reads only the patches repo, so a buildroot is not needed.
usage(2) unless defined $repo;
usage(2) unless defined $buildroot || $manifest_only;

$repo = abs_path($repo) // fail("no such patch-stack repo: $ARGV[0]\n");
fail("patch-stack repo is not a directory: $repo\n") unless -d $repo;

if (defined $buildroot)
{
	$buildroot = abs_path($buildroot) // fail("no such buildroot: $ARGV[1]\n");
	fail("buildroot is not a directory: $buildroot\n") unless -d $buildroot;
}

# Symlinked/shared-path patches are resolved via git plumbing against
# HEAD (see PGBuild::PatchSeries::resolve_patch_path), so the repo must
# actually be a git checkout -- a plain directory of files isn't
# enough.
system(qq{git -C "$repo" rev-parse --git-dir >$devnull 2>&1}) == 0
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

if ($manifest_only)
{
	my $bad = 0;
	foreach my $sub (@subdirs)
	{
		next if %only && !$only{$sub};

		print "=== series: $sub ===\n";
		my $manifest = series_manifest($repo, $sub);
		unless ($manifest)
		{
			print "  BROKEN: cannot resolve $sub/series\n\n";
			$bad = 1;
			next;
		}

		printf "  %-28s %s\n", 'series', substr($manifest->{series_sha}, 0, 7);
		foreach my $e (@{ $manifest->{entries} })
		{
			if ($e->{missing})
			{
				printf "  %-28s %s\n", $e->{name}, '(missing)';
				$bad = 1;
				next;
			}

			# Show where an entry resolved only when that differs from
			# the entry itself, so shared patches stand out.
			my $where =
			  ($e->{path} eq "$sub/$e->{name}") ? '' : "  -> $e->{path}";
			printf "  %-28s %s%s\n", $e->{name}, substr($e->{sha}, 0, 7),
			  $where;
		}
		print "  patch_stack_id: $manifest->{id}\n\n";
	}
	exit($bad ? 1 : 0);
}

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
		my $dirty = `git -C "$tree" status --porcelain 2>$devnull`;
		print "  WARNING: source tree has uncommitted changes\n"
		  if defined $dirty && $dirty ne '';
	}

	$tot_series++;

	my ($resolved_dir, $patches, $manifest) =
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
	  ? test_sequential($tree, $resolved_dir, \@patches, $manifest)
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

# Materialize a plain-file copy of a series subdirectory's series file
# and the patches it lists, with any symlinks resolved to their real
# content (see PGBuild::PatchSeries::series_manifest), so the same
# checks run below operate on real patch content regardless of the
# platform's symlink support -- exactly what PatchStack.pm will
# actually apply. Dies if the series file itself can't be resolved; a
# patch entry that can't be resolved is left out of $dest so the
# caller's normal "file not found" [MISS] handling reports it, which
# is also what apply_series does with a missing entry: stop and say so,
# rather than silently substituting something else or skipping past it.
# Returns (resolved_dir, \@patches, $manifest).
sub build_resolved_dir
{
	my ($stack_repo, $sub, $dest_root) = @_;
	my $dest = "$dest_root/$sub";

	my $manifest = series_manifest($stack_repo, $sub);
	die "cannot resolve $sub/series\n" unless $manifest;

	# Unresolvable entries are simply left out of $dest; the caller's
	# existing "file not found" handling reports them as [MISS].
	materialize_series($stack_repo, $manifest, $dest);
	return ($dest, $manifest->{entries}, $manifest);
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

# --sequential: apply the series cumulatively into a throwaway worktree,
# using the same apply_series() the buildfarm uses, so what this
# validates is exactly what an animal will do. Returns
# (clean, failed, missing).
#
# Unlike test_independent this does NOT fall back from -p1 to -p0:
# apply_series deliberately does not guess strip levels, and the point
# of this mode is to match the farm rather than to be forgiving.
sub test_sequential
{
	my ($tree, $dir, $patches, $manifest) = @_;

	my $scratch = tempdir("patchstack.XXXXXX", TMPDIR => 1, CLEANUP => 1);
	my $wt = "$scratch/wt";
	my @out = `git -C "$tree" worktree add --detach -q "$wt" HEAD 2>&1`;
	if (($? >> 8) != 0)
	{
		print "  SKIP: cannot create scratch worktree from HEAD\n";
		print_diag(join('', @out)) if $verbose;
		return (0, 0, 0);
	}

	my $logdir = "$scratch/log";
	my $result = apply_series($manifest, $dir, $wt, $logdir);

	my ($clean, $fail, $miss) = (0, 0, 0);
	my %done;
	foreach my $a (@{ $result->{applied} })
	{
		$done{ $a->{name} } = 1;
		$clean++;
		printf "  %-7s %s\n", '[ ok ]', $a->{name};
		print_diag($a->{output})
		  if $verbose && defined $a->{output} && $a->{output} ne '';
	}

	if (!$result->{ok})
	{
		my $f = $result->{failure};
		$done{ $f->{name} } = 1;
		if ($f->{reason} eq 'missing')
		{
			printf "  %-7s %s\n", '[MISS]', "$f->{name} (file not found)";
			$miss++;
		}
		else
		{
			printf "  %-7s %s\n", '[FAIL]', $f->{name};
			$fail++;
			print_diag($f->{detail});
		}
	}

	foreach my $p (@$patches)
	{
		next if $done{ $p->{name} };
		printf "  %-7s %s\n", '[SKIP]', "$p->{name} (earlier patch failed)";
	}

	# Remove the worktree registration; CLEANUP unlinks the files.
	system(qq{git -C "$tree" worktree remove --force "$wt" >$devnull 2>&1});
	system(qq{git -C "$tree" worktree prune >$devnull 2>&1});

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
		my $err = `git -C "$tree" apply --check -p$lvl -- "$file" 2>&1`;
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
Usage: check_patch_stack.pl [options] <patch_stack_repo> [<buildroot>]

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
  --manifest         print each series' resolved blob SHAs and the
                     identity the buildfarm uses to detect changes,
                     then exit; <buildroot> is not required
  --verbose          show git apply diagnostics for failing patches
  --help             this message

Exit: 0 = all clean, 1 = some patch failed/missing, 2 = usage error.
EOT
	exit $code;
}
