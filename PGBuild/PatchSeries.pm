
=pod

Copyright (c) 2003-2026, Andrew Dunstan

See accompanying License file for license details

=head1 PGBuild::PatchSeries

Shared reading of a "quilt-style" patch-stack repository: resolving a
C<series> entry to the patch content it actually names, parsing the
C<series> file, and computing a stable identity for a branch's series.

Used by both C<PGBuild::Modules::PatchStack> (which applies the series)
and C<check_patch_stack.pl> (which checks that it applies). Those two
previously carried separate copies of this logic and drifted apart.

A C<series> entry may name a patch in another branch's subdirectory by
relative path, commonly C<../master/foo.patch>, so that a patch shared
unchanged across branches is stored once. Symlinks are also resolved,
but are no longer used in practice; the support is retained so existing
stacks do not regress.

Resolution goes through git's tree and blob data rather than the
checked-out working tree. That is what makes it work on platforms where
a checked-out symlink is a plain text file holding its target path, and
it is also why paths are normalized first: C<git show HEAD:a/../b>
silently returns empty content rather than erroring.

=cut

package PGBuild::PatchSeries;

use strict;
use warnings;

use Digest::SHA    qw(sha1_hex);
use File::Path     qw(mkpath);
use File::Basename qw(dirname);

use PGBuild::Utils qw($devnull run_log);

our ($VERSION); $VERSION = 'REL_21';

use Exporter qw(import);
our (@EXPORT_OK);
@EXPORT_OK = qw(normalize_git_path git_entry git_blob resolve_patch_path
  parse_series series_manifest materialize_series apply_series);

# Collapse "." and ".." segments in a git-style forward-slash path
# without touching the filesystem -- the target may not exist as a real
# file on this platform.
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

# Return (mode, sha) for a path in the patches repo at HEAD, or ('','')
# if it is not there. "git ls-tree" prints "<mode> <type> <sha>\t<path>";
# the blob SHA is what identifies the patch content, and is what the
# callers below hash and report.
sub git_entry
{
	my ($repo, $path) = @_;

	my $line = `git -C "$repo" ls-tree HEAD -- "$path" 2>$devnull`;
	chomp $line;
	return ('', '') unless $line;
	my ($mode, $type, $sha) = split(/\s+/, $line);
	return (defined $mode ? $mode : '', defined $sha ? $sha : '');
}

# Raw content of the blob at a path in the patches repo at HEAD.
sub git_blob
{
	my ($repo, $path) = @_;

	return `git -C "$repo" show "HEAD:$path" 2>$devnull`;
}

# Resolve a path to the blob it actually names, following symlink
# entries (mode 120000) by hand. Returns ($final_path, $sha), or an
# empty list if the path does not resolve.
sub resolve_patch_path
{
	my ($repo, $path) = @_;

	$path = normalize_git_path($path);

	foreach my $hop (1 .. 5)
	{
		my ($mode, $sha) = git_entry($repo, $path);
		return () if $mode eq '';
		if ($mode eq '120000')
		{
			my $target = git_blob($repo, $path);
			$target =~ s/\s+$//;
			my ($dir) = $path =~ m{^(.*)/[^/]*$};
			$dir = defined $dir ? $dir : '';
			$path = normalize_git_path("$dir/$target");
			next;
		}
		return ($path, $sha);
	}

	# symlink chain too deep
	return ();
}

