
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::TestSepgsql;

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $steps_completed $tmpdir);

use File::Find;

use Cwd;

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_7';

my $hooks = {
	'build'      => \&build,
	'install'    => \&install,
	'locale-end' => \&locale_end,
	'cleanup'    => \&cleanup,
};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch    = shift;    # The branch of Postgres that's being built.
	my $conf      = shift;    # ref to the whole config object
	my $pgsql     = shift;    # postgres build dir

	die "vpath testing not supported for SELinux tests"
	  if $conf->{use_vpath};

	my $enforcing = `getenforce 2>&1`;
	chomp $enforcing;
	die "SELinux is not enforcing"
	  unless $enforcing eq 'Enforcing';

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

# assumes the user has passwordless sudo privs
# location of selinux Makefile is also hardcoded,
# although it's fairly likely to be stable.

sub build
{
	my $self  = shift;
	my $pgsql = $self->{pgsql};

	print time_str(), "building sepgsql policy module\n" if $verbose;

	# the main build will set up sepgsql, what we need to do here is build
	# the policy module

	my $dir = cwd();

	chdir "$pgsql/contrib/sepgsql";

	my $make = $self->{bfconf}->{make};
	my @log  = run_log("$make -f /usr/share/selinux/devel/Makefile");
	;    #  && sudo semodule -u sepgsql-regtest.pp 2>&1`;
	my $status = $? >> 8;

	chdir $dir;

	writelog("sepgsql-policy-build", \@log);
	print "======== build sepgsql policy log ========\n", @log
	  if ($verbose > 1);
	send_result("sepgsql-policy-build", $status, \@log)
	  if $status;
	{
		no warnings 'once';
		$steps_completed .= " sepgsql-policy-build";
	}
	return;
}

sub install
{
	my $self  = shift;
	my $pgsql = $self->{pgsql};

	print time_str(), "installing sepgsql policy module\n"
	  if $verbose;

	# the main build will set up sepgsql, what we need to do here is install
	# the policy module

	my $dir = cwd();

	chdir "$pgsql/contrib/sepgsql";

	my $make   = $self->{bfconf}->{make};
	my @log    = run_log("sudo semodule -u sepgsql-regtest.pp");
	my $status = $? >> 8;

	$self->{module_installed} = $status == 0;

	chdir $dir;

	writelog("sepgsql-policy-install", \@log);
	print "======== install sepgsql policy log ========\n", @log
	  if ($verbose > 1);
	send_result("sepgsql-policy-install", $status, \@log)
	  if $status;
	{
		no warnings 'once';
		$steps_completed .= " sepgsql-policy-install";
	}
	return;
}

sub locale_end
{
	my $self   = shift;
	my $locale = shift;
	my $pgsql  = $self->{pgsql};

	return unless $locale eq 'C';

	print time_str(), "testing sepgsql\n"
	  if $verbose;

	# set up a different data directory for selinux
	my @log = run_log("cd inst && bin/initdb -U buildfarm --no-locale sepgsql");

	my $status = $? >> 8;

	open(my $handle, ">>", "inst/sepgsql/postgresql.conf")
	  || die "opening inst/sepgsql/postgresql.conf: $!";
	my $param =
	  $self->{pgbranch} eq 'REL9_2_STABLE'
	  ? "unix_socket_directory"
	  : "unix_socket_directories";
	print $handle "$param = '$tmpdir'\n";
	print $handle "listen_addresses = ''\n";
	print $handle "shared_preload_libraries = 'sepgsql'\n";
	close $handle;

	my $sepgsql;
	my $wanted = sub {
		/^sepgsql\.sql\z/s && ($sepgsql = $File::Find::name);
	};
	File::Find::find($wanted, "inst/share");

	die "No sepgsql.sql found" unless $sepgsql;

	local %ENV = %ENV;
	$ENV{PGDATA} = cwd() . "/inst/sepgsql";
	$ENV{PATH}   = cwd() . "/inst/bin:$ENV{PATH}";
	$ENV{PGHOST} = $tmpdir;

	foreach my $db (qw(template0 template1 postgres))
	{
		last if $status;
		my $cmd = "inst/bin/postgres --single -F -c exit_on_error=true $db";

		# no run_log due to redirections
		my @nlog = `$cmd < $sepgsql 2>&1 1>/dev/null`;
		push(@log,
			"====== installing sepgsql in single user mode in $db =========\n",
			@nlog);
		$status = $? >> 8;
	}

	if ($status)
	{
		writelog("sepgsql-test", \@log);
		print "======== test sepgsql setup ========\n", @log
		  if ($verbose > 1);
		send_result("test-sepgsql", $status, \@log);
	}

	my @startlog =
	  run_log("cd inst && bin/pg_ctl -D sepgsql -l sepgsql.log -w start");
	push(@log, "============ sepgsql start log\n", @startlog);
	$status = $? >> 8;

	if ($status)
	{
		writelog("sepgsql-test", \@log);
		print "======== test sepgsql ========\n", @log
		  if ($verbose > 1);
		send_result("test-sepgsql", $status, \@log);
	}

	system("sudo setsebool sepgsql_regression_test_mode on");

	my @testlog = run_log("cd $pgsql/contrib/sepgsql && ./test_sepgsql");
	push(@log, "============= sepgsql tests ============\n", @testlog);
	$status = $? >> 8;

	if (-e "$pgsql/contrib/sepgsql/regression.diffs")
	{
		push(@log, "================== regression.diffs ===============\n");
		push(@log, file_lines("$pgsql/contrib/sepgsql/regression.diffs"));
	}

	if ($status)
	{
		push(@log, "============== postgresql.log =================\n");
		push(@log, file_lines("inst/sepgsql.log"));
	}

	my @stoplog = run_log("cd inst && bin/pg_ctl -D sepgsql stop");
	push(@log, "============ sepgsql stop log\n", @stoplog);
	$status ||= $? >> 8;
	writelog("sepgsql-test", \@log);

	if ($status)
	{
		print "======== test sepgsql ========\n", @log
		  if ($verbose > 1);
		send_result("test-sepgsql", $status, \@log);
	}

	{
		no warnings 'once';
		$steps_completed .= " sepgsql-test";
	}
	return;
}

sub cleanup
{
	my $self = shift;

	return unless $self->{module_installed};

	print time_str(), "cleaning up ", __PACKAGE__, "\n" if $verbose > 1;

	system("sudo semodule -r sepgsql-regtest");
	return;
}

1;
