
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2024, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::TestUpgrade;

use PGBuild::Log;
use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $steps_completed);

use File::Basename;

use strict;
use warnings;

our ($VERSION); $VERSION = 'REL_20';

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
	my $branch = shift;       # The branch of Postgres that's being built.
	my $conf = shift;         # ref to the whole config object
	my $pgsql = shift;        # postgres build dir

	# this obviates the need of any meson support in this module, as
	# this has been in since release 15
	my $srcdir = $from_source || "$buildroot/$branch/pgsql";
	return if -d "$srcdir/src/bin/pg_upgrade/t";

	die
	  "overly long build root $buildroot will cause upgrade problems - try something shorter than 46 chars"
	  if (length($buildroot) > 46);

	# could even set up several of these (e.g. for different branches)
	my $self = {
		buildroot => $buildroot,
		pgbranch => $branch,
		bfconf => $conf,
		pgsql => $pgsql
	};
	bless($self, $class);

	# for each instance you create, do:
	register_module_hooks($self, $hooks);
	return;
}

sub check
{
	my $self = shift;

	# rerun this check in case rm_worktrees is being used, in which case it
	# will fail in the setup step because the code isn't yet checked out
	return
	  if -d "$self->{buildroot}/$self->{pgbranch}/pgsql/src/bin/pg_upgrade/t";

	return unless step_wanted('pg_upgrade-check');

	print time_str(), "checking pg_upgrade\n" if $verbose;

	my $installdir = "$self->{buildroot}/$self->{pgbranch}/inst";

	my $temp_inst_ok = check_install_is_complete($self->{pgsql}, $installdir);

	my $binloc =
	  $temp_inst_ok
	  ? "tmp_install"
	  : "src/bin/pg_upgrade/tmp_check/install";
	my $tmp_bin_dir = "$self->{pgsql}/$binloc/$installdir/bin";
	my $tmp_data_dir = "$self->{pgsql}/src/bin/pg_upgrade/tmp_check/data.old";

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

		if ($self->{pgbranch} ne 'HEAD' && $self->{pgbranch} lt 'REL9_5')
		{
			$cmd =
			  "cd $self->{pgsql}/contrib/pg_upgrade && $make $instflags check";
		}
		else
		{
			$cmd =
			  "cd $self->{pgsql}/src/bin/pg_upgrade && $make $instflags check";
		}
		@checklog = run_log($cmd);
	}

	my $log = PGBuild::Log->new("check-pg_upgrade");

	# This list tries to cover all the places that upgrade regression diffs
	# and logs have been placed in various releases. If they don't exist
	# no harm will be done.
	my @logfiles = glob(
		"$self->{pgsql}/contrib/pg_upgrade/*.log
         $self->{pgsql}/contrib/pg_upgrade/log/*
         $self->{pgsql}/src/bin/pg_upgrade/*.log
         $self->{pgsql}/src/bin/pg_upgrade/log/*
         $self->{pgsql}/src/bin/pg_upgrade/tmp_check/*/*.diffs
         $self->{pgsql}/src/bin/pg_upgrade/tmp_check/data/pg_upgrade_output.d/log/*
         $self->{pgsql}/src/test/regress/*.diffs"
	);
	$log->add_log($_) foreach (@logfiles);

	my $status = $? >> 8;

	if ($status && !$self->{bfconf}->{using_msvc})
	{
		my @trace = get_stack_trace("$tmp_bin_dir", "$tmp_data_dir");
		$log->add_log_lines("stack-trace", \@trace) if @trace;
	}

	push(@checklog, $log->log_string);

	writelog("check-pg_upgrade", \@checklog);
	print "======== pg_upgrade check log ===========\n", @checklog
	  if ($verbose > 1);
	send_result("pg_upgradeCheck", $status, \@checklog) if $status;
	$steps_completed .= " pg_upgradeCheck";

	return;
}

1;