# Parse series file content (a string, not a filename) per the quilt
# convention: one patch per line, blank lines and "#" comments skipped,
# an optional -pN token giving that patch's strip level.
#
# Leading and trailing whitespace is stripped before splitting. Without
# the leading strip, split(/\s+/, "  0001.patch") yields an empty first
# field and the entry is silently dropped; the trailing strip keeps a
# CRLF series file from producing names with a stray carriage return.
sub parse_series
{
	my $content = shift;

	my @out;
	return @out unless defined $content;

	foreach my $line (split(/\n/, $content))
	{
		$line =~ s/^\s+//;
		$line =~ s/\s+$//;
		next if $line =~ /^(#|$)/;

		my @tok = split(/\s+/, $line);
		my $name = shift @tok;
		next unless defined $name && $name ne '';

		my $strip;
		foreach my $t (@tok)
		{
			$strip = $1 if $t =~ /^-p(\d+)$/;
		}
		push(@out, { name => $name, strip => $strip });
	}
	return @out;
}

# Build the manifest for one branch's subdirectory: what every entry in
# the series resolves to, in series order, plus a digest over the lot.
# Returns undef when the subdirectory has no resolvable series file.
#
# The digest is what the buildfarm compares to decide whether a branch's
# stack has changed. It is computed from resolved blob SHAs rather than
# from the subdirectory's tree SHA, so that a patch shared from another
# branch by a "../master/foo.patch" entry triggers this branch when its
# content changes. A subdirectory tree SHA does not move in that case,
# because the series blob still holds the same text -- which is why such
# branches were not being rebuilt.
#
# Only patches this branch actually names contribute, so an unrelated
# change elsewhere in the patches repo does not cause a build here.
sub series_manifest
{
	my ($repo, $subdir) = @_;

	my ($series_path, $series_sha) =
	  resolve_patch_path($repo, "$subdir/series");
	return unless defined $series_path;

	my @entries;
	my $blob = git_blob($repo, $series_path);
	my @parsed = parse_series($blob);

	foreach my $e (@parsed)
	{
		my ($path, $sha) = resolve_patch_path($repo, "$subdir/$e->{name}");

		# An entry is shared when it resolves outside this branch's own
		# subdirectory -- a "../master/foo.patch" reference, or a symlink
		# leading there. apply_series() allows such a patch more slack
		# when matching context, since it was written against a different
		# branch; a patch stored here was written for here and should
		# apply exactly.
		my $shared =
		  (defined $path && $path ne "$subdir/$e->{name}") ? 1 : 0;

		push(
			@entries,
			{
				name => $e->{name},
				strip => $e->{strip},
				path => $path,
				sha => $sha,
				shared => $shared,
				missing => (defined $path ? 0 : 1),
			}
		);
	}

	# Canonical text behind the digest. Series order is preserved, so a
	# reordering registers as a change. An entry that does not resolve
	# contributes the literal "missing" rather than an empty field, so
	# the digest moves again once the patch appears.
	my $canon = "series\t$series_sha\n";
	foreach my $e (@entries)
	{
		$canon .=
		  "$e->{name}\t" . ($e->{missing} ? 'missing' : $e->{sha}) . "\n";
	}

	return {
		series_path => $series_path,
		series_sha => $series_sha,
		entries => \@entries,
		id => sha1_hex($canon),
	};
}

# Materialize a plain-file copy of a resolved series into $dest: the
# series file itself plus every entry the manifest resolved, with any
# symlinks already followed by series_manifest(). $dest is created if it
# does not exist, but is not cleared first -- callers that need a clean
# destination (e.g. because a previous run left stale files behind) are
# responsible for that themselves.
#
# The series file is written from $manifest->{series_path}, not from a
# path built out of $subdir, because the series file itself may be
# shared and its literal path a symlink whose blob is just the target
# name.
#
# An entry marked missing is skipped rather than written, and its name
# is collected into the returned arrayref. Reporting is left to the
# caller: this module is shared between the buildfarm client and a
# command-line tool, which prefix and route their output differently,
# so it returns what happened rather than deciding where it goes.
#
# A present entry's name may itself be a relative path out of the
# destination (a shared "../master/foo.patch" style reference), so its
# parent directory may not exist yet.
sub materialize_series
{
	my ($repo, $manifest, $dest) = @_;

	mkpath($dest);

	open(my $sfh, '>', "$dest/series") or die "writing $dest/series: $!\n";
	binmode $sfh;
	print $sfh git_blob($repo, $manifest->{series_path});
	close $sfh;

	my @skipped;
	foreach my $e (@{ $manifest->{entries} })
	{
		if ($e->{missing})
		{
			push(@skipped, $e->{name});
			next;
		}

		my $target_file = "$dest/$e->{name}";
		mkpath(dirname($target_file));
		open(my $pfh, '>', $target_file) or die "writing $target_file: $!\n";
		binmode $pfh;
		print $pfh git_blob($repo, $e->{path});
		close $pfh;
	}
	return \@skipped;
}

# Apply a materialized series to a source tree, in series order,
# stopping at the first entry that is missing or fails to apply.
#
# This replaces "git quiltimport", which had three defects. It skipped
# an entry whose file was absent and still exited 0, so a stack could
# silently omit a patch while the farm reported green. It created a
# commit per patch that nothing consumed -- PGBuild::SCM::log_id writes
# a headref captured at checkout, never a fresh rev-parse. And it used
# $GIT_DIR/rebase-apply as its own scratch directory without removing
# it on the failure path, leaving a repository git reported as
# mid-rebase which could be neither continued nor aborted.
#
# Patches are applied with "git apply --index", plus a context setting
# that depends on where the patch came from:
#
#   --index  so a file added by a patch is staged, and "reset --hard"
#            therefore removes it. Without it the file is untracked and
#            survives into later runs.
#   -C3      for a patch stored in this branch's own subdirectory. It
#            was written for this branch, so it should apply exactly;
#            if it no longer does, upstream has moved beneath the stack
#            and that is worth reporting rather than absorbing.
#   -C1      for an entry resolving into another branch's subdirectory,
#            a "../master/foo.patch" reference. That patch was written
#            against a different branch, so some drift in the code
#            around it is expected, and it gets the tolerance
#            quiltimport applied to everything.
#
# Note -C is a floor, not a setting: git tries the full context first
# and reduces only as far as it must, so a patch whose context matches
# in full is applied in full under either value.
#
# No commits are created and HEAD never moves, so no rebase state is
# written under $GIT_DIR and the corruption above cannot recur.
#
# Commands run through run_log, which merges stdout and stderr; the
# combined text is returned per entry rather than logged here, because
# this module is shared between the buildfarm client and a command-line
# tool that route output differently. $logdir is passed through to
# run_log and may be undef on the farm.
sub apply_series
{
	my ($manifest, $patchdir, $srcdir, $logdir) = @_;

	my @applied;

	foreach my $e (@{ $manifest->{entries} })
	{
		my $file = "$patchdir/$e->{name}";

		if ($e->{missing} || !-f $file)
		{
			return {
				ok => 0,
				applied => \@applied,
				failure => {
					name => $e->{name},
					reason => 'missing',
					detail => "no patch file for this series entry\n",
				},
			};
		}

		# Mirror quiltimport: pass -pN only when the series line gave
		# one. Deliberately no -p1 -> -p0 fallback; guessing a strip
		# level during a real apply is what this change exists to stop.
		my $strip = defined $e->{strip} ? "-p$e->{strip} " : '';

		# Context tolerance depends on where the patch came from. A
		# patch stored in this branch's own subdirectory was written for
		# this branch and should apply exactly; if it no longer does,
		# upstream has moved under it and the stack wants rebasing,
		# which is worth being told about rather than papering over. An
		# entry reaching into another branch's subdirectory was written
		# against that branch, so some drift in the surrounding code is
		# expected and it gets the slack quiltimport gave everything.
		#
		# git reduces context progressively and only as far as it must,
		# so -C is a floor rather than a setting: a patch whose context
		# matches in full is applied in full either way.
		my $context = $e->{shared} ? '-C1' : '-C3';

		my @out = run_log(
			qq{git -C "$srcdir" apply --index $context $strip-- "$file"},
			$logdir);
		my $status = $? >> 8;
		my $text = join('', @out);

		if ($status)
		{
			return {
				ok => 0,
				applied => \@applied,
				failure => {
					name => $e->{name},
					reason => 'apply-failed',
					detail => $text,
				},
			};
		}

		push(
			@applied,
			{
				name => $e->{name},
				sha => $e->{sha},
				path => $e->{path},
				output => $text,
			}
		);
	}

	return { ok => 1, applied => \@applied };
}

1;
