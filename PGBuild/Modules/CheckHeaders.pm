
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2022, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::CheckHeaders;

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils;

use Cwd qw(getcwd);

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_14';

my $hooks = { 'build' => \&build, };

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch    = shift;    # The branch of Postgres that's being built.
	my $conf      = shift;    # ref to the whole config object
	my $pgsql     = shift;    # postgres build dir

	return if $branch ne 'HEAD';

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


sub build
{
	my $self  = shift;
	my $pgsql = $self->{pgsql};
	my $make  = $self->{bfconf}->{make};

	return unless step_wanted('headers-check');

	print time_str(), "checking headers ...\n" if $verbose;

	my @hcheck = run_log("cd $pgsql && $make -s headerscheck");
	my $status = $? >> 8;

	my @cppcheck = run_log(
		"cd $pgsql && $make CXXFLAGS='-fsyntax-only -Wall -Wno-register' -s cpluspluscheck"
	);
	$status ||= $? >> 8;

	# output means we have errors
	$status ||= (@hcheck > 0 || @cppcheck > 0);

	unshift(@hcheck,   "headerscheck:\n");
	unshift(@cppcheck, "cpluspluscheck:\n");

	push(@hcheck, @cppcheck);

	writelog("check-headers", \@hcheck);
	print @hcheck if ($verbose > 1);
	send_result("headers-check", $status, \@hcheck) if $status;
	return;
}


1;
