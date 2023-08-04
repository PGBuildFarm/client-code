
# Package Namespace is hardcoded. Modules must live in
# PGBuild::Modules

=comment

Copyright (c) 2003-2022, Andrew Dunstan

See accompanying License file for license details

=cut

package PGBuild::Modules::CheckIndent;

use PGBuild::Options;
use PGBuild::SCM;
use PGBuild::Utils;
use PGBuild::Log;

use Cwd qw(abs_path getcwd);

use strict;
use warnings;

our ($VERSION); $VERSION = 'REL_16';

my $hooks = { 'build' => \&build, };

sub setup
{
	my $class = __PACKAGE__;

	my $buildroot = shift;    # where we're building
	my $branch = shift;       # The branch of Postgres that's being built.
	my $conf = shift;         # ref to the whole config object
	my $pgsql = shift;        # postgres build dir

	return unless $branch eq 'HEAD';

	# could even set up several of these (e.g. for different branches)
	my $self = {
		buildroot => $buildroot,
		pgbranch => $branch,
		bfconf => $conf,
		pgsql => $pgsql
	};
	bless($self, $class);

	register_module_hooks($self, $hooks);
	return;
}



sub build
{
	# note - we run this in the source directory, not the build directory
	# even if it's a vpath build

	my $self = shift;

	return unless step_wanted('indent-check');

	print time_str(), "checking for pgindent diffs ...\n" if $verbose;

	my $pgsql = abs_path($self->{pgsql});

	local $ENV{PATH} = "$pgsql/src/tools/pg_bsd_indent:$ENV{PATH}";

	my $status;
	my @diffs;

	my $cmd = "src/tools/pgindent/pgindent --show-diff .";

	@diffs = run_log("cd pgsql && $cmd");
	$status = $? >> 8;

	my $log = PGBuild::Log->new("indent-check");
	$log->add_log_lines("indent.diff", \@diffs);

	# --show-diff doesn't exit with error, unlike --silent-diff
	$status ||= 1 if @diffs;

	@diffs = ("============ pgindent check ======\n", $log->log_string);

	writelog("indent-check", \@diffs);
	print @diffs if ($verbose > 1);
	send_result("indent-check", $status, \@diffs) if $status;
	return;
}

1;
