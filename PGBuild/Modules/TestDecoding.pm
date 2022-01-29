
package PGBuild::Modules::TestDecoding;

=comment

Copyright (c) 2003-2022, Andrew Dunstan

See accompanying License file for license details

=cut

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils qw(:DEFAULT $steps_completed);

use File::Basename;

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_13.1';

my $hooks = { 'check' => \&check, };

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch    = shift;    # The branch of Postgres that's being built.
	my $conf      = shift;    # ref to the whole config object
	my $pgsql     = shift;    # postgres build dir

	# for now do nothing on MSVC
	return if $conf->{using_msvc};

	# only for supported branches
	return unless $branch eq 'HEAD' || $branch ge 'REL9_4_STABLE';

	my $self = {
		buildroot => $buildroot,
		pgbranch  => $branch,
		bfconf    => $conf,
		pgsql     => $pgsql
	};
	bless($self, $class);

	register_module_hooks($self, $hooks);
	return;
}

sub check
{
	my $self = shift;

	return unless step_wanted('test-decoding-check');

	print time_str(), "checking test-decoding\n" if $verbose;

	my $installdir = "$self->{buildroot}/$self->{pgbranch}/inst";

	my $temp_inst_ok = check_install_is_complete($self->{pgsql}, $installdir);

	my $make = $self->{bfconf}->{make};

	my @checklog;

	if ($self->{bfconf}->{using_msvc})
	{
		#        $ENV{NO_TEMP_INSTALL} = $temp_inst_ok ? "1" : "0";
		#        chdir "$self->{pgsql}/src/tools/msvc";
		#        @checklog = `perl vcregress.pl upgradecheck 2>&1`;
		#        chdir "$self->{buildroot}/$self->{pgbranch}";
	}
	else
	{
		my $instflags = $temp_inst_ok ? "NO_TEMP_INSTALL=yes" : "";
		my $cmd =
		  "cd $self->{pgsql}/contrib/test_decoding && $make $instflags check";
		@checklog = run_log($cmd);
	}

	my @logfiles = glob(
		"$self->{pgsql}/contrib/test_decoding/regression_output/log/*.log
         $self->{pgsql}/contrib/test_decoding/regression_output/*.diffs
         $self->{pgsql}/contrib/test_decoding/isolation_output/log/*.log
         $self->{pgsql}/contrib/test_decoding/isolation_output/*.diffs
         $self->{pgsql}/contrib/test_decoding/output_iso/log/*.log
         $self->{pgsql}/contrib/test_decoding/output_iso/*.diffs
         $self->{pgsql}/contrib/test_decoding/log/*.log
         $self->{pgsql}/contrib/test_decoding/*.diffs"
	);
	foreach my $log (@logfiles)
	{
		my $fname = $log;
		$fname =~ s!.*/([^/]+/log/[^/]+log)$!$1!;
		$fname =~ s!.*/([^/]+/[^/]+diffs)$!$1!;
		my $contents = file_contents($log);
		push(@checklog,
			"========================== $fname ================\n", $contents);
	}

	my $status = $? >> 8;

	writelog("test-decoding-check", \@checklog);
	print "======== test-decoding check log ===========\n", @checklog
	  if ($verbose > 1);
	send_result("test-decoding-check", $status, \@checklog) if $status;
	$steps_completed .= " test-decoding-check";

	return;
}

1;
