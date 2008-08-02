#!/usr/bin/perl

####################################################
=comment

 NAME: run_build.pl - script to run postgresql buildfarm

 SYNOPSIS:

  run_build.pl [option ...] [branchname]

 AUTHOR: Andrew Dunstan

 USAGE:

   To upload results, you will need a name/secret
   to put into the config file. Test runs without
   uploading results can be done using the --nosend 
   commandline flag.

   Install this file, run_web_txn.pl and build-farm.conf in some
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

   For more extensive information, see docs and mailing list
   at the pgfoundry site: http://pgfoundry.org/projects/pgbuildfarm/

   See the results of our labors at 
   http://www.pgbuildfarm.org/cgi-bin/show_status.pl 

=cut
###################################################

my $VERSION = sprintf "%d.%d", 
	q$Id: run_build.pl,v 1.95 2008/08/02 18:02:06 andrewd Exp $
	=~ /(\d+)/g; 

use strict;
use warnings;
use Fcntl qw(:flock :seek);
use File::Path;
use File::Copy;
use File::Basename;
use File::Temp;
use IO::Handle;
use Getopt::Long;
use POSIX qw(:signal_h strftime);
use Data::Dumper;
use Cwd qw(abs_path getcwd);

use File::Find ();

# make sure we exit nicely on any normal interrupt
# so the cleanup handler gets called.
# that lets us stop the db if it's running and 
# remove the inst and pgsql directories
# so the next run can start clean.

foreach my $sig (qw(INT TERM HUP QUIT))
{
	$SIG{$sig}=\&interrupt_exit;
}

# copy command line before processing - so we can later report it
# unmunged

my @invocation_args = (@ARGV);


#
# process command line
#
my $nosend;
my $forcerun;
my $buildconf = "build-farm.conf"; # default value
my $keepall;
my $nostatus;
my $verbose;
my $ipcclean;
my $help;
my $multiroot;
my $quiet;
my $from_source;
my $from_source_clean;
my $testmode;
my $skip_steps;
my $find_typedefs;


GetOptions('nosend' => \$nosend, 
		   'config=s' => \$buildconf,
		   'from-source=s' => \$from_source,
		   'from-source-clean=s' => \$from_source_clean,
		   'force' => \$forcerun,
		   'find-typedefs' => \$find_typedefs,
		   'keepall' => \$keepall,
		   'ipcclean' => \$ipcclean,
		   'verbose:i' => \$verbose,
		   'nostatus' => \$nostatus,
		   'test' => \$testmode,
		   'help' => \$help,
		   'quiet' => \$quiet,
		   'skip-steps=s' => \$skip_steps,
		   'multiroot' => \$multiroot)
	|| die "bad command line";

die "only one of --from-source and --from-source-clean allowed"
	if ($from_source && $from_source_clean);

$verbose=1 if (defined($verbose) && $verbose==0);
$verbose ||= 0; # stop complaints about undefined var in numeric comparison

if ($testmode)
{
	$verbose=1 unless $verbose;
	$forcerun = 1;
	$nostatus = 1;
	$nosend = 1;
	
}

my %skip_steps;
$skip_steps ||= "";
if ($skip_steps =~ /\S/)
{
   %skip_steps = map {$_ => 1} split(/\s+/,$skip_steps);
}

use vars qw($branch);
my $explicit_branch = shift;
$branch = $explicit_branch || 'HEAD';

print_help() if ($help);


#
# process config file
#
require $buildconf ;

# get the config data into some local variables
my ($buildroot,$target,$animal, $print_success, $aux_path, $trigger_filter,
	$secret, $keep_errs, $force_every, $make, $cvs_timeout_secs,
	$use_vpath, $tar_log_cmd, $using_msvc, $extra_config ) = 
	@PGBuild::conf{
		qw(build_root target animal print_success aux_path trigger_filter
		   secret keep_error_builds force_every make cvs_timeout_secs
		   use_vpath tar_log_cmd using_msvc extra_config)
		};

print scalar(localtime()),": buildfarm run for $animal:$branch starting\n"
	if $verbose;

die "cannot use vpath with MSVC" 
	if ($using_msvc and $use_vpath);


if (ref($force_every) eq 'HASH')
{
	$force_every = $force_every->{$branch};
}

my $config_opts = $PGBuild::conf{config_opts};
my $cvsserver = $PGBuild::conf{cvsrepo} || 
	":pserver:anoncvs\@anoncvs.postgresql.org:/projects/cvsroot";
my $buildport = $PGBuild::conf{branch_ports}->{$branch} || 5999;

my $cvsmethod = $PGBuild::conf{cvsmethod} || 'export';

$tar_log_cmd ||= "tar -z -cf runlogs.tgz *.log";

my $logdirname = "lastrun-logs";

if ($from_source || $from_source_clean)
{
	$from_source ||= $from_source_clean;
	die "sourceroot $from_source not absolute" 
		unless $from_source =~ m!^/! ;	
	# we need to know where the lock should go, so unless the path
	# contains HEAD we require it to be specified.
	die "must specify branch explicitly with from_source"
		unless ($explicit_branch || $from_source =~ m!/HEAD/!);
	$verbose ||= 1;
	$nosend=$nostatus=1;
	$use_vpath = undef;
	$logdirname = "fromsource-logs";
}

# sanity checks
# several people have run into these

