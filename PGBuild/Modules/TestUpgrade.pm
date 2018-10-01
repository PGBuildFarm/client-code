
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::TestUpgrade;

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $steps_completed);

use File::Basename;

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_8';

my $hooks = {

	#    'checkout' => \&checkout,
	#    'setup-target' => \&setup_target,
	#    'need-run' => \&need_run,
	#    'configure' => \&configure,
	#    'build' => \&build,
	#    'install' => \&install,
	'check' => \&check,

	#    'cleanup' => \&cleanup,
};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch    = shift;    # The branch of Postgres that's being built.
	my $conf      = shift;    # ref to the whole config object
	my $pgsql     = shift;    # postgres build dir

	die
	  "overly long build root $buildroot will cause upgrade problems - try something shorter than 46 chars"
	  if (length($buildroot) > 46);

	# don't run module if builtin test is enabled.
	my $using_tap_tests =
	    $conf->{using_msvc}
	  ? $conf->{config}->{tap_tests}
	  : grep { $_ eq '--enable-tap-tests' } @{ $conf->{config} };
	return
	  if $using_tap_tests && -d "$buildroot/$branch/pgsql/src/bin/pg_upgrade/t";

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

sub check
{
	my $self = shift;

	return unless step_wanted('pg_upgrade-check');

	print time_str(), "checking pg_upgrade\n" if $verbose;

	my $installdir = "$self->{buildroot}/$self->{pgbranch}/inst";

	my $temp_inst_ok = check_install_is_complete($self->{pgsql}, $installdir);

	my $make = $self->{bfconf}->{make};

	local %ENV = %ENV;
	delete $ENV{PGUSER};

	(my $buildport = $ENV{EXTRA_REGRESS_OPTS}) =~ s/--port=//;
	$ENV{PGPORT} = $buildport;

	my @checklog;

	if ($self->{bfconf}->{using_msvc})
	{
		$ENV{NO_TEMP_INSTALL} = $temp_inst_ok ? "1" : "0";
		chdir "$self->{pgsql}/src/tools/msvc";
		@checklog = run_log("perl vcregress.pl upgradecheck");
		chdir "$self->{buildroot}/$self->{pgbranch}";
	}
	else
	{
		my $cmd;
		my $instflags = $temp_inst_ok ? "NO_TEMP_INSTALL=yes" : "";

		if ($self->{pgbranch} eq 'HEAD' || $self->{pgbranch} ge 'REL9_5')
		{
			$cmd =
			  "cd $self->{pgsql}/src/bin/pg_upgrade && $make $instflags check";
		}
		else
		{
			$cmd =
			  "cd $self->{pgsql}/contrib/pg_upgrade && $make $instflags check";
		}
		@checklog = run_log($cmd);
	}

	my @logfiles = glob(
		"$self->{pgsql}/contrib/pg_upgrade/*.log
         $self->{pgsql}/contrib/pg_upgrade/log/*
         $self->{pgsql}/src/bin/pg_upgrade/*.log
         $self->{pgsql}/src/bin/pg_upgrade/log/*
         $self->{pgsql}/src/test/regress/*.diffs"
	);
	foreach my $log (@logfiles)
	{
		my $fname    = basename $log;
		my $contents = file_contents($log);
		push(@checklog,
			"=========================== $fname ================\n", $contents);
	}

	my $status = $? >> 8;

	writelog("check-pg_upgrade", \@checklog);
	print "======== pg_upgrade check log ===========\n", @checklog
	  if ($verbose > 1);
	send_result("pg_upgradeCheck", $status, \@checklog) if $status;
	{
		no warnings 'once';
		$steps_completed .= " pg_upgradeCheck";
	}
	return;
}

1;
