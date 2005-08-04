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
	q$Id: run_build.pl,v 1.45 2005/08/04 15:29:35 andrewd Exp $
	=~ /(\d+)/g; 

use strict;
use Fcntl qw(:flock);
use File::Path;
use File::Basename;
use Getopt::Long;
use POSIX qw(:signal_h);
use Data::Dumper;

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
my $help;
my $multiroot;
my $quiet;
my $from_source;

GetOptions('nosend' => \$nosend, 
		   'config=s' => \$buildconf,
		   'from-source=s' => \$from_source,
		   'force' => \$forcerun,
		   'keepall' => \$keepall,
		   'verbose:i' => \$verbose,
		   'nostatus' => \$nostatus,
		   'help' => \$help,
		   'quiet' => \$quiet,
		   'multiroot' => \$multiroot)
	|| die "bad command line";

$verbose=1 if (defined($verbose) && $verbose==0);

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
	$use_vpath, $tar_log_cmd ) = 
	@PGBuild::conf{
		qw(build_root target animal print_success aux_path trigger_filter
		   secret keep_error_builds force_every make cvs_timeout_secs
		   use_vpath tar_log_cmd )
		};

my @config_opts = @{$PGBuild::conf{config_opts}};
my $cvsserver = $PGBuild::conf{cvsrepo} || 
	":pserver:anoncvs\@anoncvs.postgresql.org:/projects/cvsroot";
my $buildport = $PGBuild::conf{branch_ports}->{$branch} || 5999;

my $cvsmethod = $PGBuild::conf{cvsmethod} || 'export';

$tar_log_cmd ||= "tar -z -cf runlogs.tgz *.log";

my $logdirname = "lastrun-logs";