if ( `uname -s 2>&1 ` =~ /CYGWIN/i )
{
	my @procs = `ps -ef`;
	die "cygserver not running" unless(grep {/cygserver/} @procs);
}
my $ccachedir;
if ( $ccachedir = $PGBuild::conf{build_env}->{CCACHE_DIR} )
{
    # ccache is smart enough to create what you tell it is the cache dir, but
    # not smart enough to build the whole path. mkpath croaks on error, so
	# we just let it.

	mkpath $ccachedir;
	$ccachedir = abs_path($ccachedir);
}

die "no aux_path in config file" unless $aux_path;

die "cannot run as root/Administrator" unless ($using_msvc or $> > 0);

my $devnull = $using_msvc ? "nul" : "/dev/null";

if (!$from_source && $cvsserver =~ /^:pserver:/ && ! $using_msvc)
{
	# we can't do this when using cvsnt (for msvc) because it
	# stores the passwords in the registry, damn it

	# this is NOT a perfect check, because we don't want to
	# catch the  port which might or might not be there
	# but it will warn most people if necessary, and it's not
	# worth any extra work.
	my $cvspass;
	my $loginfound = 0;
	my $srvr;
	(undef,,undef,$srvr,undef) = split(/:/,$cvsserver);
	my $qsrvr = quotemeta($srvr);
	if (open($cvspass,glob("~/.cvspass")))
	{
		while (my $line = <$cvspass>)
		{
			if ($line =~ /:pserver:$qsrvr:/)
			{
				$loginfound=1;
				last;
			}

		}
		close($cvspass);
	}
	die "Need to login to :pserver:$srvr first" 
		unless $loginfound;
}

if ($multiroot)
{
	warn "--multi-root is no longer necessary, and is deprecated";
}

my $st_prefix = "$animal."; 

my $pgsql = $from_source  || 
   ( ($cvsmethod eq 'export' && not $use_vpath) ? "pgsql" : "pgsql.$$" );

# set environment from config
while (my ($envkey,$envval) = each %{$PGBuild::conf{build_env}})
{
	$ENV{$envkey}=$envval;
}

# change to buildroot for this branch or die

die "no buildroot" unless $buildroot;

unless ($buildroot =~ m!^/! or 
		($using_msvc and $buildroot =~ m![a-z]:[/\\]!i ))
{
	die "buildroot $buildroot not absolute" ;
}



die "$buildroot does not exist or is not a directory" unless -d $buildroot;

chdir $buildroot || die "chdir to $buildroot: $!";

mkdir $branch unless -d $branch;

chdir $branch || die "chdir to $buildroot/$branch";

# rename legacy status files/directories
foreach my $oldfile (glob("last*"))
{
	move $oldfile, "$st_prefix$oldfile";
}

my $branch_root = getcwd();

# make sure we are using GNU make (except for MSVC)
unless ($using_msvc)
{
	die "$make is not GNU Make - please fix config file" 
		unless check_make();
}

# acquire the lock

my $lockfile;
my $have_lock;

open($lockfile, ">builder.LCK") || die "opening lockfile: $!";

# only one builder at a time allowed per branch
# having another build running is not a failure, and so we do not output
# a failure message under this condition.
if ($from_source)
{
	die "acquiring lock in $buildroot/$branch/builder.LCK" 
		unless flock($lockfile,LOCK_EX|LOCK_NB);
}
else
{
	exit(0) unless flock($lockfile,LOCK_EX|LOCK_NB);
}

die "$buildroot/$branch has $pgsql or inst directories!" 
	if ((!$from_source && -d $pgsql) || -d "inst");

# we are OK to run if we get here
$have_lock = 1;

# check if file present for forced run
my $forcefile = $st_prefix . "force-one-run";
if (-e $forcefile)
{
	$forcerun = 1;
	unlink $forcefile;
}

# try to allow core files to be produced.
# another way would be for the calling environment
# to call ulimit. We do this in an eval so failure is
# not fatal.
unless ($using_msvc)
{
	eval
	{
		require BSD::Resource;
		BSD::Resource->import();
		# explicit sub calls here. using & keeps compiler happy
		my $coreok = setrlimit(&RLIMIT_CORE,&RLIM_INFINITY,&RLIM_INFINITY);
		die "setrlimit" unless $coreok;
	};
	warn "failed to unlimit core size: $@" if $@ && $verbose > 1;
}

# the time we take the snapshot
my $now=time;
my $installdir = "$buildroot/$branch/inst";
my $dbstarted;

my %ignore_file = ();

# cleanup handler for all exits
END
{
	# if we have the lock we must already be in the build root, so
	# removing things should be safe.
	# there should only be anything to cleanup if we didn't have
	# success.
	if ( $have_lock && -d "$pgsql")
	{
		if ($dbstarted)
		{
			chdir $installdir;
			system (qq{"bin/pg_ctl" -D data stop >$devnull 2>&1});
			chdir $branch_root;
		}
		if ($ipcclean && -x "$pgsql/src/bin/ipcclean/ipcclean")
		{
			system("$pgsql/src/bin/ipcclean/ipcclean >$devnull 2>&1");
		}
		if ( !$from_source && $keep_errs) 
		{ 
			print "moving kept error trees\n" if $verbose;
			my $timestr = strftime "%Y-%m-%d_%H-%M-%S", localtime($now);
			unless (move("$pgsql", "pgsqlkeep.$timestr"))
			{
				print "error renaming '$pgsql' to 'pgsqlkeep.$timestr': $!";
			}
			if (-d "inst")
			{
				unless(move("inst", "instkeep.$timestr"))
				{
					print 
						"error renaming 'inst' to 'instkeep.$timestr': $!";
				}
			}
		}
		else
		{
			
			rmtree("inst") unless $keepall;
			rmtree("$pgsql") unless ($from_source || $keepall);
		}
		# only keep the cache in cases of success
		rmtree("$ccachedir") if $ccachedir;
	}
	if ($have_lock)
	{
		if ($use_vpath)
		{
			# vpath builds leave some stuff lying around in the
			# source dir, unfortunately. This should clean it up.
			unlink (keys %ignore_file);
		}
		close($lockfile);
		unlink("builder.LCK");
	}
}

