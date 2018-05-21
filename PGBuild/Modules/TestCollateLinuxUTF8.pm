
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::TestCollateLinuxUTF8;

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $steps_completed);

use Fcntl qw(:seek);

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_8';

my $hooks = { 'installcheck' => \&installcheck, };

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch    = shift;    # The branch of Postgres that's being built.
	my $conf      = shift;    # ref to the whole config object
	my $pgsql     = shift;    # postgres build dir

	my $locales = $conf->{locales};
	my $found   = 0;
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

	my $pgsql     = $self->{pgsql};
	my $branch    = $self->{pgbranch};
	my $buildroot = "$self->{buildroot}/$branch";
	my $binswitch =
	  ($branch eq 'HEAD' || $branch ge 'REL9_5') ? 'bindir' : 'psqldir';
	my $installdir = "$buildroot/inst";

	return unless $locale =~ /utf8$/i;

	return unless step_wanted("installcheck-collate-$locale");

	print time_str(), "installchecking $locale", __PACKAGE__, "\n"
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
	my @logfiles =
	  ("$pgsql/src/test/regress/regression.diffs", "$installdir/logfile");
	foreach my $logfile (@logfiles)
	{
		next unless (-e $logfile);
		my $lpos = 0;
		$lpos = $logpos if $logfile eq "$installdir/logfile";

		push(@checklog, "\n\n================== $logfile ==================\n");
		push(@checklog, file_lines($logfile, $lpos));
	}
	if ($status)
	{
		my @trace =
		  get_stack_trace("$installdir/bin", "$installdir/data-$locale");
		push(@checklog, @trace);
	}
	writelog("install-check-collate-$locale", \@checklog);
	print "======== make installcheck collate-$locale log ========\n", @checklog
	  if ($verbose > 1);
	send_result("InstallCheck-collate-$locale", $status, \@checklog)
	  if $status;
	{
		no warnings 'once';
		$steps_completed .= " InstallCheck-collate-$locale";
	}
	return;
}

1;
