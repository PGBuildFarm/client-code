#!/usr/bin/perl

####################################################
=comment

 NAME: run_build.pl - script to run postgresql buildfarm

 SYNOPSIS:

  run_build.pl [--nosend] [branchname]

 AUTHOR: Andrew Dunstan

 TODO:
  . collect more log data for installcheck runs

 FUTURE:
  . possibly get dumps via rsync instead of via
    cvs export/update, to save bandwidth (and 
    processor overhead)

 USAGE:

   To upload results, you will need a name/secret
   to put into the config file. Test runs without
   uploading results can be done using the --nosend 
   commandline flag.

   Install this file and build-farm.conf in some
   directory together. Edit build-farm.conf to match
   your setup. Create the buildroot directory.
   Run "perl -cw build-farm.conf" to make sure it
   is OK. Run "perl -cw run_build.pl" to make sure
   you have all the required perl modules. Make a
   test run in the foreground (can take up to an hour
   on a slow machine). Add cron entries that look
   like this:

   # check HEAD branch once an hour
   32 * * * * cd /path/to/script && ./run_build.pl 
   # check REL7_4_STABLE branch once a week
   18 3 * * 3 cd /path/to/script && ./run_build.pl REL7_4_STABLE

   There is provision in the conf file for support of 
   ccache. This is highly recommended.

=cut
###################################################

# $Id: run_build.pl,v 1.11 2004/11/13 20:17:55 andrewd Exp $

use strict;
use LWP;
use HTTP::Request::Common;
use MIME::Base64;
use Digest::SHA1  qw(sha1_hex);
use Fcntl qw(:flock);
use Getopt::Long;
use POSIX qw(:signal_h);