my $extraconf;
if ($extra_config && $extra_config->{$branch})
{
    my $tmpname;
	($extraconf,$tmpname) = File::Temp::tempfile('buildfarm-XXXXXX');
    die 'no $tmpname!' unless $tmpname;
	$ENV{TEMP_CONFIG} = $tmpname;
	foreach my $line (@{$extra_config->{$branch}})
	{
		print $extraconf "$line\n";
	}
	autoflush $extraconf 1;
}


my $steps_completed = "";

my @changed_files;
my @changed_since_success;
my $last_status;
my $last_run_snap;
my $last_success_snap;
my $current_snap;
my @filtered_files;
my $savecvslog = "" ;

if ($from_source_clean)
{
	print time_str(),"cleaning source in $pgsql ...\n";
	clean_from_source();
}
elsif (! $from_source)
{
    # see if we need to run the tests (i.e. if either something has changed or
    # we have gone over the force_every heartbeat time)

	print time_str(),"checking out source ...\n" if $verbose;


	my $timeout_pid;

	$timeout_pid = spawn(\&cvs_timeout,$cvs_timeout_secs) 
		if $cvs_timeout_secs; 

	$savecvslog = checkout();

	if ($timeout_pid)
	{
		# don't kill me, I finished in time
		if (kill (SIGTERM, $timeout_pid))
		{
			# reap the zombie
			waitpid($timeout_pid,0); 
		}
	}

	print time_str(),"checking if build run needed ...\n" if $verbose;

    # transition to new time processing
	unlink "last.success";

    # get the timestamp data
	$last_status = find_last('status') || 0;
	$last_run_snap = find_last('run.snap');
	$last_success_snap = find_last('success.snap');
	$forcerun = 1 unless (defined($last_run_snap));

    # updated by find_changed to last mtime of any file in the repo
	$current_snap=0;

    # see if we need to force a build
	$last_status = 0
		if ($last_status && $force_every && 
			$last_status+($force_every*3600) < $now);
	$last_status = 0 if $forcerun;

    # get a hash of the files listed in .cvsignore files
    # They will be removed if a vpath build puts them in the repo.

	File::Find::find({wanted => \&find_ignore}, 'pgsql') ;

    # see what's changed since the last time we did work
	File::Find::find({wanted => \&find_changed}, 'pgsql');

    #ignore changes to files specified by the trigger filter, if any
	if (defined($trigger_filter))
	{
		@filtered_files = grep { ! m[$trigger_filter] } @changed_files;
	}
	else
	{
		@filtered_files = @changed_files;
	}

    # if no build required do nothing
	if ($last_status && ! @filtered_files)
	{
		print time_str(),
		"No build required: last status = ",scalar(gmtime($last_status)),
		" GMT, current snapshot = ",scalar(gmtime($current_snap))," GMT,",
		" changed files = ",scalar(@filtered_files),"\n" if $verbose;
		rmtree("$pgsql");
		exit 0;
	}
	
    # get CVS version info on both changed files sets
    # skip if in export mode

	unless ($cvsmethod eq "export")
	{
		get_cvs_versions(\@changed_files);
		get_cvs_versions(\@changed_since_success);
	}

} # end of unless ($from_source)

cleanlogs();

writelog('CVS',$savecvslog) unless $from_source;

# copy/create according to vpath/cvsmethod settings

if ($use_vpath)
{
    print time_str(),"creating vpath build dir $pgsql ...\n" if $verbose;
	mkdir $pgsql || die "making $pgsql: $!";
}
elsif (!$from_source && $cvsmethod eq 'update')
{
	print time_str(),"copying source to $pgsql ...\n" if $verbose;

	# annoyingly, there isn't a standard perl module to do a recursive copy
	# and I don't want to require use of the non-standard File::Copy::Recursive
	if ($using_msvc)
	{
		system("xcopy /I /Q /E pgsql $pgsql 2>&1");
	}
	else
	{
		system("cp -r pgsql $pgsql 2>&1");
	}
	my $status = $? >> 8;
	die "copying directories: $status" if $status;
}

# start working

set_last('status',$now) unless $nostatus;
set_last('run.snap',$current_snap) unless $nostatus;

my $started_times = 0;

# each of these routines will call send_result, which calls exit,
# on any error, so each step depends on success in the previous
# steps.

print time_str(),"running configure ...\n" if $verbose;

configure();

print time_str(),"running make ...\n" if $verbose;

make();

print time_str(),"running make check ...\n" if $verbose;

make_check();

unless ($using_msvc)
{
	print time_str(),"running make contrib ...\n" if $verbose;
	
	make_contrib();
}

print time_str(),"running make install ...\n" if $verbose;

make_install();

print time_str(),"setting up db cluster ...\n" if $verbose;

initdb();

print time_str(),"starting db ...\n" if $verbose;

start_db();

print time_str(),"running make installcheck ...\n" if $verbose;

make_install_check();

# releases 8.0 and earlier don't support the standard method for testing PLs
# so only check them for later versions

