#!/usr/bin/perl

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_7';

use Fcntl qw(:flock :seek);
use File::Spec;
use File::Basename;
use Cwd qw(getcwd);

BEGIN
{
	unshift(@INC, $ENV{BFLIB}) if $ENV{BFLIB};
	use lib File::Spec->rel2abs(dirname(__FILE__));
}

my $orig_dir = getcwd();
unshift @INC, $orig_dir;

use PGBuild::Options;

# older msys is ging to use a different perl to run LWP, so we can't absolutely
# require this module there
BEGIN
{
	## no critic (ValuesAndExpressions::ProhibitMismatchedOperators)
	# perlcritic gets confused by version comparisons - this usage is
	# sanctioned by perldoc perlvar
	require LWP::Simple if $^O ne 'msys' || $^V ge v5.8.0;
}

my %branch_last;
sub branch_last_sort;

my $run_build;
($run_build = $0) =~ s/run_branches/run_build/;

my ($run_all, $run_one);
my %extra_options = (
	'run-all' => \$run_all,
	'run-one' => \$run_one,
);

# process the command line
PGBuild::Options::fetch_options(%extra_options);

# no non-option args allowed here
die("$0: non-option arguments not permitted")
  if @ARGV;

die "only one of --run-all and --run-one permitted"
  if ($run_all && $run_one);

die "need one of --run-all and --run-one"
  unless ($run_all || $run_one);

# set up a "branch" variable for processing the config file
use vars qw($branch);
$branch = 'global';

#
# process config file
#
require $buildconf;

die "from-source cannot be used with run_branches,pl"
  if ($from_source || $from_source_clean);

PGBuild::Options::fixup_conf(\%PGBuild::conf, \@config_set);

unless (
	(
		ref $PGBuild::conf{branches_to_build} eq 'ARRAY'
		&& @{ $PGBuild::conf{branches_to_build} }
	)
	|| $PGBuild::conf{branches_to_build} =~
	/^(ALL|HEAD_PLUS_LATEST|HEAD_PLUS_LATEST\d)$/
  )
{
	die "no branches_to_build specified in $buildconf";
}

my @branches;
if (ref $PGBuild::conf{branches_to_build})
{
	@branches = @{ $PGBuild::conf{branches_to_build} };
}
elsif ($PGBuild::conf{branches_to_build} =~
	/^(ALL|HEAD_PLUS_LATEST|HEAD_PLUS_LATEST(\d))$/)
{

	my $latest = $2;

	# Need to set the path here so we make sure we pick up the right perl.
	# It has to be the perl that the build script would choose
	# i.e. specially *not* the MinGW SDK perl that is invoked for the
	# build script, which means we need to put the path back the way it was
	# when we're done
	my $save_path = $ENV{PATH};
	$ENV{PATH} = $PGBuild::conf{build_env}->{PATH}
	  if ($PGBuild::conf{build_env}->{PATH});
	(my $url = $PGBuild::conf{target}) =~ s/cgi-bin.*/branches_of_interest.txt/;
	my $branches_of_interest;
	## no critic (ValuesAndExpressions::ProhibitMismatchedOperators)
	# perlcritic gets confused by version comparisons - this usage is
	# sanctioned by perldoc perlvar
	if ($^O eq 'msys' && $^V lt v5.8.0)
	{
		# msys: use perl in PATH
		$branches_of_interest = `perl -MLWP::Simple -e "getprint(q{$url})"`;
	}
	else
	{
		# everyone else: use this perl
		# make sure we have https protocol support if it's required
		require LWP::Protocol::https if $url =~ /^https:/;
		$branches_of_interest = LWP::Simple::get($url);
	}
	die "getting branches of interest ($url)" unless $branches_of_interest;
	$ENV{PATH} = $save_path;
	push(@branches, $_) foreach (split(/\s+/, $branches_of_interest));
	splice(@branches, 0, -2)
	  if $PGBuild::conf{branches_to_build} eq 'HEAD_PLUS_LATEST';
	splice(@branches, 0, 0 - ($latest + 1))
	  if $PGBuild::conf{branches_to_build} =~ /^HEAD_PLUS_LATEST\d$/;
}

@branches = apply_throttle(@branches);

