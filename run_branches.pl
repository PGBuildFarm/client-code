#!/usr/bin/perl

=comment

Copyright (c) 2003-2022, Andrew Dunstan

See accompanying License file for license details

=cut

use strict;
use warnings;

our ($VERSION); $VERSION = 'REL_17';

# minimum version supported
use v5.14;    ## no critic (ProhibitVersionStrings)

use Fcntl qw(:flock :seek);
use File::Spec;
use File::Basename;
use File::Path;
use Cwd qw(abs_path getcwd);
use POSIX ':sys_wait_h';
use JSON::PP;
use LWP::UserAgent;

use FindBin;
use lib $FindBin::RealBin;

BEGIN
{
	unshift(@INC, $ENV{BFLIB}) if $ENV{BFLIB};
}

my $now = time;

my $orig_dir = getcwd();
unshift @INC, $orig_dir;

use PGBuild::Options;
use PGBuild::Utils qw(:DEFAULT $send_result_routine
  $st_prefix $logdirname $branch_root);
use PGBuild::SCM;

$send_result_routine = \&send_res;

my %branch_last;
sub branch_last_sort;

my $run_build;
($run_build = $0) =~ s/run_branches/run_build/;

my ($run_all, $run_one, $run_parallel, $check_for_work) = (0, 0, 0, 0);
my %extra_options = (
	'run-all' => \$run_all,
	'run-one' => \$run_one,
	'run-parallel' => \$run_parallel,
	'check-for-work' => \$check_for_work,
);

# process the command line
PGBuild::Options::fetch_options(%extra_options);

# any arguments left are explicit branches
my $explicit_branches = [@ARGV];

my $mode_sum = ($run_all + $run_one + $run_parallel + $check_for_work);
my $mode_string = "--run-all, --run-one, --run_parallel, --check-for-work";
if ($mode_sum > 1)
{
	die "only one of $mode_string permitted";
}
elsif (!$mode_sum)
{
	die "need one of $mode_string";
}

# set up a "branch" variable for processing the config file
our ($branch);
$branch = 'global';

#
# process config file
#
require $buildconf;

PGBuild::Options::fixup_conf(\%PGBuild::conf, \@config_set);

my $animal = $PGBuild::conf{animal};

die "from-source cannot be used with run_branches,pl"
  if ($from_source || $from_source_clean);


my $buildroot = $PGBuild::conf{build_root}
  || abs_path(dirname(__FILE__)) . "/buildroot";
my $using_msvc = $PGBuild::conf{using_msvc};

exit 0 if -e "$buildroot/$animal.inhibit-runs";

die "no buildroot" unless $buildroot;

unless ($buildroot =~ m!^/!
	or ($using_msvc and $buildroot =~ m![a-z]:[/\\]!i))
{
	die "buildroot $buildroot not absolute";
}

my $here = getcwd();

mkpath $buildroot unless -d $buildroot;

die "$buildroot does not exist or is not a directory" unless -d $buildroot;

my $global_lock_dir = $PGBuild::conf{global}->{global_lock_dir}
  || $PGBuild::conf{global_lock_dir}    # legacy support
  || $PGBuild::conf{build_root}         # default
  || '';

unless ($global_lock_dir && -d $global_lock_dir)
{
	die "no global lock directory: $global_lock_dir";
}

# acquire the lock

my $lockfile;

my $lockfilename = "$global_lock_dir/GLOBAL.lck";

unless ($check_for_work)
{
	# no lock needed if we're not going to do anything
	open($lockfile, ">", "$lockfilename") || die "opening lockfile: $!";

	if (!flock($lockfile, LOCK_EX | LOCK_NB))
	{
		print "Another process holds the lock on "
		  . "$lockfilename. Exiting.\n"
		  if ($verbose > 1);
		exit(0);
	}
}

my $branches_to_build = $PGBuild::conf{global}->{branches_to_build}
  || $PGBuild::conf{branches_to_build};    # legacy support