if ($branch eq 'HEAD' || $branch gt 'REL8_1')
{
    # restart the db to clear the log file
	print time_str(),"restarting db ...\n" if $verbose;

	stop_db();
	start_db();

	print time_str(),"running make PL installcheck ...\n" if $verbose;

	make_pl_install_check();
}

# restart the db to clear the log file
print time_str(),"restarting db ...\n" if $verbose;

stop_db();
start_db();

# contrib is installed under standard install for msvc
unless ($using_msvc)
{
	print time_str(),"running make contrib install ...\n" if $verbose;

	make_contrib_install();
}

print time_str(),"running make contrib installcheck ...\n" if $verbose;

make_contrib_install_check();

print time_str(),"stopping db ...\n" if $verbose;

stop_db();

# ecpg checks are not supported in 8.1 and earlier
if ($branch eq 'HEAD' || $branch gt 'REL8_2')
{
	print time_str(),"running make ecpg check ...\n" if $verbose;
	
	make_ecpg_check();
}

if ($find_typedefs)
{
	print time_str(),"running find_typedefs ...\n" if $verbose;
	
	find_typedefs();
}

# if we get here everything went fine ...

my $saved_config = get_config_summary();

rmtree("inst"); # only keep failures
rmtree("$pgsql") unless $from_source;

print(time_str(),"OK\n") if $verbose;

send_result("OK");

exit;

############## end of main program ###########################

sub print_help
{
	print qq!
usage: $0 [options] [branch]

 where options are one or more of:

  --nosend                  = don't send results
  --nostatus                = don't set status files
  --force                   = force a build run (ignore status files)
  --from-source=/path       = use source in path, not from cvs
  or
  --from-source-clean=/path = same as --from-source, run make distclean first
  --config=/path/to/file    = alternative location for config file
  --keepall                 = keep directories if an error occurs
  --verbose[=n]             = verbosity (default 1) 2 or more = huge output.
  --quiet                   = suppress normal error message 
  --ipcclean                = clean up shared memory on failure
  --test                    = short for --nosend --nostatus --verbose --force

Default branch is HEAD. Usually only the --config option should be necessary.

!;
	exit(0);
}

sub time_str
{
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	return sprintf("[%.2d:%.2d:%.2d] ",$hour, $min, $sec);
}

sub clean_from_source
{
	if (-e "$pgsql/GNUmakefile")
	{
		# fixme for MSVC
		my @makeout = `cd $pgsql && $make distclean 2>&1`;
		my $status = $? >>8;
		writelog('distclean',\@makeout);
		print "======== distclean log ===========\n",
		  @makeout if ($verbose > 1);
		send_result('distclean',$status,\@makeout) if $status;
	}
}

sub interrupt_exit
{
	my $signame = shift;
	print "Exiting on signal $signame\n";
	exit(1);
}


sub cleanlogs
{
	my $lrname = $st_prefix . $logdirname;
	rmtree("$lrname");
	mkdir "$lrname" || die "can't make $lrname dir: $!";
}

sub writelog
{
	my $stage = shift;
	my $loglines = shift;
	my $handle;
	my $lrname = $st_prefix . $logdirname;
	open($handle,">$lrname/$stage.log");
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
	return if $skip_steps{make};
	my (@makeout);
	unless ($using_msvc)
	{
		@makeout = `cd $pgsql && $make 2>&1`;
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = `perl build.pl 2>&1`;
		chdir $branch_root;
	}
	my $status = $? >>8;
	writelog('make',\@makeout);
	print "======== make log ===========\n",@makeout if ($verbose > 1);
	send_result('Make',$status,\@makeout) if $status;
	$steps_completed .= " Make";
}

sub make_install
{
	my @makeout;
	unless ($using_msvc)
	{
		@makeout = `cd $pgsql && $make install 2>&1`;
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = `perl install.pl "$installdir" 2>&1`;
		chdir $branch_root;
	}
	my $status = $? >>8;
	writelog('make-install',\@makeout);
	print "======== make install log ===========\n",@makeout if ($verbose > 1);
	send_result('Install',$status,\@makeout) if $status;

	# On Windows and Cygwin avoid path problems associated with DLLs
	# by copying them to the bin dir where the system will pick them
	# up regardless.

	foreach my $dll (glob("$installdir/lib/*pq.dll"))
	{
		my $dest = "$installdir/bin/" . basename($dll);
		copy($dll,$dest);
		chmod 0755, $dest;
	}

	# make sure the installed libraries come first in dynamic load paths
	# this won;t have any effect under Windows, but the DLL copy above 
	# achieves the same thing there anyway.
	# DYLD_LIBRARY_PATH is for darwin.
	# this is exactly what pg_regress does for its temp installs.

	if (my $ldpath = $ENV{LD_LIBRARY_PATH})
	{
		$ENV{LD_LIBRARY_PATH}="$installdir/lib:$ldpath";
	}
	else
	{
		$ENV{LD_LIBRARY_PATH}="$installdir/lib";
	}
	if (my $ldpath = $ENV{DYLD_LIBRARY_PATH})
	{
		$ENV{DYLD_LIBRARY_PATH}="$installdir/lib:$ldpath";
	}
	else
	{
		$ENV{DYLD_LIBRARY_PATH}="$installdir/lib";
	}

	$steps_completed .= " Install";
}

