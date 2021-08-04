
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2021, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::FileTextArrayFDW;

use PGBuild::Options;
use PGBuild::Log;
use PGBuild::SCM;
use PGBuild::Utils;

use File::Path;

use strict;
use warnings;

# strip required namespace from package name
(my $MODULE = __PACKAGE__) =~ s/PGBuild::Modules:://;

use vars qw($VERSION); $VERSION = 'REL_13.1';

my $hooks = {
	'checkout'     => \&checkout,
	'setup-target' => \&setup_target,

	# 'need-run' => \&need_run,

	# 'configure' => \&configure,
	'build' => \&build,

	# 'check' => \&check,
	'install'      => \&install,
	'installcheck' => \&installcheck,
	'cleanup'      => \&cleanup,
};

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch    = shift;    # The branch of Postgres that's being built.
	my $conf      = shift;    # ref to the whole config object
	my $pgsql     = shift;    # postgres build dir

	# return unless step_wanted("$MODULE-build");

	# could even set up several of these (e.g. for different branches)
	my $self = {
		buildroot => $buildroot,
		pgbranch  => $branch,
		bfconf    => $conf,
		pgsql     => $pgsql
	};
	bless($self, $class);

	my $scmconf = {
		scm             => 'git',
		scmrepo         => 'git://github.com/adunstan/file_text_array_fdw.git',
		git_reference   => undef,
		git_keep_mirror => 'true',
		git_ignore_mirror_failure => 'true',
		build_root                => $self->{buildroot},
	};

	$self->{scm} = PGBuild::SCM->new($scmconf, 'file_text_array_fdw');
	my $where = $self->{scm}->get_build_path();
	$self->{where} = $where;

	# for each instance you create, do:
	register_module_hooks($self, $hooks);
	return;
}

sub checkout
{
	my $self       = shift;
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

sub configure
{
	my $self = shift;

	print time_str(), "configuring $MODULE\n" if $verbose;
	return;

}

sub build
{
	my $self = shift;

	print time_str(), "building $MODULE\n" if $verbose;

	my $cmd = "PATH=../inst:$ENV{PATH} make USE_PGXS=1";

	my @makeout = run_log("cd $self->{where} && $cmd");

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

	my $cmd = "PATH=../inst:$ENV{PATH} make USE_PGXS=1 install";

	my @log = run_log("cd $self->{where} && $cmd");

	my $status = $? >> 8;
	writelog("$MODULE-install", \@log);
	print "======== install log ===========\n", @log if ($verbose > 1);
	send_result("$MODULE-install", $status, \@log) if $status;
	return;
}

sub check
{
	my $self = shift;

	print time_str(), "checking ", __PACKAGE__, "\n" if $verbose;
	return;
}

sub installcheck
{
	my $self   = shift;
	my $locale = shift;

	return unless $locale eq 'C';

	my $make = $self->{bfconf}->{make};

	print time_str(), "install-checking $MODULE\n" if $verbose;

	my $cmd = "$make USE_PGXS=1 USE_MODULE_DB=1 installcheck";

	my @log = run_log("cd $self->{where} && $cmd");

	my $log = PGBuild::Log->new("$MODULE-installcheck-$locale");

	my $status     = $? >> 8;
	my $installdir = "$self->{buildroot}/$self->{pgbranch}/inst";
	my @logfiles   = ("$self->{where}/regression.diffs", "$installdir/logfile");
	if ($status)
	{
		$log->add_log($_) foreach (@logfiles);
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