use File::Find ();
use vars qw/*name *dir *prune/;
*name   = *File::Find::name;
*dir    = *File::Find::dir;
*prune  = *File::Find::prune;

# make sure we exit nicely on any normal interrupt
# so the cleanup handler gets called.
# that lets us stop the db if it's running and 
# remove the inst and pgsql directories
# so the next run can start clean.

foreach my $sig (qw(INT TERM HUP QUIT))
{
	$SIG{$sig}=\&interrupt_exit;
}

#
# process command line
#
my $nosend;
my $forcerun;
my $buildconf = "build-farm.conf"; # default value
my $keepall;
my $nostatus;
my $verbose;
my $help;

GetOptions('nosend' => \$nosend, 
		   'config=s' => \$buildconf,
		   'force' => \$forcerun,
		   'keepall' => \$keepall,
		   'verbose:i' => \$verbose,
		   'nostatus' => \$nostatus,
		   'help' => \$help);

$verbose=1 if (defined($verbose) && $verbose==0);

use vars qw($branch);
$branch = shift || 'HEAD';

print_help() if ($help);

#
# process config file
#
require $buildconf ;

# get the config data into some local variables
my ($buildroot,$target,$animal, $print_success,
	$secret, $keep_errs, $force_every, $make, $cvs_timeout_secs) = 
	@PGBuild::conf{
		qw(build_root target animal print_success
		   secret keep_error_builds force_every make cvs_timeout_secs)
		};
my @config_opts = @{$PGBuild::conf{config_opts}};
my $cvsserver = $PGBuild::conf{cvsrepo} ||
	":pserver:anoncvs\@anoncvs.postgresql.org:2401/projects/cvsroot";
my $buildport = $PGBuild::conf{branch_ports}->{$branch} || 5999;

my $cvsmethod = $PGBuild::conf{cvsmethod} || 'export';


my $pgsql = $cvsmethod eq 'export' ? "pgsql" : "pgsql.$$";

# set environment from config
while (my ($envkey,$envval) = each %{$PGBuild::conf{build_env}})
{
	$ENV{$envkey}=$envval;
}

# change to buildroot for this branch or die

die "no buildroot" unless $buildroot;

die "buildroot $buildroot not absolute" unless $buildroot =~ m!^/! ;

die "$buildroot does not exist or is not a directory" unless -d $buildroot;

chdir $buildroot || die "chdir to $buildroot: $!";

mkdir $branch unless -d $branch;

chdir $branch || die "chdir to $buildroot/$branch";

# make sure we are using GNU make

die "$make is not GNU Make - please fix config file" unless check_make();

# acquire the lock

my $lockfile;
my $have_lock;

open($lockfile, ">builder.LCK") || die "opening lockfile: $!";

# only one builder at a time allowed per branch
exit(0) unless flock($lockfile,LOCK_EX|LOCK_NB);

die "$buildroot/$branch has $pgsql or inst directories!" 
	if (-d $pgsql || -d "inst");

# we are OK to run if we get here
$have_lock = 1;

# the time we take the snapshot
my $now=time;
my $installdir = "$buildroot/$branch/inst";
my $dbstarted;

# cleanup handler for all exits
END
{
	# if we have the lock we must already be in the build root, so
	# removing things should be safe.
	# there should only be anything to cleanup if we didn't have
	# success.
	if ( $have_lock && -d "$pgsql")
	{
		if ($keep_errs) 
		{ 
			system("mv $pgsql pgsqlkeep.$now") ;
		}
		if ($dbstarted)
		{
			system ("cd inst && bin/pg_ctl -D data stop >/dev/null 2>&1");
		}
		system("rm -rf $pgsql inst") unless $keepall;
	}
	if ($have_lock)
	{
		close($lockfile);
		unlink("builder.LCK");
	}
}



# see if we need to run the tests (i.e. if either something has changed or
# we have gone over the force_every heartbeat time)

print "checking out source ...\n" if $verbose;


my $timeout_pid;

$timeout_pid = spawn(\&cvs_timeout,$cvs_timeout_secs) 
	if $cvs_timeout_secs; 


checkout();

if ($timeout_pid)
{
    # don't kill me, I finished in time
	if (kill (SIGTERM, $timeout_pid))
	{
		# reap the zombie
		waitpid($timeout_pid,0); 
	}
}

print "checking if build run needed ...\n" if $verbose;

my @changed_files;
my @changed_since_success;

my $last_status = find_last('status') || 0;
my $last_success = find_last('success');

# see if we need to force a build
$last_status = 0
	if ($last_status && $force_every && 
		$last_status+($force_every*3600) < $now);
$last_status = 0 if $forcerun;


# see what's changed since the last time we did work
File::Find::find({wanted => \&find_changed}, 'pgsql') if $last_status;

# if no build required do nothing
if ($last_status && ! @changed_files)
{
	system("rm -rf $pgsql");
	exit 0;
}

cleanlogs();

# copy over if using update method

if ($cvsmethod eq 'update')
{
	print "copying source to $pgsql ...\n" if $verbose;

	system("cp -r pgsql $pgsql 2>&1");
	my $status = $? >> 8;
	die "copying directories: $status" if $status;
}

# start working

set_last('status') unless $nostatus;

my $started_times = 0;

# each of these routines will call send_result, which calls exit,
# on any error, so each step depends on success in the previous
# steps.

print "running configure ...\n" if $verbose;

configure();

print "running make ...\n" if $verbose;

make();

print "running make check ...\n" if $verbose;

make_check();

print "running make contrib ...\n" if $verbose;

make_contrib();

print "running make install ...\n" if $verbose;

make_install();

print "setting up db cluster ...\n" if $verbose;

initdb();

print "starting db ...\n" if $verbose;

start_db();

print "running make installcheck ...\n" if $verbose;

make_install_check();

# restart the db to clear the log file
print "restarting db ...\n" if $verbose;

stop_db();
start_db();

print "running make contrib install ...\n" if $verbose;

make_contrib_install();

print "running make contrib installcheck ...\n" if $verbose;

make_contrib_install_check();

print "stopping db ...\n" if $verbose;

stop_db();


# if we get here everything went fine ...

my $saved_config = get_config_summary();

system("rm -rf $pgsql inst"); # only keep failures

print("OK\n") if $verbose;

send_result("OK");

exit;

############## end of main program ###########################

sub print_help
{
	print qq!
usage: $0 [options] [branch]

 where options are one or more of:

  --nosend                = don't send results
  --nostatus              = don't set last.status file
  --force                 = force a build run
  --config=/path/to/file  = alternative location for config file
  --keepall               = keep directories if an error occurs
  --verbose[=n]           = verbosity (default 1) 2 or more = huge output.

Default branch is HEAD. Except for debugging purposes, you should only need
to use the --config option.

!;
	exit(0);
}

sub interrupt_exit
{
	my $signame = shift;
	print "Exiting on signal $signame\n";
	exit(1);
}


sub cleanlogs
{
	system("rm -rf lastrun-logs");
	mkdir "lastrun-logs" || die "can't make lastrun-logs dir: $!";
}

sub writelog
{
	my $stage = shift;
	my $loglines = shift;
	my $handle;
	open($handle,">lastrun-logs/$stage.log");
	print $handle @$loglines;
	close($handle);
}

sub check_make
{
	my @out = `$make -v 2>&1`;
	return undef unless ($? == 0 && grep {/GNU Make/} @out);
	return 'OK';
}


sub make
{
	my @makeout = `cd $pgsql && $make 2>&1`;
	my $status = $? >>8;
	writelog('make',\@makeout);
	print "======== make log ===========\n",@makeout if ($verbose > 1);
	send_result('Make',$status,\@makeout) if $status;
}

sub make_install
{
	my @makeout = `cd $pgsql && $make install 2>&1`;
	my $status = $? >>8;
	writelog('make-install',\@makeout);
	print "======== make install log ===========\n",@makeout if ($verbose > 1);
	send_result('Install',$status,\@makeout) if $status;

	# On Windows and Cygwin avoid path problems associated with DLLs
	# by copying them to the bin dir where the system will pick them
	# up regardless.
	foreach my $dll (glob("$installdir/lib/*pq.dll"))
	{
		system("cp $dll $installdir/bin");
	}
}

sub make_contrib
{
	my @makeout = `cd $pgsql/contrib && $make 2>&1`;
	my $status = $? >>8;
	writelog('make-contrib',\@makeout);
	print "======== make contrib log ===========\n",@makeout if ($verbose > 1);
	send_result('Contrib',$status,\@makeout) if $status;
}

sub make_contrib_install
{
	my @makeout = `cd $pgsql/contrib && $make install 2>&1`;
	my $status = $? >>8;
	writelog('install-contrib',\@makeout);
	print "======== make contrib install log ===========\n",@makeout 
		if ($verbose > 1);
	send_result('ContribInstall',$status,\@makeout) if $status;
}

sub initdb
{
	my @initout = `cd $installdir && bin/initdb data 2>&1`;
	my $status = $? >>8;
	writelog('initdb',\@initout);
	print "======== initdb log ===========\n",@initout if ($verbose > 1);
	send_result('Initdb',$status,\@initout) if $status;
}

sub start_db
{
	$started_times++;
	# must use -w here or we get horrid FATAL errors from trying to
	# connect before the db is ready
	# clear log file each time we start
	my $cmd = "cd $installdir && rm -f logfile && ".
		"bin/pg_ctl -D data -l logfile -w start 2>&1";
	my @ctlout = `$cmd`;
	my $status = $? >>8;
	writelog("startdb-$started_times",\@ctlout);
	print "======== start db : $started_times log ===========\n",@ctlout 
		if ($verbose > 1);
	send_result("StartDb:$started_times",$status,\@ctlout) if $status;
	$dbstarted=1;
}

sub stop_db
{
	my @ctlout = `cd $installdir && bin/pg_ctl -D data stop 2>&1`;
	my $status = $? >>8;
	writelog("stopdb-$started_times",\@ctlout);
	print "======== stop db : $started_times log ===========\n",@ctlout 
		if ($verbose > 1);
	send_result("StopDb:$started_times",$status,\@ctlout) if $status;
	$dbstarted=undef;
}

sub make_install_check
{
	my @checkout = `cd $pgsql/src/test/regress && $make installcheck 2>&1`;
	my $status = $? >>8;
	my @logfiles = ("$pgsql/src/test/regress/regression.diffs",
					"$installdir/logfile");
	foreach my $logfile(@logfiles)
	{
		next unless (-e $logfile );
		push(@checkout,
			 "\n\n================== $logfile ==================\n");
		my $handle;
		open($handle,$logfile);
		while(<$handle>)
		{
			push(@checkout,$_);
		}
		close($handle);	
	}
	writelog('install-check',\@checkout);
	print "======== make installcheck log ===========\n",@checkout 
		if ($verbose > 1);
	send_result('InstallCheck',$status,\@checkout) if $status;	
}

sub make_contrib_install_check
{
	my @checkout = `cd $pgsql/contrib && $make installcheck 2>&1`;
	my $status = $? >>8;
	my @logs = glob ("$pgsql/contrib/*/regression.diffs");
	push (@logs,"$installdir/logfile");
	foreach my $logfile (@logs)
	{
		next unless (-e $logfile);
		push(@checkout,"\n\n================= $logfile ===================\n");
		my $handle;
		open($handle,$logfile);
		while(<$handle>)
		{
			push(@checkout,$_);
		}
		close($handle);
	}
	writelog('contrib-install-check',\@checkout);
	print "======== make contrib installcheck log ===========\n",@checkout 
		if ($verbose > 1);
	send_result('ContribCheck',$status,\@checkout) if $status;
}