sub make_contrib
{
	# part of build under msvc
	return if $skip_steps{'make-contrib'};
	my @makeout = `cd $pgsql/contrib && $make 2>&1`;
	my $status = $? >>8;
	writelog('make-contrib',\@makeout);
	print "======== make contrib log ===========\n",@makeout if ($verbose > 1);
	send_result('Contrib',$status,\@makeout) if $status;
	$steps_completed .= " Contrib";
}

sub make_contrib_install
{
	# part of install under msvc
	my @makeout = `cd $pgsql/contrib && $make install 2>&1`;
	my $status = $? >>8;
	writelog('install-contrib',\@makeout);
	print "======== make contrib install log ===========\n",@makeout 
		if ($verbose > 1);
	send_result('ContribInstall',$status,\@makeout) if $status;
	$steps_completed .= " ContribInstall";
}

sub initdb
{
	my @initout;
	if ($using_msvc)
	{
		chdir $installdir;
		@initout = `"bin/initdb" --no-locale data 2>&1`;
		chdir $branch_root;
	}
	else
	{       
		# --no-locale switch only came in with 7.3
		my $noloc = "--no-locale";
		$noloc = "" if ($branch ne 'HEAD' && $branch lt 'REL7_3');
		@initout = 
			`cd $installdir && LANG= LC_ALL= bin/initdb $noloc data 2>&1`;
	}

	my $status = $? >>8;

	if ($extraconf)
	{
		my $handle;
		open($handle,">>$installdir/data/postgresql.conf");
		foreach my $line (@{$extra_config->{$branch}})
		{
			print $handle "$line\n";
		}
		close($handle);
	}

	writelog('initdb',\@initout);
	print "======== initdb log ===========\n",@initout if ($verbose > 1);
	send_result('Initdb',$status,\@initout) if $status;
	$steps_completed .= " Initdb";
}


sub start_db
{

	$started_times++;
	if (-e "$installdir/logfile")
	{
		# give Windows some breathing room if necessary
		sleep 5;
		unlink "$installdir/logfile";
		sleep 5;
	}
	# must use -w here or we get horrid FATAL errors from trying to
	# connect before the db is ready
	# clear log file each time we start
	# seem to need an intermediate file here to get round Windows bogosity
	chdir($installdir);
	my $cmd = '"bin/pg_ctl" -D data -l logfile -w start >startlog 2>&1';
	system($cmd);
	my $status = $? >>8;
	chdir($branch_root);
	my $handle;
	open($handle,"$installdir/startlog");
	my @ctlout = <$handle>;
	close($handle);
	if (open($handle,"$installdir/logfile"))
	{
		my @loglines = <$handle>;
		close($handle);
		push(@ctlout,"=========== db log file ==========\n",@loglines);
	}
	writelog("startdb-$started_times",\@ctlout);
	print "======== start db : $started_times log ===========\n",@ctlout 
		if ($verbose > 1);
	send_result("StartDb:$started_times",$status,\@ctlout) if $status;
	$dbstarted=1;
}

sub stop_db
{
	my $logpos = -s "$installdir/logfile" || 0;
	chdir($installdir);
	my $cmd = '"bin/pg_ctl" -D data stop >stoplog 2>&1';
	system($cmd);
	my $status = $? >>8;
	chdir($branch_root);
	my $handle;
	open($handle,"$installdir/stoplog");
	my @ctlout = <$handle>;
	close($handle);
	if (open($handle,"$installdir/logfile"))
	{
		# go to where the log file ended before we tried to shut down.
		seek($handle, $logpos, SEEK_SET);
		my @loglines = <$handle>;
		close($handle);
		push(@ctlout,"=========== db log file ==========\n",@loglines);
	}
	writelog("stopdb-$started_times",\@ctlout);
	print "======== stop db : $started_times log ===========\n",@ctlout 
		if ($verbose > 1);
	send_result("StopDb:$started_times",$status,\@ctlout) if $status;
	$dbstarted=undef;
}


sub get_stack_trace
{
	my $bindir = shift;
	my $pgdata = shift;

	# no core = no result
	my @cores = glob("$pgdata/core*");
	return () unless @cores;

	# no gdb = no result
	system "gdb --version > $devnull 2>&1";
	my $status = $? >>8;
	return () if $status; 

	my @trace;

	foreach my $core (@cores)
	{
		my @onetrace = `gdb -ex bt --batch $bindir/postgres $core 2>&1`;
		push(@trace,
			"\n\n================== stack trace: $core ==================\n",
			 @onetrace);
	}

	return @trace;
}

sub make_install_check
{
	return if $skip_steps{'install-check'};
	my @checkout;
	unless ($using_msvc)
	{
		@checkout = `cd $pgsql/src/test/regress && $make installcheck 2>&1`;
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@checkout = `perl vcregress.pl installcheck 2>&1`;
		chdir $branch_root;
	}
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
	if ($status)
	{
		my @trace = get_stack_trace("$installdir/bin","$installdir/data");
		push(@checkout,@trace);
	}
	writelog('install-check',\@checkout);
	print "======== make installcheck log ===========\n",@checkout 
		if ($verbose > 1);
	send_result('InstallCheck',$status,\@checkout) if $status;	
	$steps_completed .= " InstallCheck";
}

sub make_contrib_install_check
{
	return if $skip_steps{'contrib-install-check'};
	my @checkout ;
	unless ($using_msvc)
	{
		@checkout = `cd $pgsql/contrib && $make installcheck 2>&1`;
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@checkout = `perl vcregress.pl contribcheck 2>&1`;
		chdir $branch_root;
	}
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
	if ($status)
	{
		my @trace = get_stack_trace("$installdir/bin","$installdir/data");
		push(@checkout,@trace);
	}
	writelog('contrib-install-check',\@checkout);
	print "======== make contrib installcheck log ===========\n",@checkout 
		if ($verbose > 1);
	send_result('ContribCheck',$status,\@checkout) if $status;
	$steps_completed .= " ContribCheck";
}

