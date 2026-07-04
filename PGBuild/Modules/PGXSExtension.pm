
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2024, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::PGXSExtension;

# Generic module for building and testing one or more out-of-tree PGXS
# extensions against the Postgres tree under test. Configure via the
# bfconf 'pgxs_extensions' hash: one entry per extension, keyed by the
# label used for step/result names (e.g. 'RedisFDW'). See
# build-farm.conf.sample for the available per-extension settings and
# examples.

use PGBuild::Log;
use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils;

use File::Path 'mkpath';
use Fcntl qw(:flock :seek);

use strict;
use warnings;

our ($VERSION); $VERSION = 'REL_21';

my $hooks = {
	'checkout' => \&checkout,
	'setup-target' => \&setup_target,
	'build' => \&build,
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

	my $extensions = $conf->{pgxs_extensions};

	return unless $extensions;

	while (my ($label, $params) = each %$extensions)
	{
		my $self = {
			buildroot => $buildroot,
			pgbranch => $branch,
			bfconf => $conf,
			pgsql => $pgsql,
			label => $label,
			params => $params,
		};
		bless($self, $class);

		my $scmconf = {
			scm => 'git',
			scmrepo => $params->{url},
			git_reference => undef,
			git_keep_mirror => 'true',
			git_ignore_mirror_failure => 'true',
			build_root => $self->{buildroot},
		};

		my $reponame = $params->{reponame} || $label;
		$self->{scm} = PGBuild::SCM->new($scmconf, $reponame);
		my $where = $self->{scm}->get_build_path();
		$self->{where} = $where;

		# clean up anything left from an aborted run
		rmtree($where);

		register_module_hooks($self, $hooks);
	}
	return;
}

sub checkout
{
	my $self = shift;
	my $savescmlog = shift;    # array ref to the log lines

	my $label = $self->{label};

	print time_str(), "checking out $label\n" if $verbose;

	my $ref = $self->{params}->{branch} || 'HEAD';
	$ref = $self->{pgbranch} if $ref eq 'PGBRANCH';

	my $scmlog = $self->{scm}->checkout($ref);

	push(@$savescmlog,
		"------------- $label checkout ----------------\n", @$scmlog);
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

	my $label = $self->{label};

	print time_str(), "building $label\n" if $verbose;

	my $cmd = "PATH=../inst:$ENV{PATH} make USE_PGXS=1";

	my @makeout = run_log("cd $self->{where} && $cmd");

	my $status = $? >> 8;
	writelog("$label-build", \@makeout);
	print "======== make log ===========\n", @makeout if ($verbose > 1);
	$status ||= check_make_log_warnings("$label-build", $verbose)
	  if $check_warnings;
	send_result("$label-build", $status, \@makeout) if $status;
	return;
}

sub install
{
	my $self = shift;

	my $label = $self->{label};

	print time_str(), "installing $label\n" if $verbose;

	my $module_db =
	  $self->{params}->{install_use_module_db} ? ' USE_MODULE_DB=1' : '';
	my $cmd = "PATH=../inst:$ENV{PATH} make USE_PGXS=1$module_db install";

	my @log = run_log("cd $self->{where} && $cmd");

	my $status = $? >> 8;
	writelog("$label-install", \@log);
	print "======== install log ===========\n", @log if ($verbose > 1);
	send_result("$label-install", $status, \@log) if $status;
	return;
}

sub get_lock
{
	my $self = shift;
	my $exclusive = shift;
	my $label = $self->{label};
	my $lockfile = "$self->{buildroot}/$label-installcheck.LCK";

	# note no branch involved here. we want all the branches building
	# this extension to use the same lock.
	open(my $lock, ">", $lockfile)
	  || die "opening $label installcheck lock file";

	# wait if necessary for the lock
	if (!flock($lock, $exclusive ? LOCK_EX : LOCK_SH))
	{
		print STDERR "Unable to get $label installcheck lock. Exiting.\n";
		exit(1);
	}
	$self->{lockfile} = $lock;
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

	my $label = $self->{label};
	my $params = $self->{params};

	return unless $params->{installcheck};
	return unless $locale eq 'C';

	print time_str(), "install-checking $label\n" if $verbose;

	my $cmd = "make USE_PGXS=1 USE_MODULE_DB=1 installcheck";

	my $installdir = "$self->{buildroot}/$self->{pgbranch}/inst";
	my $logpos =
	  $params->{logfile_offset} ? (-s "$installdir/logfile" || 0) : 0;

	$self->get_lock(1) if $params->{serialize_installcheck};

	my @log = run_log("cd $self->{where} && $cmd");

	$self->release_lock if $params->{serialize_installcheck};

	my $status = $? >> 8;

	my $log = PGBuild::Log->new("$label-installcheck-$locale");

	my $diffs = $params->{regress_diffs} || 'regression.diffs';
	my @logfiles = ("$self->{where}/$diffs", "$installdir/logfile");
	foreach my $logfile (@logfiles)
	{
		last unless $status;
		my $lpos = 0;
		$lpos = $logpos if $logfile eq "$installdir/logfile";
		$log->add_log($logfile, $lpos);
	}
	if ($status)
	{
		my @trace =
		  get_stack_trace("$installdir/bin", "$installdir/data-$locale");
		$log->add_log_lines("stack-trace", \@trace) if @trace;
	}
	push(@log, $log->log_string);
	writelog("$label-installcheck-$locale", \@log);
	print "======== installcheck ($locale) log ===========\n", @log
	  if ($verbose > 1);
	send_result("$label-installcheck-$locale", $status, \@log) if $status;
	return;
}

sub cleanup
{
	my $self = shift;

	print time_str(), "cleaning up $self->{label}\n" if $verbose > 1;

	rmtree($self->{where});
	return;
}

1;