sub make_check
{
	my @makeout = `cd $pgsql/src/test/regress && $make check 2>&1`;
	my $status = $? >>8;

	# get the log files and the regression diffs
	my @logs = glob("$pgsql/src/test/regress/log/*.log");
	unshift(@logs,"$pgsql/src/test/regress/regression.diffs")
		if (-e "$pgsql/src/test/regress/regression.diffs");
	foreach my $logfile (@logs)
	{
		push(@makeout,"\n\n================== $logfile ===================\n");
		my $handle;
		open($handle,$logfile);
		while(<$handle>)
		{
			push(@makeout,$_);
		}
		close($handle);
	}
	writelog('check',\@makeout);
	print "======== make check logs ===========\n",@makeout 
		if ($verbose > 1);

	send_result('Check',$status,\@makeout) if $status;
}

sub configure
{

	my $confstr = join(" ",@config_opts,
					   "--prefix=$installdir",
					   "--with-pgport=$buildport");

	my $env = $PGBuild::conf{config_env};

	my $envstr = "";
	while (my ($key,$val) = each %$env)
	{
		$envstr .= "$key='$val' ";
	}
	
	my @confout = `cd $pgsql && $envstr ./configure $confstr 2>&1`;
	
	my $status = $? >> 8;

	print "======== configure output ===========\n",@confout 
		if ($verbose > 1);

	writelog('configure',\@confout) unless $status;

	return unless $status;

	my $handle;

	if (open($handle,"$pgsql/config.log"))
	{
		push(@confout,"\n\n================= config.log ================\n\n");
		while(<$handle>)
		{
			push(@confout,$_);
		}
		close($handle);
	}
	
	writelog('configure',\@confout);

	send_result('Configure',$status,\@confout);
	
}