sub make_pl_install_check
{
	return if $skip_steps{'pl-install-check'};
	my @checkout;
	unless ($using_msvc)
	{
		@checkout = `cd $pgsql/src/pl && $make installcheck 2>&1`;
	}
	else
	{
		chdir("$pgsql/src/tools/msvc");
		@checkout = `perl vcregress.pl plcheck 2>&1`;
		chdir($branch_root);
	}
	my $status = $? >>8;
	my @logs = glob ("$pgsql/src/pl/*/regression.diffs");
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
	if ($status)
	{
		my @trace = get_stack_trace("$installdir/bin","$installdir/data");
		push(@checkout,@trace);
	}
	writelog('pl-install-check',\@checkout);
	print "======== make pl installcheck log ===========\n",@checkout 
		if ($verbose > 1);
	send_result('PLCheck',$status,\@checkout) if $status;
	# only report PLCheck as a step if it actually tried to do anything
	$steps_completed .= " PLCheck" 
		if (grep {/pg_regress|Checking pl/} @checkout) ;
}

sub make_check
{
	return if $skip_steps{check};
	my @makeout;
	unless ($using_msvc)
	{
		@makeout = 
			`cd $pgsql/src/test/regress && $make NO_LOCALE=1 check 2>&1`;
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = `perl vcregress.pl check 2>&1`;
		chdir $branch_root;
	}
 
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
	if ($status)
	{
		my $base = "$pgsql/src/test/regress/tmp_check";
		my @trace = 
			get_stack_trace("$base/install$installdir/bin",	"$base/data");
		push(@makeout,@trace);
	}
	writelog('check',\@makeout);
	print "======== make check logs ===========\n",@makeout 
		if ($verbose > 1);

	send_result('Check',$status,\@makeout) if $status;
	$steps_completed .= " Check";
}

sub make_ecpg_check
{
	return if $skip_steps{'ecpg-check'};
	my @makeout;
	my $ecpg_dir = "$pgsql/src/interfaces/ecpg";
	if ($using_msvc)
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = `perl vcregress.pl ecpgcheck 2>&1`;
		chdir $branch_root;
	}
	else
	{
		@makeout = `cd  $ecpg_dir && $make NO_LOCALE=1 check 2>&1`;
	}
	my $status = $? >>8;

	# get the log files and the regression diffs
	my @logs = glob("$ecpg_dir/test/log/*.log");
	unshift(@logs,"$ecpg_dir/test/regression.diffs")
		if (-e "$ecpg_dir/test/regression.diffs");
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
	if ($status)
	{
		my $base = "$ecpg_dir/test/regress/tmp_check";
		my @trace = 
			get_stack_trace("$base/install$installdir/bin",	"$base/data");
		push(@makeout,@trace);
	}
	writelog('ecpg-check',\@makeout);
	print "======== make ecpg check logs ===========\n",@makeout 
		if ($verbose > 1);

	send_result('ECPG-Check',$status,\@makeout) if $status;
	$steps_completed .= " ECPG-Check";
}

sub find_typedefs
{
	my @err = `objdump -W 2>&1`;
	@err = () if `uname -s 2>&1` =~ /CYGWIN/i;
	my %syms;
	my @dumpout;
	my @flds;
	foreach my $bin (glob("$installdir/bin/*"),
					 glob("$installdir/lib/*"),
					 glob("$installdir/lib/postgresql/*"))
	{
		next if $bin =~ m!bin/(ipcclean|pltcl_)!;
		next unless -f $bin;
		if (@err == 1) # Linux
		{
			@dumpout = `objdump -W $bin 2>/dev/null | egrep -A3 '(DW_TAG_typedef|DW_TAG_structure_type|DW_TAG_union_type)' 2>/dev/null`;
			foreach (@dumpout)
			{
				@flds = split;
				next if ($flds[0]  ne 'DW_AT_name' || $flds[-1] =~ /^DW_FORM_str/);
				$syms{$flds[-1]} =1;
			}
		}
		else
		{
			@dumpout = `objdump --stabs $bin 2>/dev/null`;
			foreach (@dumpout)
			{
				@flds = split;
				next if (@flds < 7);
				next if ($flds[1]  ne 'LSYM' || $flds[6] !~ /([^:]+):[tT]/);
				$syms{$1} =1;
			}			
		}		
	}
	my @badsyms = grep { /\s/ } keys %syms;
	push(@badsyms,'date','interval','timestamp','ANY');
	delete @syms{@badsyms};

	my @goodsyms = sort keys %syms;
	my @foundsyms;

	foreach my $sym (@goodsyms)
	{
		system("grep -r -w -q --exclude cscope.out --exclude pgtypedefs.bsdos --exclude tags $sym $branch_root/pgsql");
        push(@foundsyms,$sym) unless ($? >> 8);
	}

	map { s/$/\n/; } @foundsyms;

	writelog('typedefs',\@foundsyms);
	$steps_completed .= " find-typedefs";    
}

