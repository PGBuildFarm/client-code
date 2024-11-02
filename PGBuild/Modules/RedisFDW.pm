# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules


=comment

Copyright (c) 2003-2024, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::RedisFDW;

use PGBuild::Log;
use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils;

use File::Path 'mkpath';
use Fcntl qw(:flock :seek);


use strict;
use warnings;

# strip required namespace from package name
(my $MODULE = __PACKAGE__) =~ s/PGBuild::Modules:://;

our ($VERSION); $VERSION = 'REL_17';

my $hooks = {
	'checkout' => \&checkout,
	'setup-target' => \&setup_target,

	# 'need-run' => \&need_run,
	# 'configure' => \&configure,
	'build' => \&build,

	# 'check' => \&check,
	'install' => \&install,
	'installcheck' => \&installcheck,
	'cleanup' => \&cleanup,
};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch = shift;       # The branch of Postgres that's being built.
	my $conf = shift;         # ref to the whole config object
	my $pgsql = shift;        # postgres build dir

	# could even set up several of these (e.g. for different branches)
	my $self = {
		buildroot => $buildroot,
		pgbranch => $branch,
		bfconf => $conf,
		pgsql => $pgsql
	};
	bless($self, $class);

	my $scmconf = {
		scm => 'git',
		scmrepo => 'https://github.com/pg-redis-fdw/redis_fdw.git',
		git_reference => undef,
		git_keep_mirror => 'true',
		git_ignore_mirror_failure => 'true',
		build_root => $self->{buildroot},
	};

	$self->{scm} = PGBuild::SCM->new($scmconf, 'redis_fdw');
	my $where = $self->{scm}->get_build_path();
	$self->{where} = $where;

	# clean up anything left from an aborted run
	rmtree($where);

	# for each instance you create, do:
	register_module_hooks($self, $hooks);
	return;
}

sub checkout
{
	my $self = shift;
	my $savescmlog = shift;    # array ref to the log lines

	print time_str(), "checking out $MODULE\n" if $verbose;

	my $scmlog = $self->{scm}->checkout($self->{pgbranch});

	push(@$savescmlog,
		"------------- $MODULE checkout ----------------\n", @$scmlog);
	return;
}

sub setup_target
{
	my $self = shift;

	# copy the code or setup a vpath dir if supported as appropriate

	print time_str(), "copying source to  ...$self->{where}\n"
	  if $verbose;

	$self->{scm}->copy_source(undef);
	return;
}

sub build
{
	my $self = shift;

	print time_str(), "building $MODULE\n" if $verbose;

	my $cmd = "PATH=../inst:$ENV{PATH} make USE_PGXS=1";

	#	print STDERR `pwd`,',',-e $self->{where}, ": $cmd\n";

	my @makeout = `cd $self->{where} && $cmd 2>&1`;

	my $status = $? >> 8;
	writelog("$MODULE-build", \@makeout);
	print "======== make log ===========\n", @makeout if ($verbose > 1);
	$status ||= check_make_log_warnings("$MODULE-build", $verbose)
	  if $check_warnings;
	send_result("$MODULE-build", $status, \@makeout) if $status;
	return;
}

sub install
{
	my $self = shift;

	print time_str(), "installing $MODULE\n" if $verbose;

	my $cmd = "make USE_PGXS=1 USE_MODULE_DB=1 install";

	my @log = `cd $self->{where} && $cmd 2>&1`;

	my $status = $? >> 8;
	writelog("$MODULE-install", \@log);
	print "======== install log ===========\n", @log if ($verbose > 1);
	send_result("$MODULE-install", $status, \@log) if $status;
	return;
}

sub get_lock
{
	my $self = shift;
	my $exclusive = shift;
	my $lockdir = $self->{buildroot};

	# note no branch involved here. we want all the branches to use
	# the same lock.
	my $lockfile = "$lockdir/redis-installcheck.LCK";
	open(my $rlock, ">", $lockfile)
	  || die "opening redis installcheck lock file";

	# wait if necessary for the lock
	if (!flock($rlock, $exclusive ? LOCK_EX : LOCK_SH))
	{
		print STDERR "Unable to get redis installcheck lock. Exiting.\n";
		exit(1);
	}
	$self->{lockfile} = $rlock;
	return;
}

sub release_lock
{
	my $self = shift;
	close($self->{lockfile});
	delete $self->{lockfile};
	return;
}

sub installcheck
{
	my $self = shift;
	my $locale = shift;

	return unless $locale eq 'C';

	my $branch = $self->{pgbranch};

	print time_str(), "install-checking $MODULE\n" if $verbose;

	my $cmd = "make USE_PGXS=1 USE_MODULE_DB=1 installcheck";

	my $installdir = "$self->{buildroot}/$self->{pgbranch}/inst";
	my $logpos = -s "$installdir/logfile" || 0;

	get_lock($self, 1);

	my @log = `cd $self->{where} && $cmd 2>&1`;

	release_lock($self);

	my $status = $? >> 8;

	my $log = PGBuild::Log->new("$MODULE-installcheck-$locale");

	my @logfiles = ("$self->{where}/test/regression.diffs", "inst/logfile");
	foreach my $logfile (@logfiles)
	{
		last unless $status;
		my $lpos = 0;
		$lpos = $logpos if $logfile eq "inst/logfile";
		$log->add_log($logfile, $lpos);
	}
	if ($status)
	{
		my @trace =
		  get_stack_trace("$installdir/bin", "$installdir/data-$locale");
		$log->add_log_lines("stack-trace", \@trace) if @trace;
	}
	push(@log, $log->log_string);
	writelog("$MODULE-installcheck-$locale", \@log);
	print "======== installcheck ($locale) log ===========\n", @log
	  if ($verbose > 1);
	send_result("$MODULE-installcheck-$locale", $status, \@log) if $status;
	return;
}

sub cleanup
{
	my $self = shift;

	print time_str(), "cleaning up $MODULE\n" if $verbose > 1;

	rmtree($self->{where});
	return;
}

1;