# override with explicit branches if there are any
$branches_to_build = $explicit_branches if @{$explicit_branches};

unless (((ref $branches_to_build) eq 'ARRAY' && @{$branches_to_build})
	|| (ref $branches_to_build) =~ /Regexp/i
	|| $branches_to_build =~ /^(ALL|OLD|STABLE|HEAD_PLUS_LATEST(\d?))$/)
{
	die "no branches_to_build specified in $buildconf";
}

if (-e "$buildroot/$animal.force-one-run" && !$check_for_work)
{
	$PGBuild::Options::forcerun = 1;
	unlink "$buildroot/$animal.force-one-run";
}

my %branch_gitrefs;
my @branches;
if ((ref $branches_to_build) eq 'ARRAY')
{
	@branches = @{$branches_to_build};
	$ENV{BF_CONF_BRANCHES} = join(',', @branches);

	# here we don't set the branches from the branches_of_interest but we
	# fetch it (unless told not to) so we can filter using that data.
	get_branches_of_interest('CURRENT')
	  unless $PGBuild::conf{global}->{no_precheck};
}
elsif ((ref $branches_to_build) =~ /Regexp/i)
{
	die "Can't check for work with regexp branches_to_build"
	  if ($check_for_work);
	chdir $buildroot || die "chdir to $buildroot: $!";
	mkdir 'HEAD' unless -d 'HEAD';
	chdir 'HEAD' || die "chdir to HEAD: $!";
	$branch_root = getcwd();
	$st_prefix = "$animal.";
	$logdirname = "lastrun-logs";
	my $scm = PGBuild::SCM->new(\%PGBuild::conf);
	my $savescmlog = $scm->checkout('HEAD');
	$scm->rm_worktree();    # don't need the worktree here
	my @cbranches = $scm->get_branches('remotes/origin/');
	@branches = grep { $_ =~ /$branches_to_build/ } @cbranches;
	$ENV{BF_CONF_BRANCHES} = join(',', "(found by regexp)", @branches);
	chdir $here;
}
elsif ($branches_to_build =~
	/^(ALL|STABLE|OLD|HEAD_PLUS_LATEST|HEAD_PLUS_LATEST(\d))$/)
{
	$ENV{BF_CONF_BRANCHES} = $branches_to_build;
	my $match = $1;
	my $latest = $2;

	@branches = get_branches_of_interest($match);

	# assumes that branches_of_interest is in order, oldest through to HEAD
	splice(@branches, 0, -2)
	  if $branches_to_build eq 'HEAD_PLUS_LATEST';
	splice(@branches, 0, 0 - ($latest + 1))
	  if $branches_to_build =~ /^HEAD_PLUS_LATEST\d$/;
	splice(@branches, -1)
	  if ($branches_to_build eq 'STABLE');
}

@branches = apply_filters(@branches);

if ($check_for_work)
{
	print(@branches ? "yes\n" : "no\n") if $verbose;
	exit(scalar(@branches) == 0);    # 1 = no work, 0 = work to do
}

if ($run_parallel)
{
	# TestSepgsql uses shared resources in multiple phases, so making it
	# parallel-safe is hard. For now just disallow it.
	my $has_sepgsql = grep { $_ eq 'TestSepgsql' } @{ $PGBuild::conf{modules} };
	if ($has_sepgsql)
	{
		print STDERR "cannot run in parallel mode with TestSepgsql module.";
		exit 1;
	}
	run_parallel(@branches);
}
elsif ($run_all)
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