sub configure
{

	if ($using_msvc)
	{
		my $lconfig = { %$config_opts, "--with-pgport" => $buildport };
		my $conf = Data::Dumper->Dump([$lconfig],['config']);
		my @text = (
					"# Configuration arguments for vcbuild.\n",
					"# written bu buildfarm client \n",
					"use strict; \n",
					"use warnings;\n",
					"our $conf \n",
					"1;\n"
					);

		my $handle;
		open($handle,">$pgsql/src/tools/msvc/config.pl");
		print $handle @text;
		close($handle);

		push(@text, "# no configure step for MSCV - config file shown\n");

		writelog('configure',\@text);

		$steps_completed .= " Configure";

		return;
	} 

	my @quoted_opts;
	foreach my $c_opt (@$config_opts)
	{
		push(@quoted_opts,"'$c_opt'");
	}

	my $confstr = join(" ",@quoted_opts,
					   "--prefix=$installdir",
					   "--with-pgport=$buildport");

	my $env = $PGBuild::conf{config_env};

	my $envstr = "";
	while (my ($key,$val) = each %$env)
	{
		$envstr .= "$key='$val' ";
	}

	my $conf_path = $use_vpath ? "../pgsql/configure" : "./configure";
	
	my @confout = `cd $pgsql && $envstr $conf_path $confstr 2>&1`;
	
	my $status = $? >> 8;

	print "======== configure output ===========\n",@confout 
		if ($verbose > 1);

	writelog('configure',\@confout);

	my ($handle,@config);

	if (open($handle,"$pgsql/config.log"))
	{
		while(<$handle>)
		{
			push(@config,$_);
		}
		close($handle);
		writelog('config',\@config);
	}
	
	if ($status)
	{

		push(@confout,
			 "\n\n================= config.log ================\n\n",
			 @config);

		send_result('Configure',$status,\@confout);
	}
	
	$steps_completed .= " Configure";
}

