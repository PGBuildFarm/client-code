
package PGBuild::Modules::Dist;


=comment

Copyright (c) 2003-2024, Andrew Dunstan

See accompanying License file for license details

=cut

use PGBuild::Options;
use PGBuild::SCM;

use strict;
use warnings;

our ($VERSION); $VERSION = 'REL_20';

my $hooks = {
	'build' => \&build,
	'install' => \&install,
};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch = shift;       # The branch of Postgres that's being built.
	my $conf = shift;         # ref to the whole config object
	my $pgsql = shift;        # postgres build dir

	die "can't run this module with vpath builds"
	  if $conf->{vpath};

	my $self = {
		buildroot => $buildroot,
		pgbranch => $branch,
		bfconf => $conf,
		pgsql => $pgsql
	};
	bless($self, $class);

	main::register_module_hooks($self, $hooks)
	  ;    # if ($self->{pgbranch} eq "HEAD");
	return;
}

sub build
{
	my $self = shift;

	print main::time_str(), "running make dist ", __PACKAGE__, "\n"
	  if $verbose;
	my $src = "$self->{buildroot}/$self->{pgbranch}/pgsql";
	symlink("$src/.git", "$self->{pgsql}/.git");
	system("ls -la $self->{pgsql}");
	my @log = `cd $self->{pgsql} && make dist 2>&1`;
	my $status = $? >> 8;
	main::writelog('make-dist', \@log);
	print "======== make dist log ===========\n", @log
	  if ($verbose > 1);

	main::send_result('Make-Dist', $status, \@log) if $status;
	return;
}

sub install
{
	my $self = shift;

	print main::time_str(), "copying dist files ", __PACKAGE__, "\n"
	  if $verbose;
	my $whence = $self->{pgsql};
	my $where = "$self->{buildroot}/$self->{pgbranch}";

	system("mv $whence/postgresql-*.tar* $where >/dev/null 2>&1");
	my $status = $? >> 8;

	main::send_result('Copy-Dist', $status, []) if $status;
	return;
}

1;