sub get_branches_of_interest
{
	my $which = shift;

	# Need to set the path here so we make sure we pick up the right perl.
	# It has to be the perl that the build script would choose
	# i.e. specially *not* the MinGW SDK perl that is invoked for the
	# build script, which means we need to put the path back the way it was
	# when we're done
	my $save_path = $ENV{PATH};
	$ENV{PATH} = $PGBuild::conf{build_env}->{PATH}
	  if ($PGBuild::conf{build_env}->{PATH});
	(my $url = $PGBuild::conf{target}) =~
	  s/cgi-bin.*/branches_of_interest.json/;
	$url =~ s/branches_of_interest/old_branches_of_interest/
	  if $which eq 'OLD';
	my $branches_of_interest;

	my $have_msys_https = $url !~ /^https:/;  # if not needed, assume it's there

	if ($^O eq 'msys' && !$have_msys_https)
	{
		eval { require LWP::Protocol::https; };
		$have_msys_https = 1 unless $@;
	}
	if ($^O eq 'msys' && !$have_msys_https)
	{
		# msys: use perl in PATH if necessary
		$branches_of_interest = `perl -MLWP::Simple -e "getprint(q{$url})"`;
	}
	else
	{
		# everyone else: use this perl
		# make sure we have https protocol support if it's required
		require LWP::Protocol::https if $url =~ /^https:/;
		my $ua = LWP::UserAgent->new;
		$ua->agent("Postgres Build Farm Reporter");
		if (my $proxy = $ENV{BF_PROXY})
		{
			my $targetURI = URI->new($url);
			$ua->proxy($targetURI->scheme, $proxy);
		}
		my $response = $ua->get($url);
		if ($response->is_success)
		{
			$branches_of_interest = $response->decoded_content;
		}
		else
		{
			print STDERR "error getting branches of interest: ";
			die $response->status_line;
		}
	}
	die "getting branches of interest ($url)" unless $branches_of_interest;
	$ENV{PATH} = $save_path;

	my $gitrefs = decode_json($branches_of_interest);

	my @fbranches;
	foreach my $gr (@$gitrefs)
	{
		my ($br, $ref) = each %$gr;
		push(@fbranches, $br);
		$branch_gitrefs{$br} = $ref;
	}
	return @fbranches;
}

sub check_max
{
	my $plockdir = shift;
	my $max = shift;
	my $running = 0;

	# grab the global parallel lock. Wait if necessary
	# only keep this for a very short time, just enough
	# to prevent a race condition
	open(my $glock, ">", "$plockdir/parallel_global_lock.LCK") || die "$!";
	if (!flock($glock, LOCK_EX))
	{
		print STDERR "Unable to get global parallel lock. Exiting.\n";
		exit(1);
	}

	# get a list of the running lock files, and check if they are
	# still locked. remove any that aren't.
	my @running_locks = glob("$plockdir/*.running.LCK");
	foreach my $rlock (@running_locks)
	{
		open(my $frlock, ">", $rlock) || die "$!";
		if (!flock($frlock, LOCK_EX | LOCK_NB))
		{
			# getting the lock failed, so it's still running
			$running++;
			close($frlock);
		}
		else
		{
			# we got the lock, so the process must have exited.
			close($frlock);
			unlink($rlock);
		}
	}

	# release the global lock
	close($glock);

	return $running < $max;
}

sub parallel_child
{
	my $plockdir = shift;
	my $brnch = shift;

	# grab the global parallel lock. Wait if necessary
	# only keep this for a very short time, just enough
	# to prevent a race condition
	open(my $glock, ">", "$plockdir/parallel_global_lock.LCK") || die "$!";
	if (!flock($glock, LOCK_EX))
	{
		print STDERR "Unable to get global parallel lock. Exiting.\n";
		exit(1);
	}

	# the running lock will be released when the child exits;
	open(my $plock, ">", "$plockdir/$animal.$brnch.running.LCK")
	  || die "opening parallel running lock for $animal:$brnch";
	if (!flock($plock, LOCK_EX | LOCK_NB))
	{
		print STDERR "Unable to get parallel running lock. Exiting.\n";
		exit(1);
	}

	# release the global lock
	close($glock);
	return run_branch($brnch);
}

