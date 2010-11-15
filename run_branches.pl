#!/usr/bin/perl

use vars qw($VERSION); $VERSION = 'REL_0.0';

use strict;
use warnings;
use Fcntl qw(:flock :seek);
use PGBuild::Options;
use File::Basename;

my %branch_last;
sub branch_last_sort;

my $run_build;
($run_build = $0) =~ s/run_branches/run_build/;


my($run_all, $run_one);
my %extra_options = 
  (
   'run-all' => \$run_all,
   'run-one' => \$run_one,
   );

# process the command line
PGBuild::Options::fetch_options(%extra_options);

# no non-option args allowed here
die ("$0: non-option arguments not permitted")
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
require $buildconf ;

unless (ref $PGBuild::conf{branches_to_build} eq 'ARRAY' && 
		@{$PGBuild::conf{branches_to_build}})
{
	die "no branches_to_build specified in $buildconf";
}

my @branches = @{$PGBuild::conf{branches_to_build}};

my $global_lock_dir = 
  $PGBuild::conf{global_lock_dir} ||
  $PGBuild::conf{build_root} ||
  '';
  ;

unless ($global_lock_dir && -d $global_lock_dir)
{
	die "no global lock directory: $global_lock_dir"
}

# acquire the lock

my $lockfile;

my $lockfilename = "$global_lock_dir/GLOBAL.lck";

open($lockfile, ">$lockfilename") || die "opening lockfile: $!";

if ( ! flock($lockfile,LOCK_EX|LOCK_NB) )
{
	print "Another process holds the lock on " .
		"$lockfilename. Exiting."
		if ($verbose);
	exit(0);
}

if ($run_all)
{
	foreach my $brnch(@branches)
	{
		run_branch($brnch);
	}
}
elsif ($run_one)
{
	# sort the branches by the order in which they last did actual work
	# then try running them in that order until one does some work

	%branch_last = map {$_ => find_last_status($_)} @branches;
	foreach my $brnch(sort branch_last_sort @branches)
	{
		run_branch($brnch);
		my $new_status = find_last_status($brnch);
		last if $new_status != $branch_last{$brnch};
	}
}


exit 0;

##########################################################



sub run_branch
{
	my $branch = shift;
	my @args = ($run_build, 
				PGBuild::Options::standard_option_list(), $branch);
	system(@args);
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
	return 0 unless (-e  $status_file);
	my $handle;
	open($handle,$status_file) || dir $!;
	my $ts = <$handle>;
	chomp $ts;
	close($handle);
	return $ts + 0;
}
