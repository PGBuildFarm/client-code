
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2019, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::CheckPerl;

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils;

use Cwd qw(getcwd);

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_9';

my $hooks = { 'build' => \&build, };

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch    = shift;    # The branch of Postgres that's being built.
	my $conf      = shift;    # ref to the whole config object
	my $pgsql     = shift;    # postgres build dir

	return unless $branch eq 'HEAD' || $branch ge 'REL_11';

	# could even set up several of these (e.g. for different branches)
	my $self = {
		buildroot => $buildroot,
		pgbranch  => $branch,
		bfconf    => $conf,
		pgsql     => $pgsql
	};
	bless($self, $class);

	# for each instance you create, do:
	register_module_hooks($self, $hooks);
	return;
}

sub find_perl_files
{
	my $pgsql = shift;

	my %files;

	my $wanted = sub {
		my ($dev, $ino, $mode, $nlink, $uid, $gid);

		($dev, $ino, $mode, $nlink, $uid, $gid) = lstat($_);
		-f _ || return;
		if (/\.p[lm]\z/)
		{
			$files{$File::Find::name} = 1;
		}
		elsif (($mode & 0100) == 0100)    ## no critic (ProhibitLeadingZeros)

		{
			my $fileout = `file $File::Find::name`;
			$files{$File::Find::name} = 1
			  if ($fileout =~ /:.*perl[0-9]*\b/i);
		}
	};

	my $here = getcwd;

	chdir $pgsql;

	File::Find::find({ wanted => $wanted }, ".");

	chdir $here;

	return (sort keys %files);
}



sub build
{
	# note - we run this in the source directory, not the build directory
	# even if it's a vpath build

	my $self = shift;

	return unless step_wanted('perl-check');

	print time_str(), "checking perl code ...\n" if $verbose;

	my $perlcritic = $ENV{PERLCRITIC} || 'perlcritic';

	my @files = find_perl_files('pgsql');
	my $files = join(' ', @files);

	my @criticlog =
	  run_log("cd pgsql && $perlcritic "
		  . "--program-extensions .pl "
		  . "--profile=src/tools/perlcheck/perlcriticrc "
		  . $files);
	unshift(@criticlog, "================== perlcritic output =============\n");
	my $status = $? >> 8;

	unless ($status)
	{

		my @includes = qw(src/test/perl
		  src/tools/msvc
		  src/backend/catalog
		  src/backend/utils/mb/Unicode
		  src/bin/pg_rewind
		  src/test/ssl
		  src/tools/msvc/dummylib);
		do { s/^/-I/; }
		  foreach @includes;
		my $incl = join(' ', @includes);

		my @cwlog =
		  run_log("cd pgsql && "
			  . " ST=0 && for f in $files; do perl $incl -cw \$f || ST=1; done && test \$ST = 0"
		  );


		$status = $? >> 8;

		push @criticlog,
		  "================== perl -cw output =============\n",
		  @cwlog;
	}

	writelog("perl-check", \@criticlog);
	print @criticlog if ($verbose > 1);
	send_result("perl-check", $status, \@criticlog) if $status;
	return;
}


1;