sub find_changed 
{
	# skip CVS dirs if using update
	if ($cvsmethod eq 'update' && $_ eq 'CVS' && -d $_)
	{
		$File::Find::prune = 1;
	}
	else
	{
		my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,
        $size,$atime,$mtime,$ctime,$blksize,$blocks) = lstat($_);

		if (-f _)
		{
			  if ($mtime > $last_status)
			  {
				  push(@changed_files,$name);
			  }
			  elsif ($last_success && $mtime > $last_success)
			  {
				  push(@changed_since_success,$name);
			  }
		  }
		
	}
}


sub checkout
{
	my @cvslog;
	# cvs occasionally does weird things when given an explicit HEAD
	# especially on checkout or update.
	# since it's the default anyway, we omit it.
	my $rtag = $branch eq 'HEAD' ? "" : "-r $branch";
	if ($cvsmethod eq 'export')
	{
		# but you have to have a tag for export
		@cvslog = `cvs -d  $cvsserver export -r $branch pgsql 2>&1`;
	}
	elsif (-d 'pgsql')
	{
		@cvslog = `cd pgsql && cvs -d $cvsserver update -d -P $rtag 2>&1`;
	}
	else
	{
		@cvslog = `cvs -d $cvsserver co -P $rtag pgsql 2>&1`;
	}
	my $status = $? >>8;
	print "======== cvs $cvsmethod log ===========\n",@cvslog
		if ($verbose > 1);
	# can't call writelog here because we call cleanlogs after the
	# cvs stage, since we only clear out the logs if we find we need to
	# do a build run.
	# consequence - we don't save the cvs log
	# doesn't matter too much because if CVS fails we exit anyway.
	send_result('CVS',$status,\@cvslog)	if ($status);
}

sub find_last
{
	my $which = shift;
	my $handle;
	open($handle,"last.$which") or return undef;
	my $time = <$handle>;
	close($handle);
	chomp $time;
	return $time + 0;
}

