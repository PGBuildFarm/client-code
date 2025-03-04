
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2024, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::TestCollateLinuxUTF8;

use PGBuild::Log;
use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $steps_completed);

use Fcntl qw(:seek);

use strict;
use warnings;

our ($VERSION); $VERSION = 'REL_19';

my $hooks = { 'installcheck' => \&installcheck, };

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch = shift;       # The branch of Postgres that's being built.
	my $conf = shift;         # ref to the whole config object
	my $pgsql = shift;        # postgres build dir

	my $locales = $conf->{locales};
	my $found = 0;
	return unless ref $locales eq 'ARRAY';
	foreach my $locale (@$locales)
	{
		next unless $locale =~ /utf8$/i;
		$found = 1;
		last;
	}

	return unless $found;

	my $os = `uname -s`;
	return unless $os =~ /linux/i;

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

sub installcheck
{
	my $self = shift;
	my $locale = shift;

	my $pgsql = $self->{pgsql};
	my $branch = $self->{pgbranch};
	my $buildroot = "$self->{buildroot}/$branch";
	my $binswitch =
	  ($branch ne 'HEAD' && $branch lt 'REL9_5') ? 'psqldir' : 'bindir';
	my $installdir = "$buildroot/inst";

	return unless $locale =~ /utf8$/i;

	return unless step_wanted("installcheck-collate-$locale");

	print time_str(), "installchecking $locale ", __PACKAGE__, "\n"
	  if $verbose;

	(my $buildport = $ENV{EXTRA_REGRESS_OPTS}) =~ s/--port=//;

	my $inputdir = "";
	if ($self->{bfconf}->{use_vpath})
	{
		if ($from_source)
		{
			$inputdir = "--inputdir=$from_source/src/test/regress";
		}
		else
		{
			$inputdir = "--inputdir=$buildroot/pgsql/src/test/regress";
		}
	}

	my $logpos = -s "$installdir/logfile" || 0;

	my @checklog;
	my $cmd = "./pg_regress --$binswitch=$installdir/bin --dlpath=. "
	  . "$inputdir --port=$buildport collate.linux.utf8";
	@checklog = run_log("cd $pgsql/src/test/regress && $cmd");

	my $status = $? >> 8;

	my $log = PGBuild::Log->new("install-check-collate-$locale");

	my @logfiles = ("$pgsql/src/test/regress/regression.diffs", "inst/logfile");
	foreach my $logfile (@logfiles)
	{
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
	push(@checklog, $log->log_string);

	writelog("install-check-collate-$locale", \@checklog);
	print "======== make installcheck collate-$locale log ========\n", @checklog
	  if ($verbose > 1);
	send_result("InstallCheck-collate-$locale", $status, \@checklog)
	  if $status;
	$steps_completed .= " InstallCheck-collate-$locale";

	return;
}

1;