my $global_lock_dir =
     $PGBuild::conf{global_lock_dir}
  || $PGBuild::conf{build_root}
  || '';

unless ($global_lock_dir && -d $global_lock_dir)
{
	die "no global lock directory: $global_lock_dir";
}

# acquire the lock

my $lockfile;

my $lockfilename = "$global_lock_dir/GLOBAL.lck";

open($lockfile, ">", "$lockfilename") || die "opening lockfile: $!";

if (!flock($lockfile, LOCK_EX | LOCK_NB))
{
	print "Another process holds the lock on " . "$lockfilename. Exiting.\n"
	  if ($verbose);
	exit(0);
}

if ($run_all)
{
	foreach my $brnch (@branches)
	{
		run_branch($brnch);
	}
}
elsif ($run_one)
{

	# sort the branches by the order in which they last did actual work
	# then try running them in that order until one does some work

	%branch_last = map { $_ => find_last_status($_) } @branches;
	foreach my $brnch (sort branch_last_sort @branches)
	{
		run_branch($brnch);
		my $new_status = find_last_status($brnch);
		last if $new_status != $branch_last{$brnch};
	}
}

# clean up the lockfile when we're done.
close $lockfile;
unlink $lockfilename;

exit 0;

##########################################################

sub run_branch
{
	my $branch = shift;
	my @args = ($run_build, PGBuild::Options::standard_option_list(), $branch);

	# Explicitly use perl from the path (and not this perl, so don't use $^X)
	# This script needs to run on Cygwin with non-cygwin perl if it's running
	# in tandem with AS/MinGW perl, since Cygwin perl doesn't honor locks
	# the samne way, and the global lock fails. But the build script needs
	# to run with the native perl, even on Cygwin, which it picks up from
	# the path. (Head exploding yet?).
	system("perl", @args);
	return;
}

sub branch_last_sort
{
	return $branch_last{$a} <=> $branch_last{$b};
}

sub find_last_status
{
	my $brnch = shift;
	my $status_file =
	  "$PGBuild::conf{build_root}/$brnch/$PGBuild::conf{animal}.last.status";
	return 0 unless (-e $status_file);
	my $ts = file_contents($status_file);
	chomp $ts;
	return $ts + 0;
}

sub apply_throttle
{
	my @thrbranches = @_;
	return @thrbranches unless exists $PGBuild::conf{throttle};
	my @result;
	my %throttle = %{ $PGBuild::conf{throttle} };

	# implement throttle keywords ALL !HEAD and !RECENT
	my @candidates;
	my $replacement;
	if (exists $throttle{ALL})
	{
		@candidates  = @thrbranches;
		$replacement = $throttle{ALL};
	}
	elsif (exists $throttle{'!HEAD'})
	{
		@candidates = grep { $_ ne 'HEAD' } @thrbranches;
		$replacement = $throttle{'!HEAD'};
	}
	elsif (exists $throttle{'!RECENT'})
	{

		# sort branches, make sure we get numeric major version sorting right
		my @stable = grep { $_ ne 'HEAD' } @thrbranches;
		s/^REL(\d)_/0$1/ foreach (@stable);
		@stable = sort @stable;
		s/^REL0/REL/ foreach (@stable);
		pop @stable;    # remove latest
		@candidates  = @stable;
		$replacement = $throttle{'!RECENT'};
	}
	foreach my $cand (@candidates)
	{

		# only supply this for the branch if there isn't already
		# a throttle
		$throttle{$cand} ||= $replacement;
	}

	# apply throttle filters
	foreach my $branch (@thrbranches)
	{
		my $this_throttle = $throttle{$branch};
		unless (defined $this_throttle)
		{
			push(@result, $branch);
			next;
		}
		my $minh = $this_throttle->{min_hours_since};
		my $ts   = find_last_status($branch);
		next
		  if ( $ts
			&& (defined $minh)
			&& ($minh && $minh < ((time - $ts) / 3600.0)));
		if (exists $this_throttle->{allowed_hours})
		{
			my @allowed_hours = split(/,/, $this_throttle->{allowed_hours});
			my $hour = (localtime(time))[2];
			next unless grep { $_ == $hour } @allowed_hours;
		}
		push(@result, $branch);
	}

	return @result;
}