if ($from_source)
{
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

if ( my $ccachedir = $PGBuild::conf{build_env}->{CCACHE_DIR} )
{
    # ccache is smart enough to create what you tell it is the cache dir, but
    # not smart enough to build the whole path. mkpath croaks on error, so
	# we just let it.

	mkpath $ccachedir;
}

die "no aux_path in config file" unless $aux_path;

die "cannot run as root/Administrator" unless ($> > 0);

if (!$from_source && $cvsserver =~ /^:pserver:/)
{
	# this is NOT a perfect check, because we don't want to
	# catch the  port which might or might not be there
	# but it will warn most people if necessary, and it's not
	# worth any extra work.
	my $cvspass;
	my $loginfound = 0;
	my $srvr;
	(undef,,undef,$srvr,undef) = split(/:/,$cvsserver);
	$srvr = quotemeta($srvr);
	if (open($cvspass,glob("~/.cvspass")))
	{
		while (my $line = <$cvspass>)
		{
			if ($line =~ /:pserver:$srvr:/)
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

# special prefix for last.* if running multiroot, 
# so they don't clobber each other
my $mr_prefix = $multiroot ? "$animal." : ""; 

my $pgsql = $from_source  || 
   ( ($cvsmethod eq 'export' && not $use_vpath) ? "pgsql" : "pgsql.$$" );

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
		if ($dbstarted)
		{
			system ("cd inst && bin/pg_ctl -D data stop >/dev/null 2>&1");
		}
		if ( !$from_source && $keep_errs) 
		{ 
			system("mv $pgsql pgsqlkeep.$now && mv inst instkeep.$now") ;
		}
		system("rm -rf inst") unless $keepall;
		system("rm -rf $pgsql") unless ($from_source || $keepall);
	}
	if ($have_lock)
	{
		close($lockfile);
		unlink("builder.LCK");
	}
}


my $steps_completed = "";



my @changed_files;
my @changed_since_success;
my $last_status;
my $last_run_snap;
my $last_success_snap;
my $current_snap;
my %ignore_file = ();
my @filtered_files;
my $savecvslog = "" ;

if ($from_source)
{
	print "cleaning source in $pgsql ...\n";
	clean_from_source();
}
else
{
    # see if we need to run the tests (i.e. if either something has changed or
    # we have gone over the force_every heartbeat time)

	print "checking out source ...\n" if $verbose;


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

	print "checking if build run needed ...\n" if $verbose;

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
    # find_changed will skip these files

	File::Find::find({wanted => \&find_ignore}, 'pgsql');

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
		print "No build required: last status = ",scalar(gmtime($last_status)),
		" GMT, current snapshot = ",scalar(gmtime($current_snap))," GMT,",
		" changed files = ",scalar(@filtered_files),"\n" if $verbose;
		system("rm -rf $pgsql");
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
    print "creating vpath build dir $pgsql ...\n" if $verbose;
	mkdir $pgsql || die "making $pgsql: $!";
}
elsif (!$from_source && $cvsmethod eq 'update')
{
	print "copying source to $pgsql ...\n" if $verbose;

	system("cp -r pgsql $pgsql 2>&1");
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

# releases 8.0 and earlier don't support the standard method for testing PLs
# so only check them for later versions

if ($branch eq 'HEAD' || $branch gt 'REL8_1' )
{

    # restart the db to clear the log file
	print "restarting db ...\n" if $verbose;

	stop_db();
	start_db();

	print "running make PL installcheck ...\n" if $verbose;

	make_pl_install_check();

}

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

system("rm -rf inst"); # only keep failures
system("rm -rf $pgsql") unless $from_source;

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
  --nostatus              = don't set status files
  --force                 = force a build run (ignore status files)
  --from-source=/path     = use source in path, not from cvs
  --config=/path/to/file  = alternative location for config file
  --keepall               = keep directories if an error occurs
  --verbose[=n]           = verbosity (default 1) 2 or more = huge output.
  --quiet                 = suppress normal error message 
  --multiroot             = allow several members to use same build root

Default branch is HEAD. Usually only the --config option should be necessary.

!;
	exit(0);
}

sub clean_from_source
{
	if (-e "$pgsql/GNUmakefile")
	{
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
	my $lrname = $mr_prefix . $logdirname;
	system("rm -rf $lrname");
	mkdir "$lrname" || die "can't make $lrname dir: $!";
}

sub writelog
{
	my $stage = shift;
	my $loglines = shift;
	my $handle;
	my $lrname = $mr_prefix . $logdirname;
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
	my @makeout = `cd $pgsql && $make 2>&1`;
	my $status = $? >>8;
	writelog('make',\@makeout);
	print "======== make log ===========\n",@makeout if ($verbose > 1);
	send_result('Make',$status,\@makeout) if $status;
	$steps_completed .= " Make";
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
	$steps_completed .= " Install";
}

sub make_contrib
{
	my @makeout = `cd $pgsql/contrib && $make 2>&1`;
	my $status = $? >>8;
	writelog('make-contrib',\@makeout);
	print "======== make contrib log ===========\n",@makeout if ($verbose > 1);
	send_result('Contrib',$status,\@makeout) if $status;
	$steps_completed .= " Contrib";
}

sub make_contrib_install
{
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
	# --no-locale switch only came in with 7.3
	my $noloc = "--no-locale";
	$noloc = "" if ($branch ne 'HEAD' && $branch lt 'REL7_3');
	my @initout = `cd $installdir && LANG= LC_ALL= bin/initdb $noloc data 2>&1`;
	my $status = $? >>8;
	writelog('initdb',\@initout);
	print "======== initdb log ===========\n",@initout if ($verbose > 1);
	send_result('Initdb',$status,\@initout) if $status;
	$steps_completed .= " Initdb";
}

sub start_db
{
	$started_times++;
	# must use -w here or we get horrid FATAL errors from trying to
	# connect before the db is ready
	# clear log file each time we start
	# seem to need an intermediate file here to get round Windows bogosity
	my $cmd = "cd $installdir && rm -f logfile && ".
		"bin/pg_ctl -D data -l logfile -w start >startlog 2>&1";
	system($cmd);
	my $status = $? >>8;
	my $handle;
	open($handle,"$installdir/startlog");
	my @ctlout = <$handle>;
	close($handle);
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
	$steps_completed .= " InstallCheck";
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
	$steps_completed .= " ContribCheck";
}

sub make_pl_install_check
{
	my @checkout = `cd $pgsql/src/pl && $make installcheck 2>&1`;
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
	writelog('pl-install-check',\@checkout);
	print "======== make pl installcheck log ===========\n",@checkout 
		if ($verbose > 1);
	send_result('PLCheck',$status,\@checkout) if $status;
	# only report PLCheck as a step if it actually tried to do anything
	$steps_completed .= " PLCheck" if (grep {/pg_regress/} @checkout) ;
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
	$steps_completed .= " Check";
}

sub configure
{

	my @quoted_opts;
	foreach my $c_opt (@config_opts)
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
		my $ fh;
		open($fh,$_) || die "cannot open $name for reading";
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
	elsif ($ignore_file{$name})
	{
		# do nothing
		# print "Ignoring $name\n";
	}
	else
	{
		my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,
			$size,$atime,$mtime,$ctime,$blksize,$blocks) = lstat($_);

		if (-f _ )
		{
			$current_snap = $mtime  if ($mtime > $current_snap);
			return unless $last_status;

			my $sname = $name;
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
	# consequence - we don't save the cvs log if we don't do a run
	# doesn't matter too much because if CVS fails we exit anyway.

	my $merge_conflicts = grep {/^C/} @cvslog;
	my $modfiles = grep { /^M/ } @cvslog;
	
	send_result('CVS',$status,\@cvslog)	if ($status);
	send_result('CVS-Merge',$merge_conflicts,\@cvslog) if ($merge_conflicts);
	send_result('CVS-Dirty',$modfiles,\@cvslog) 
		if ($modfiles && !($nosend && $nostatus ));
	$steps_completed = "CVS";

	# if we were successful, however, we return the info so that 
	# we can put it in the newly cleaned logdir  later on.
	return \@cvslog;
}

sub get_cvs_versions
{
	my $flist = shift;
	return unless @$flist;
	my @cvs_status = `cd pgsql && cvs status @$flist 2>&1` ;
	my $status = $? >>8;
	print "======== cvs status log ===========\n",@cvs_status
		if ($verbose > 1);
	send_result('CVS-status',$status,\@cvs_status)	if ($status);
	my @repolines = grep {/Repository revision:/} @cvs_status;
	foreach (@repolines)
	{
		chomp;
		s!.*Repository revision:.(\d+(\.\d+)+).*(pgsql/.*),v.*!$3 $1!;
	}
	@$flist = (@repolines);
}

sub find_last
{
	my $which = shift;
	my $stname = $mr_prefix . "last.$which";
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
	my $stname = $mr_prefix . "last.$which";
	my $st_now = shift || time;
	my $handle;
	open($handle,">$stname") or die "opening $stname: $!";
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
	
	unshift (@$log,
		  "Last file mtime in snapshot: ",
		  scalar(gmtime($current_snap))," GMT\n",
		  "===================================================\n");

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
	elsif ($stage ne 'CVS')
	{
		$confsum = get_config_summary();
	}

	my $savedata = Data::Dumper->Dump
		(
		 [$changed_this_run, $changed_since_success, $branch, $status,$stage,
		  $animal, $ts, $log_data, $confsum, $target, $verbose, $secret],
		 [qw(changed_this_run changed_since_success branch status stage
			 animal ts log_data confsum target verbose secret)]);
	
	my $lrname = $mr_prefix . $logdirname;

	my $txfname = "$lrname/web-txn.data";
	my $txdhandle;
	open($txdhandle,">$txfname");
	print $txdhandle $savedata;
	close($txdhandle);

	if ($nosend || $stage =~ m/CVS/ )
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

	my @logfiles = glob("$lrname/*.log");
	my %mtimes = map { $_ => (stat $_)[9] } @logfiles;
	@logfiles =  map { basename $_ } 
		( sort { $mtimes{$a} <=> $mtimes{$b} } @logfiles );
	my $logfiles = join (' ',@logfiles);
	$tar_log_cmd =~ s/\*\.log/$logfiles/;
	

	system("cd $lrname && $tar_log_cmd 2>&1 ");

	unless (-x "$aux_path/run_web_txn.pl")
	{
		print "Could not locate $aux_path/run_web_txn.pl\n";
		exit(1);
	}

	system("$aux_path/run_web_txn.pl $lrname");

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
	my $conf = {%PGBuild::conf,  # shallow copy
				script_version => $VERSION,
				invocation_args => \@invocation_args,
				steps_completed => $steps_completed,
			};
	delete $conf->{secret};
	$config .= "\n========================================================\n";
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