sub run_parallel
{
	my @pbranches = @_;
	my $plockdir = $PGBuild::conf{global}->{parallel_lock_dir}
	  || $global_lock_dir;
	my $stagger_time = $PGBuild::conf{global}->{parallel_stagger};
	$stagger_time ||= 60;

	# things could look weird unless the animals all agree on this number
	my $max_parallel = $PGBuild::conf{global}->{max_parallel};
	$max_parallel ||= 10;
	while (@pbranches)
	{
		if (check_max($plockdir, $max_parallel))
		{
			my $brnch = shift @pbranches;
			spawn(\&parallel_child, $plockdir, $brnch);
		}

		# no need to do more if there are no more branches
		# needing to be launched.
		last unless @pbranches;

		# sleep at least 2 secs between spawns. This helps ensure each
		# child has a different snapshot time.

		sleep 2;

		# sleep remaining $stagger_time secs unless a child exits
		# in the meantime.
		foreach (3 .. $stagger_time)
		{
			# 0 == there are children and none have exited
			# per perldoc -f waitpid
			last unless waitpid(-1, WNOHANG) == 0;
			sleep 1;
		}
	}

	# reap remaining children
	sleep 1 while (wait != -1);
	return;
}

sub run_branch
{
	my $brnch = shift;

	my @args = ($run_build, PGBuild::Options::standard_option_list(), $brnch);

	# On cygwin, explicitly use perl from the path (and not this perl,
	# so don't use $^X)
	# This script needs to run on Cygwin with non-cygwin perl if it's running
	# in tandem with AS/MinGW perl, since Cygwin perl doesn't honor locks
	# the same way, and the global lock fails. But the build script needs
	# to run with the native perl, even on Cygwin, which it picks up from
	# the path. (Head exploding yet?).
	#
	# So if the perl in the path is cygwin perl, we use that, otherwise we use
	# this perl.

	my $pathperlinfo = qx(perl -v 2>&1);
	my $runperl = $pathperlinfo =~ /cygwin/ ? "perl" : $^X;

	system($runperl, @args);
	return $? >> 8;
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

sub apply_filters
{
	my @filt_branches = @_;
	my @thrbranches;

	# remove up to date branches unless they are forced
	foreach my $brnch (@filt_branches)
	{
		my $gitref = $branch_gitrefs{$brnch};
		my $up_to_date = 0;
		my $force_every = $PGBuild::conf{force_every};
		if (ref($force_every) eq 'HASH')
		{
			$force_every = $force_every->{$brnch} || $force_every->{default};
		}
		if ($force_every)
		{
			my $ts = find_last_status($brnch);
			if ($ts + ($force_every * 3600) < $now)
			{
				push(@thrbranches, $brnch);
				next;
			}
		}

		if (   $gitref
			&& -e "$buildroot/$brnch/$animal.lastrun-logs/githead.log"
			&& !$PGBuild::Options::forcerun
			&& !-e "$buildroot/$brnch/$animal.force-one-run")
		{
			# skip the run if the last thing we built is what the server says is
			# is the latest commit.
			my $last_gitref =
			  file_contents(
				"$buildroot/$brnch/$animal.lastrun-logs/githead.log");
			if (index($last_gitref, $gitref) == 0)
			{
				print
				  "@{[scalar(localtime())]}: $animal:$brnch is up to date.\n"
				  if ($verbose && !$check_for_work);
				$up_to_date = 1;
			}
		}
		push(@thrbranches, $brnch) unless $up_to_date;
	}

	# apply a throttle if configured
	return @thrbranches unless exists $PGBuild::conf{throttle};
	my @result;
	my %throttle = %{ $PGBuild::conf{throttle} };

	# implement throttle keywords ALL !HEAD and !RECENT
	my @candidates;
	my $replacement;
	if (exists $throttle{ALL})
	{
		@candidates = @thrbranches;
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
		@candidates = @stable;
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
		my $ts = find_last_status($branch);
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


sub send_res
{
	# error routine catch - we don't actually send anything here
	my $stage = shift;
	my $status = shift || 0;
	my $log = shift || [];
	print "======== log passed to send_result ===========\n", @$log
	  if ($verbose > 1);
	print
	  "Buildfarm member $animal failed in run_branches.pl at stage $stage\n";
	exit(1);
}