sub find_ignore
{
	# skip CVS dirs if using update
	if ($cvsmethod eq 'update' && $_ eq 'CVS' && -d $_)
	{
		$File::Find::prune = 1;
	}
	elsif (-f $_ && $_ eq '.cvsignore')
	{
		my $fh;
		open($fh,$_) || die "cannot open $File::Find::name for reading";
		my @names = (<$fh>);
		close($fh);
		chomp @names;
		map { s!^!$File::Find::dir/!; } @names;
		@ignore_file{@names} = (1) x @names;
	}
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

		if (-f _ )
		{
			$current_snap = $mtime  if ($mtime > $current_snap);
			
			my $sname = $File::Find::name;
			if ($last_run_snap && ($mtime > $last_run_snap))
			{
				$sname =~ s!^pgsql/!!;
				push(@changed_files,$sname);
			}
			elsif ($last_success_snap && ($mtime > $last_success_snap))
			{
				$sname =~ s!^pgsql/!!;
				push(@changed_since_success,$sname);
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
		chdir 'pgsql';
		@cvslog = `cvs -d $cvsserver update -d $rtag 2>&1`;
		chdir '..';
	}
	else
	{
		@cvslog = `cvs -d $cvsserver co $rtag pgsql 2>&1`;
	}
	my $status = $? >>8;
	print "======== cvs $cvsmethod log ===========\n",@cvslog
		if ($verbose > 1);
	# can't call writelog here because we call cleanlogs after the
	# cvs stage, since we only clear out the logs if we find we need to
	# do a build run.
	# consequence - we don't save the cvs log if we don't do a run
	# doesn't matter too much because if CVS fails we exit anyway.

	my $merge_conflicts = grep {/^C/} @cvslog;
	my $mod_files = grep { /^M/ } @cvslog;
	my $unknown_files = grep {/^\?/ } @cvslog;
	my @bad_ignore = ();
	foreach my $ignore (keys %ignore_file)
	{
		push (@bad_ignore,"X $ignore\n") 
			if -e $ignore;
	}

	if ( $cvsmethod ne 'export' && $unknown_files && 
		! ($nosend && $nostatus ) )
	{
		sleep 20;
		my @statout = `cd pgsql && cvs -d $cvsserver status 2>&1`;
		$unknown_files = grep { /^\?/ } @statout;
	}
		
	
	send_result('CVS',$status,\@cvslog)	if ($status);
	send_result('CVS-Merge',$merge_conflicts,\@cvslog) 
		if ($merge_conflicts);
	unless ($nosend && $nostatus)
	{
		send_result('CVS-Dirty',$mod_files,\@cvslog) 
			if ($mod_files);
		send_result('CVS-Extraneous-Files',$unknown_files,\@cvslog)
			if ($unknown_files);
		send_result('CVS-Extraneous-Ignore',scalar(@bad_ignore),\@bad_ignore)
			if (@bad_ignore);
	}
	$steps_completed = "CVS";

	# if we were successful, however, we return the info so that 
	# we can put it in the newly cleaned logdir  later on.
	return \@cvslog;
}

sub get_cvs_versions
{
	my $flist = shift;
	return unless @$flist;
	my @cvs_status;
	# some shells (e.g cygwin::bash ) choke on very long command lines
	# so do this in batches.
	while (@$flist)
	{
		my @chunk = splice(@$flist,0,200);
		my @res = `cd pgsql && cvs status @chunk 2>&1` ;
		push(@cvs_status,@res);
		my $status = $? >>8;
		print "======== cvs status log ===========\n",@cvs_status
			if ($verbose > 1);
		send_result('CVS-status',$status,\@cvs_status)	if ($status);
	}
	my @fchunks = split(/File:/,join("",@cvs_status));
	my @repolines;
	foreach (@fchunks)
	{
		# we need to report the working revision rather than the
		# repository revision version in case the file has been
		# updated between the time we did the checkout/update and now.
		next unless 
			m!
			Working\srevision:\s+
			(\d+(\.\d+)+)
			.*Repository.revision:.
			(\d+(\.\d+)+)
			.*
			/(pgsql/.*)
			,v
			!sx ;

		push(@repolines,"$5 $1");
	}
	@$flist = (@repolines);
}

sub find_last
{
	my $which = shift;
	my $stname = $st_prefix . "last.$which";
	my $handle;
	open($handle,$stname) or return undef;
	my $time = <$handle>;
	close($handle);
	chomp $time;
	return $time + 0;
}

sub set_last
{
	my $which = shift;
	my $stname = $st_prefix . "last.$which";
	my $st_now = shift || time;
	my $handle;
	open($handle,">$stname") or die "opening $stname: $!";
	print $handle "$st_now\n";
	close($handle);
}

sub send_result
{
    # clean up temp file
	$extraconf = undef;

	my $stage = shift;
	my $ts = $now || time;
	my $status=shift || 0;
	my $log = shift || [];
	print "======== log passed to send_result ===========\n",@$log
		if ($verbose > 1);
	
	unshift (@$log,
			 "Last file mtime in snapshot: ",
			 scalar(gmtime($current_snap))," GMT\n",
			 "===================================================\n")
		unless ($from_source || ! $current_snap);

	my $log_data = join("",@$log);
	my $confsum = "" ;
	my $changed_this_run = "";
	my $changed_since_success = "";
	$changed_this_run = join("!",@changed_files)
		if @changed_files;
	$changed_since_success = join("!",@changed_since_success)
		if ($stage ne 'OK' && @changed_since_success);
	if ($stage eq 'OK')
	{
		$confsum= $saved_config;
	}
	elsif ($stage !~ /CVS/ )
	{
		$confsum = get_config_summary();
	}

	my $savedata = Data::Dumper->Dump
		(
		 [$changed_this_run, $changed_since_success, $branch, $status,$stage,
		  $animal, $ts, $log_data, $confsum, $target, $verbose, $secret],
		 [qw(changed_this_run changed_since_success branch status stage
			 animal ts log_data confsum target verbose secret)]);
	
	my $lrname = $st_prefix . $logdirname;

	# might happen if there is a CVS failure and have never got further
	mkdir $lrname unless -d $lrname;

	my $txfname = "$lrname/web-txn.data";
	my $txdhandle;
	open($txdhandle,">$txfname");
	print $txdhandle $savedata;
	close($txdhandle);

	if ($nosend || $stage eq 'CVS' || $stage eq 'CVS-status' )
	{
		print "Branch: $branch\n";
		if ($stage eq 'OK')
		{
			print "All stages succeeded\n";
			set_last('success.snap',$current_snap) unless $nostatus;
			exit(0);
		}
		else
		{
			print "Stage $stage failed with status $status\n";
			exit(1);
		}
	}

	if ($stage !~ /CVS/ )
	{

		my @logfiles = glob("$lrname/*.log");
		my %mtimes = map { $_ => (stat $_)[9] } @logfiles;
		@logfiles =  map { basename $_ } 
		( sort { $mtimes{$a} <=> $mtimes{$b} } @logfiles );
		my $logfiles = join (' ',@logfiles);
		$tar_log_cmd =~ s/\*\.log/$logfiles/;
		chdir($lrname);
		system("$tar_log_cmd 2>&1 ");
		chdir($branch_root);

	}
	else
	{
		# these would be from an earlier run, since we
		# do cleanlogs() after the cvs stage
		# so don't send them.
		unlink "$lrname/runlogs.tgz";
	}
	

	unless (-x "$aux_path/run_web_txn.pl" || 
		($using_msvc && -f "$aux_path/run_web_txn.pl"))
	{
		print "Could not locate $aux_path/run_web_txn.pl\n";
		exit(1);
	}

	if ($using_msvc)
	{
		# no shebang line for windows, but perl is in the path
		system("perl \"$aux_path/run_web_txn.pl\" $lrname");
	}
	else
	{
		system("$aux_path/run_web_txn.pl $lrname");
	}

	my $txstatus = $? >> 8;

	if ($txstatus)
	{
		print "Web txn failed with status: $txstatus\n";
		exit($txstatus);
	}

	unless ($stage eq 'OK' || $quiet)
	{
		print "Buildfarm member $animal failed on $branch stage $stage\n";
	}

#	print "Success!\n",$response->content 
#		if $print_success;

	set_last('success.snap',$current_snap) if ($stage eq 'OK' && ! $nostatus);

	exit 0;
}

sub get_config_summary
{
	my $handle;
	my $config = "";
	unless ($using_msvc)
	{
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
			next if /= <?unknown>?/;
			# split up long configure line
			if (m!\$.*configure.*--with! && length > 70)
			{
				my $pos = index($_," ",70);
				substr($_,$pos+1,0,"\\\n        ") if ($pos > 0);
				$pos = index($_," ",140);
				substr($_,$pos+1,0,"\\\n        ") if ($pos > 0);
				$pos = index($_," ",210);
				substr($_,$pos+1,0,"\\\n        ") if ($pos > 0);
			}
			$config .= $_;
		}
		close($handle);
		$config .= 
			"\n========================================================\n";
	}
	my $conf = {%PGBuild::conf,  # shallow copy
				script_version => $VERSION,
				invocation_args => \@invocation_args,
				steps_completed => $steps_completed,
			};
	delete $conf->{secret};
	$config .= Data::Dumper->Dump([$conf],['Script_Config']);
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