sub set_last
{
	my $which = shift;
	my $st_now = shift || time;
	my $handle;
	open($handle,">last.$which") or die "opening last.$which: $!";
	print $handle "$st_now\n";
	close($handle);
}

sub send_result
{
	my $stage = shift;
	my $ts = $now || time;
	my $status=shift || 0;
	my $log = shift || [];
	print "======== log passed to send_result ===========\n",@$log
		if ($verbose > 1);
	
	my $log_data = encode_base64(join("",@$log),"");
	my $confsum = "" ;
	my $changed_this_run = "";
	my $changed_since_success = "";
	$changed_this_run = encode_base64(join("!",@changed_files))
		if @changed_files;
	$changed_since_success = encode_base64(join("!",@changed_since_success)) 
		if ($stage ne 'OK' && @changed_since_success);
	if ($stage eq 'OK')
	{
		$confsum= encode_base64($saved_config,"");
	}
	elsif ($stage ne 'CVS')
	{
		$confsum = encode_base64(get_config_summary(),"");
	}

	# make the base64 data escape-proof; = is probably ok but no harm done
	# this ensures that what is seen at the other end is EXACTLY what we
	# see when we calculate the signature

	map 
	{ tr/+=/$@/ } 
	($log_data,$confsum,$changed_this_run,$changed_since_success);
	

    my $content = 
		"changed_files=$changed_this_run&".
		"changed_since_success=$changed_since_success&".
		"branch=$branch&res=$status&stage=$stage&animal=$animal&ts=$ts".
		"&log=$log_data&conf=$confsum";
	my $sig= sha1_hex($content,$secret);
	my $ua = new LWP::UserAgent;
	$ua->agent("Postgres Build Farm Reporter");
	my $request=HTTP::Request->new(POST => "$target/$sig");
    $request->content_type("application/x-www-form-urlencoded");
	$request->content($content);
	if ($nosend)
	{
		print "Branch: $branch\n";
		if ($stage eq 'OK')
		{
			print "All stages succeeded\n";
			set_last('success',$now) unless $nostatus;
		}
		else
		{
			print "Stage $stage failed with status $status\n";
		}
		exit(0);
	}
    my $response=$ua->request($request);
	unless ($response->is_success)
	{
		print 
			"Query for: stage=$stage&animal=$animal&ts=$ts\n",
			"Target: $target/$sig\n";
		print "Status Line: ",$response->status_line,"\n";
		print "Content: \n", $response->content,"\n" 
			if ($verbose && $response->content);
		exit 1;
	}
	print "Success!\n",$response->content 
		if $print_success;

	set_last('success',$now) if ($stage eq 'OK' && ! $nostatus);

	exit 0;
}

sub get_config_summary
{
	my $handle;
	my $config = "";
	open($handle,"$pgsql/config.log") || return undef;
	my $start = undef;
	while (<$handle>)
	{
		if (!$start && /created by PostgreSQL configure/)
		{
			$start=1;
			s/It was/This file was/;
		}
		next unless $start;
		last if /Core tests/;
		next if /^\#/;
		next if /= unknown/;
		# split up long configure line
		if (m!\$.*configure.*--with! && length > 70)
		{
			my $pos = index($_," ",70);
			substr($_,$pos+1,0,"\\\n        ") if ($pos > 0);
			$pos = index($_," ",140);
			substr($_,$pos+1,0,"\\\n        ") if ($pos > 0);
		}
		$config .= $_;
	}
	close($handle);
	return $config;
}

sub cvs_timeout
{
	my $wait_time = shift;
	my $who_to_kill = getpgrp(0);
	my $sig = SIGTERM;
	$sig = -$sig;
	print "waiting $wait_time secs to time out process $who_to_kill\n"
		if $verbose;
	foreach my $sig (qw(INT TERM HUP QUIT))
	{
		$SIG{$sig}='DEFAULT';
	}
	sleep($wait_time);
	$SIG{TERM} = 'IGNORE'; # so we don't kill ourself, we're exiting anyway
	 # kill the whole process group
	unless (kill $sig,$who_to_kill)
	{
		print "cvs timeout kill failed\n";
	}
}

sub spawn
{
    my $coderef = shift;
    my $pid = fork;
    if (defined($pid) && $pid == 0)
    {
        exit &$coderef(@_);
    }
    return $pid;
}
