
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2019, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::TestICU;

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $steps_completed);

use Fcntl qw(:seek);

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_10';

my $hooks = { 'installcheck' => \&installcheck, };

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch    = shift;    # The branch of Postgres that's being built.
	my $conf      = shift;    # ref to the whole config object
	my $pgsql     = shift;    # postgres build dir

	return unless grep { $_ eq '--with-icu' } @{ $conf->{config_opts} },

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

sub installcheck
{
	my $self   = shift;
	my $locale = shift;

	return unless $locale =~ /utf8/i;

	my $pgsql      = $self->{pgsql};
	my $branch     = $self->{pgbranch};
	my $buildroot  = "$self->{buildroot}/$branch";
	my $binswitch  = 'bindir';
	my $installdir = "$buildroot/inst";

	return unless $locale =~ /utf8$/i;

	return unless step_wanted("installcheck-icu");

	print time_str(), "installchecking ICU-$locale\n"
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
	  . "$inputdir --port=$buildport collate.icu.utf8";
	@checklog = run_log("cd $pgsql/src/test/regress && $cmd");

	my $status = $? >> 8;
	my @logfiles =
	  ("$pgsql/src/test/regress/regression.diffs", "$installdir/logfile");
	foreach my $logfile (@logfiles)
	{
		next unless (-e $logfile);
		push(@checklog, "\n\n================== $logfile ==================\n");
		my $lpos = 0;
		$lpos = $logpos if $logfile eq "$installdir/logfile";
		push(@checklog, file_lines($logfile, $lpos));
	}
	if ($status)
	{
		my @trace =
		  get_stack_trace("$installdir/bin", "$installdir/data-$locale");
		push(@checklog, @trace);
	}
	writelog("install-check-ICU-$locale", \@checklog);
	print "======== make installcheck -ICU-$locale log ========\n", @checklog
	  if ($verbose > 1);
	send_result("InstallCheck-ICU-$locale", $status, \@checklog)
	  if $status;
	$steps_completed .= " InstallCheck-ICU-$locale";

	return;
}

1;
