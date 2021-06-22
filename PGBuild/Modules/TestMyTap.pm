
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2021, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::TestMyTap;

use PGBuild::Log;
use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $steps_completed);

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_12';

my $hooks = {
	'checkout'     => \&checkout,
	'setup-target' => \&setup_target,
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

	return unless $branch eq 'HEAD';

	my @opts = @{$conf->{config_opts}};

	return unless grep {/enable-tap-tests/} @opts;

	my $tests = $conf->{my_tap_tests};

	return unless $tests;

	while (my ($name,$params) = each %$tests)
	{

		my $self = {
			buildroot => $buildroot,
			pgbranch  => $branch,
			bfconf    => $conf,
			pgsql     => $pgsql,
			testset   => $name,
			testparams => $params,
		   };
		bless($self, $class);

		my $scmconf = {
			scm             => 'git',
			scmrepo         => $params->{url},
			git_reference   => undef,
			git_keep_mirror => 'true',
			git_ignore_mirror_failure => 'true',
			build_root                => $self->{buildroot},
		};
		$self->{scm} = PGBuild::SCM->new($scmconf, $name);
		my $where = $self->{scm}->get_build_path();
		$self->{where} = $where;
		$self->{pg_config} = "$buildroot/$branch/inst/bin/pg_config";
		register_module_hooks($self, $hooks);
	}
	return;
}

sub checkout
{
	my $self       = shift;
	my $savescmlog = shift;    # array ref to the log lines

	my $cobranch = 'main' ; # the default

	my $branch = $self->{testparams}->{branch};
	if (defined $branch && ref $branch eq 'HASH')
	{
	  if (exists $branch->{$self->{pgbranch}})
		{
			$cobranch = $branch->{$self->{pgbranch}};
		}
		elsif (exists $branch->{default})
		{
			$cobranch = $branch->{default};
		}
		else
		{
			$cobranch = 'no_such_branch';
		}
	}
	elsif (defined $branch)
	{
		$cobranch = $branch;
	}

	if ($cobranch eq 'PGBRANCH')
	{
		$cobranch = $self->{pgbranch};
	}

	print time_str(), "checking out test set ",$self->{testset}, "\n"
	  if $verbose;

    my $scmlog = $self->{scm}->checkout($cobranch);

    push(@$savescmlog,
		 "------------- test set $self->{testset}  checkout ----------------\n",
		 @$scmlog);
	return;
}

sub setup_target
{
	my $self = shift;

	if ($from_source || $from_source_clean)
	{
		# from-source doesn't call checkout
		my @lines;
		$self->checkout(\@lines);
	}

	# copy the code or setup a vpath dir if supported as appropriate

    print time_str(), "copying source to  ...$self->{where}\n"
      if $verbose;

    $self->{scm}->copy_source(undef);
	return;

}

sub installcheck
{
	my $self   = shift;
	my $locale = shift;
	my $testset = $self->{testset};

	return unless $locale eq 'C'; # just run once

	print time_str(), "installchecking test set ", $testset, "\n"
	  if $verbose;

	my $cmd = "make PG_CONFIG=$self->{pg_config} installcheck";
	my @log = run_log("cd $self->{where} && $cmd");
	my $status = $? >> 8;

	my @logs = glob("$self->{where}/tmp_check/log/*");
	my $log = PGBuild::Log->new("$testset-installcheck");
	$log->add_log($_) foreach @logs;
	push(@log, $log->log_string);
    writelog("$testset-install-check", \@log);
    print "======== testset $testset installcheck log ===========\n",  @log
      if ($verbose > 1);
    send_result("${testset}InstallCheck", $status, \@log) if $status;
    $steps_completed .= " ${testset}InstallCheck";
	return;
}

sub cleanup
{
	my $self = shift;

	print time_str(), "cleaning up test set ",$self->{testset}, "\n" if $verbose > 1;

	my $cmd = "make PG_CONFIG=$self->{pg_config} clean";
	my @log = `cd $self->{where} && $cmd 2>&1`;

	return;
}

1;
