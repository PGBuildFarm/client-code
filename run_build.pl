#!/usr/bin/perl

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

####################################################

=comment

 NAME: run_build.pl - script to run postgresql buildfarm

 SYNOPSIS:

  run_build.pl [option ...] [branchname]

 AUTHOR: Andrew Dunstan

 DOCUMENTATION:

  See https://wiki.postgresql.org/wiki/PostgreSQL_Buildfarm_Howto

 REPOSITORY:

  https://github.com/PGBuildFarm/client-code

=cut

###################################################

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_8';

use Config;
use Fcntl qw(:flock :seek);
use File::Path;
use File::Copy;
use File::Basename;
use File::Temp;
use File::Spec;
use IO::Handle;
use POSIX qw(:signal_h strftime);
use Data::Dumper;
use Cwd qw(abs_path getcwd);
use File::Find ();

BEGIN
{
	unshift(@INC, $ENV{BFLIB}) if $ENV{BFLIB};
	use lib File::Spec->rel2abs(dirname(__FILE__));
}

# use High Resolution stat times if the module is available
# this helps make sure we sort logfiles correctly
BEGIN
{
	eval { require Time::HiRes; Time::HiRes->import('stat'); };
}

# save a copy of the original enviroment for reporting
# save it early to reduce the risk of prior mangling
use vars qw($orig_env);

BEGIN
{
	$orig_env = {};
	while (my ($k, $v) = each %ENV)
	{

		# report all the keys but only values for whitelisted settings
		# this is to stop leaking of things like passwords
		$orig_env->{$k} = (
			(
				     $k =~ /^PG(?!PASSWORD)|MAKE|CC|CPP|CXX|LD|LD_LIBRARY_PATH/
				  || $k =~ /^(HOME|LOGNAME|USER|PATH|SHELL|LIBRAR|INCLUDE)$/
			)
			? $v
			: 'xxxxxx'
		);
	}
}

use PGBuild::SCM;
use PGBuild::Options;
use PGBuild::WebTxn;
use PGBuild::Utils qw(:DEFAULT $st_prefix $logdirname $branch_root
  $steps_completed %skip_steps %only_steps $tmpdir
  $temp_installs $devnull $send_result_routine);

$send_result_routine = \&send_res;

my $orig_dir = getcwd();
unshift @INC, $orig_dir;

# make sure we exit nicely on any normal interrupt
# so the cleanup handler gets called.
# that lets us stop the db if it's running and
# remove the inst and pgsql directories
# so the next run can start clean.

foreach my $sig (qw(INT TERM HUP QUIT))
{
	$SIG{$sig} = \&interrupt_exit;
}

# copy command line before processing - so we can later report it
# unmunged

my @invocation_args = (@ARGV);

# process the command line
PGBuild::Options::fetch_options();

die "only one of --from-source and --from-source-clean allowed"
  if ($from_source && $from_source_clean);

die "only one of --skip-steps and --only-steps allowed"
  if ($skip_steps && $only_steps);

if ($testmode)
{
	$verbose  = 1 unless $verbose;
	$forcerun = 1;
	$nostatus = 1;
	$nosend   = 1;

}

$skip_steps ||= "";
if ($skip_steps =~ /\S/)
{
	%skip_steps = map { $_ => 1 } split(/\s+/, $skip_steps);
}
$only_steps ||= "";
if ($only_steps =~ /\S/)
{
	%only_steps = map { $_ => 1 } split(/\s+/, $only_steps);
}

use vars qw($branch);
my $explicit_branch = shift;
$branch = $explicit_branch || 'HEAD';

print_help() if ($help);

#
# process config file
#
require $buildconf;

# get this here before we change directories
my @conf_stat     = stat $buildconf;
my $buildconf_mod = $conf_stat[9];

PGBuild::Options::fixup_conf(\%PGBuild::conf, \@config_set);

# default buildroot
$PGBuild::conf{build_root} ||= abs_path(dirname(__FILE__)) . "/buildroot";

# get the config data into some local variables
my (
	$buildroot,       $target,
	$animal,          $aux_path,
	$trigger_exclude, $trigger_include,
	$secret,          $keep_errs,
	$force_every,     $make,
	$optional_steps,  $use_vpath,
	$tar_log_cmd,     $using_msvc,
	$extra_config,    $make_jobs,
	$core_file_glob,  $ccache_failure_remove,
	$wait_timeout,    $use_accache,
	$use_valgrind,    $valgrind_options,
	$use_installcheck_parallel
  )
  = @PGBuild::conf{
	qw(build_root target animal aux_path trigger_exclude
	  trigger_include secret keep_error_builds force_every make optional_steps
	  use_vpath tar_log_cmd using_msvc extra_config make_jobs core_file_glob
	  ccache_failure_remove wait_timeout use_accache
	  use_valgrind valgrind_options use_installcheck_parallel)
  };

# default use_accache to on
$use_accache = 1 unless exists $PGBuild::conf{use_accache};

#default is no parallel build
$make_jobs ||= 1;

# default core file pattern is Linux, which used to be hardcoded
$core_file_glob ||= 'core*';
$PGBuild::Utils::core_file_glob = $core_file_glob;

# get check_warning from config if not on command line
$check_warnings = $PGBuild::conf{check_warnings}
  unless defined $check_warnings;

# legacy name
if (defined($PGBuild::conf{trigger_filter}))
{
	$trigger_exclude = $PGBuild::conf{trigger_filter};
}

my $scm_timeout_secs = $PGBuild::conf{scm_timeout_secs}
  || $PGBuild::conf{cvs_timeout_secs};

print scalar(localtime()), ": buildfarm run for $animal:$branch starting\n"
  if $verbose;

die "cannot use vpath with MSVC"
  if ($using_msvc and $use_vpath);

if (ref($force_every) eq 'HASH')
{
	$force_every = $force_every->{$branch} || $force_every->{default};
}

my $config_opts = $PGBuild::conf{config_opts};

use vars qw($buildport);

if (exists $PGBuild::conf{base_port})
{
	$buildport = $PGBuild::conf{base_port};
	if ($branch =~ /REL(\d+)_(\d+)/)
	{
		$buildport += (10 * ($1 - 7)) + $2;
	}
	elsif ($branch =~ /REL_(\d+)/)    # pattern used from REL_10_STABLE on
	{
		$buildport += 10 * ($1 - 7);
	}
}
else
{

	# support for legacy config style
	$buildport = $PGBuild::conf{branch_ports}->{$branch} || 5999;
}

$ENV{EXTRA_REGRESS_OPTS} = "--port=$buildport";

$tar_log_cmd ||= "tar -z -cf runlogs.tgz *.log";

$logdirname = "lastrun-logs";

if ($from_source || $from_source_clean)
{
	$from_source ||= $from_source_clean;
	$from_source = abs_path($from_source)
	  unless File::Spec->file_name_is_absolute($from_source);

	# we need to know where the lock should go, so unless the path
	# contains HEAD or they have explicitly said the branch let
	# them know where things are going.
	print
	  "branch not specified, locks, logs, ",
	  "build artefacts etc will go in HEAD\n"
	  unless ($explicit_branch || $from_source =~ m!/HEAD/!);
	$verbose ||= 1;
	$nosend     = 1;
	$nostatus   = 1;
	$logdirname = "fromsource-logs";

	if (!$from_source_clean && $use_vpath)
	{
		my $ofiles = 0;
		File::Find::find(sub { /\.o$/ && $ofiles++; }, "$from_source/src");
		if ($ofiles)
		{
			die "from source directory has object files. vpath build will fail";
		}
	}
}

my @locales;
@locales = @{ $PGBuild::conf{locales} } if exists $PGBuild::conf{locales};
unshift(@locales, 'C') unless grep { $_ eq "C" } @locales;

# sanity checks
# several people have run into these

if (`uname -s 2>&1 ` =~ /CYGWIN/i)
{
	my @procs = `ps -ef`;
	die "cygserver not running" unless (grep { /cygserver/ } @procs);
}
my $ccachedir = $PGBuild::conf{build_env}->{CCACHE_DIR};
if (!$ccachedir && $PGBuild::conf{use_default_ccache_dir})
{
	$ccachedir = "$buildroot/ccache-$animal";
	$ENV{CCACHE_DIR} = $ccachedir;
}
if ($ccachedir)
{

	# ccache is smart enough to create what you tell it is the cache dir, but
	# not smart enough to build the whole path. mkpath croaks on error, so
	# we just let it.

	mkpath $ccachedir;
	$ccachedir = abs_path($ccachedir);
}

# this should now only apply to older Msys installs. All others should
# be running with perl >= 5.8 since that's required to build postgres
# anyway. However, the Msys DTK perl doesn't handle https, but Msys2 perl
# does, so detect if it's there. If we're not sending this is all moot anyway.
my $use_auxpath = undef;

unless ($nosend)
{
	## no critic (ValuesAndExpressions::ProhibitMismatchedOperators)
	# perlcritic gets confused by version comparisons - this usage is
	# sanctioned by perldoc perlvar
	if (!$^V || $^V lt v5.8.0)
	{
		$aux_path ||= find_in_path('run_web_txn.pl');
		die "no aux_path in config file" unless $aux_path;
		$use_auxpath = 1;
	}
	elsif ($Config{osname} eq 'msys' && $target =~ /^https/)
	{
		eval { require LWP::Protocol::https; };
		if ($@)
		{
			$aux_path ||= find_in_path('run_web_txn.pl');
			die "no aux_path in config file" unless $aux_path;
			$use_auxpath = 1;
		}
	}
}

die "cannot run as root/Administrator" unless ($using_msvc or $> > 0);

$devnull = $using_msvc ? "nul" : "/dev/null";

$st_prefix = "$animal.";

# set environment from config
while (my ($envkey, $envval) = each %{ $PGBuild::conf{build_env} })
{
	$ENV{$envkey} = $envval;
}

# default value - supply unless set via the config file
# or calling environment
$ENV{PGCTLTIMEOUT} = 120 unless exists $ENV{PGCTLTIMEOUT};

# change to buildroot for this branch or die

die "no buildroot" unless $buildroot;

unless ($buildroot =~ m!^/!
	or ($using_msvc and $buildroot =~ m![a-z]:[/\\]!i))
{
	die "buildroot $buildroot not absolute";
}

mkpath $buildroot unless -d $buildroot;

die "$buildroot does not exist or is not a directory" unless -d $buildroot;

chdir $buildroot || die "chdir to $buildroot: $!";

# set up a temporary directory for extra configs, sockets etc
my $oldmask = umask;
umask 0077 unless $using_msvc;
$tmpdir = File::Temp::tempdir(
	"buildfarm-XXXXXX",
	DIR     => File::Spec->tmpdir,
	CLEANUP => 1
);
umask $oldmask unless $using_msvc;

my $scm = PGBuild::SCM->new(\%PGBuild::conf);
if (!$from_source)
{
	$scm->check_access($using_msvc);
}

mkdir $branch unless -d $branch;

chdir $branch || die "chdir to $buildroot/$branch";

# rename legacy status files/directories
foreach my $oldfile (glob("last*"))
{
	move $oldfile, "$st_prefix$oldfile";
}

$branch_root = getcwd();

my $pgsql;
if ($from_source)
{
	$pgsql = $use_vpath ? "$branch_root/pgsql.build" : $from_source;
}
else
{
	$pgsql = $scm->get_build_path($use_vpath);
}

# make sure we are using GNU make (except for MSVC)
unless ($using_msvc)
{
	die "$make is not GNU Make - please fix config file"
	  unless check_make();
}

# set up modules
foreach my $module (@{ $PGBuild::conf{modules} })
{

	# fill in the name of the module here, so use double quotes
	# so everything BUT the module name needs to be escaped
	my $str = qq!
         require PGBuild::Modules::$module;
         PGBuild::Modules::${module}::setup(
              \$buildroot,
              \$branch,
              \\\%PGBuild::conf,
              \$pgsql);
    !;

	# the string is built at runtime so there is no option but
	# to use stringy eval
	eval $str;    ## no critic (ProhibitStringyEval)

	# make errors fatal
	die $@ if $@;
}

# acquire the lock

my $lockfile;
my $have_lock;

open($lockfile, ">", "builder.LCK") || die "opening lockfile: $!";

# only one builder at a time allowed per branch
# having another build running is not a failure, and so we do not output
# a failure message under this condition.
if ($from_source)
{
	die "acquiring lock in $buildroot/$branch/builder.LCK"
	  unless flock($lockfile, LOCK_EX | LOCK_NB);
}
elsif (!flock($lockfile, LOCK_EX | LOCK_NB))
{
	print "Another process holds the lock on "
	  . "$buildroot/$branch/builder.LCK. Exiting.\n"
	  if ($verbose);
	exit(0);
}

rmtree("inst");
rmtree("$pgsql") unless ($from_source && !$use_vpath);

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
	eval {
		require BSD::Resource;
		BSD::Resource->import();

		# explicit sub calls here. using & keeps compiler happy
		my $coreok = setrlimit(&RLIMIT_CORE, &RLIM_INFINITY, &RLIM_INFINITY);
		die "setrlimit" unless $coreok;
	};
	warn "failed to unlimit core size: $@" if $@ && $verbose > 1;
}

# the time we take the snapshot
use vars qw($now);
$now = time;
my $installdir = "$buildroot/$branch/inst";
my $dbstarted;

my $extraconf;

my $main_pid = $$;
my $waiter_pid;

# cleanup handler for all exits
END
{
	# only do this block in the main process
	return unless ($main_pid == $$);

	kill('TERM', $waiter_pid) if $waiter_pid;

	# save the exit status in case $? is mangled by system() calls below
	my $exit_status = $?;

	# if we have the lock we must already be in the build root, so
	# removing things there should be safe.
	# there should only be anything to cleanup if we didn't have
	# success.

	if (   $have_lock
		&& !-d "$pgsql"
		&& $PGBuild::conf{rm_worktrees}
		&& !$from_source)
	{
		# remove work tree on success, if configured
		$scm->rm_worktree();
	}

	if ($have_lock && -d "$pgsql")
	{
		if ($dbstarted)
		{
			chdir $installdir;
			system(qq{"bin/pg_ctl" -D data stop >$devnull 2>&1});
			foreach my $loc (@locales)
			{
				next unless -d "data-$loc";
				system(qq{"bin/pg_ctl" -D "data-$loc" stop >$devnull 2>&1});
			}
			chdir $branch_root;
		}
		if (!$from_source && $keep_errs)
		{
			print "moving kept error trees\n" if $verbose;
			my $timestr = strftime "%Y-%m-%d_%H-%M-%S", localtime($now);
			unless (move("$pgsql", "pgsqlkeep.$timestr"))
			{
				print "error renaming '$pgsql' to 'pgsqlkeep.$timestr': $!";
			}
			if (-d "inst")
			{
				unless (move("inst", "instkeep.$timestr"))
				{
					print "error renaming 'inst' to 'instkeep.$timestr': $!";
				}
			}
		}
		else
		{
			rmtree("inst") unless $keepall;
			rmtree("$pgsql") unless (($from_source && !$use_vpath) || $keepall);
		}

		# only keep the cache in cases of success, if config flag is set
		if ($ccache_failure_remove)
		{
			rmtree("$ccachedir") if $ccachedir;
		}
	}

	# get the modules to clean up after themselves
	process_module_hooks('cleanup');

	if ($have_lock)
	{
		if ($use_vpath && !$from_source)
		{
			# vpath builds leave some stuff lying around in the
			# source dir, unfortunately. This should clean it up.
			$scm->cleanup();
		}
		close($lockfile);
		unlink("builder.LCK");
	}

	$? = $exit_status;
}

$waiter_pid = spawn(\&wait_timeout, $wait_timeout) if $wait_timeout;

# Prepend the DEFAULT settings (if any) to any settings for the
# branch. Since we're mangling this, deep clone $extra_config
# so the config object is kept as given. This is done using
# Dumper() because the MSys DTK perl doesn't have Storable. This
# is less efficient but it hardly matters here for this shallow
# structure.
{
	## no critic (ProhibitStringyEval)
	eval Data::Dumper->Dump([$extra_config], ['extra_config']);
}

if ($extra_config && $extra_config->{DEFAULT})
{
	if (!exists $extra_config->{$branch})
	{
		$extra_config->{$branch} = $extra_config->{DEFAULT};
	}
	else
	{
		unshift(@{ $extra_config->{$branch} }, @{ $extra_config->{DEFAULT} });
	}
}

if ($extra_config && $extra_config->{$branch})
{
	my $tmpname = "$tmpdir/bfextra.conf";
	open($extraconf, ">", "$tmpname") || die 'opening $tmpname $!';
	$ENV{TEMP_CONFIG} = $tmpname;
	foreach my $line (@{ $extra_config->{$branch} })
	{
		print $extraconf "$line\n";
	}
	autoflush $extraconf 1;
}

$steps_completed = "";

my @changed_files;
my @changed_since_success;
my $last_status;
my $last_run_snap;
my $last_success_snap;
my $current_snap;
my @filtered_files;
my $savescmlog = "";

$ENV{PGUSER} = 'buildfarm';

if ($from_source_clean)
{
	die "configure step needed for --from-source-clean"
	  unless step_wanted('configure');
	cleanlogs();    # do this here so we capture the "make dist" log
	print time_str(), "cleaning source in $pgsql ...\n";
	clean_from_source();
}
elsif (!$from_source)
{

	# see if we need to run the tests (i.e. if either something has changed or
	# we have gone over the force_every heartbeat time)

	print time_str(), "checking out source ...\n" if $verbose;

	my $timeout_pid;

	$timeout_pid = spawn(\&scm_timeout, $scm_timeout_secs)
	  if $scm_timeout_secs;

	$savescmlog      = $scm->checkout($branch);
	$steps_completed = "SCM-checkout";

	process_module_hooks('checkout', $savescmlog);

	if ($timeout_pid)
	{

		# don't kill me, I finished in time
		if (kill(SIGTERM, $timeout_pid))
		{

			# reap the zombie
			waitpid($timeout_pid, 0);
		}
	}

	print time_str(), "checking if build run needed ...\n" if $verbose;

	# transition to new time processing
	unlink "last.success";

	# get the timestamp data
	$last_status       = find_last('status') || 0;
	$last_run_snap     = find_last('run.snap');
	$last_success_snap = find_last('success.snap');
	$forcerun          = 1 unless (defined($last_run_snap));

	# updated by find_changed to last mtime of any file in the repo
	$current_snap = 0;

	# see if we need to force a build
	$last_status = 0
	  if ( $last_status
		&& $force_every
		&& $last_status + ($force_every * 3600) < $now);
	$last_status = 0 if $forcerun;

	# see what's changed since the last time we did work
	$scm->find_changed(
		\$current_snap,  $last_run_snap, $last_success_snap,
		\@changed_files, \@changed_since_success
	);

	#ignore changes to files specified by the trigger exclude filter, if any
	if (defined($trigger_exclude))
	{
		@filtered_files = grep { !m[$trigger_exclude] } @changed_files;
	}
	else
	{
		@filtered_files = @changed_files;
	}

	#ignore changes to files NOT specified by the trigger include filter, if any
	if (defined($trigger_include))
	{
		@filtered_files = grep { m[$trigger_include] } @filtered_files;
	}

	my $modules_need_run;

	process_module_hooks('need-run', \$modules_need_run);

	# if no build required do nothing
	if ($last_status && !@filtered_files && !$modules_need_run)
	{
		print time_str(),
		  "No build required: last status = ", scalar(gmtime($last_status)),
		  " GMT, current snapshot = ", scalar(gmtime($current_snap)), " GMT,",
		  " changed files = ", scalar(@filtered_files), "\n"
		  if $verbose;
		rmtree("$pgsql");
		exit 0;
	}

	# get version info on both changed files sets
	# XXX modules support?

	$scm->get_versions(\@changed_files);
	$scm->get_versions(\@changed_since_success);

}    # end of unless ($from_source)

cleanlogs() unless ($from_source_clean || !step_wanted('configure'));

writelog('SCM-checkout', $savescmlog) unless $from_source;
$scm->log_id() unless $from_source;

# copy/create according to vpath/scm settings

if ($use_vpath)
{
	print time_str(), "creating vpath build dir $pgsql ...\n" if $verbose;
	mkdir $pgsql || die "making $pgsql: $!";
}
elsif (!$from_source && $scm->copy_source_required())
{
	print time_str(), "copying source to $pgsql ...\n" if $verbose;

	$scm->copy_source($using_msvc);
}

process_module_hooks('setup-target');

# start working

set_last('status',   $now)          unless $nostatus;
set_last('run.snap', $current_snap) unless $nostatus;

my $started_times = 0;

# counter for temp installs. if it gets high enough
# (currently 3) we can set NO_TEMP_INSTALL.
$temp_installs = 0;

# each of these routines will call send_result, which calls exit,
# on any error, so each step depends on success in the previous
# steps.

if (step_wanted('configure'))
{
	print time_str(), "running configure ...\n" if $verbose;

	configure();
}

# module configure has to wait until we have built and installed the base
# so see below

make();

make_check() unless $delay_check;

# contrib is built under the standard build step for msvc
make_contrib() unless ($using_msvc);

make_testmodules()
  if (!$using_msvc && ($branch eq 'HEAD' || $branch ge 'REL9_5'));

make_doc() if (check_optional_step('build_docs'));

make_install();

# contrib is installed under standard install for msvc
make_contrib_install() unless ($using_msvc);

make_testmodules_install()
  if (!$using_msvc && ($branch eq 'HEAD' || $branch ge 'REL9_5'));

make_check() if $delay_check;

process_module_hooks('configure');

process_module_hooks('build');

process_module_hooks("check") unless $delay_check;

process_module_hooks('install');

process_module_hooks("check") if $delay_check;

run_bin_tests();

run_misc_tests();

foreach my $locale (@locales)
{
	last unless step_wanted('install');

	print time_str(), "setting up db cluster ($locale)...\n" if $verbose;

	initdb($locale);

	do
	{
		local %ENV = %ENV;
		if (!$using_msvc && $Config{osname} !~ /msys|MSWin/)
		{
			$ENV{PGHOST} = $tmpdir;
		}
		else
		{
			$ENV{PGHOST} = 'localhost';
		}

		print time_str(), "starting db ($locale)...\n" if $verbose;

		start_db($locale);

		make_install_check($locale);

		process_module_hooks('installcheck', $locale);

		if (   -d "$pgsql/src/test/isolation"
			&& $locale eq 'C'
			&& step_wanted('isolation-check'))
		{

			# restart the db to clear the log file
			print time_str(), "restarting db ($locale)...\n" if $verbose;

			stop_db($locale);
			start_db($locale);

			print time_str(), "running make isolation check ...\n" if $verbose;

			make_isolation_check($locale);
		}

		if (
			step_wanted('pl-install-check')
			&& (
				(
					!$using_msvc
					&& (grep { /--with-(perl|python|tcl)/ } @$config_opts)
				)
				|| (
					$using_msvc
					&& (   defined($config_opts->{perl})
						|| defined($config_opts->{python})
						|| defined($config_opts->{tcl}))
				)
			)
		  )
		{

			# restart the db to clear the log file
			print time_str(), "restarting db ($locale)...\n" if $verbose;

			stop_db($locale);
			start_db($locale);

			print time_str(), "running make PL installcheck ($locale)...\n"
			  if $verbose;

			make_pl_install_check($locale);
		}

		if (step_wanted('contrib-install-check'))
		{

			# restart the db to clear the log file
			print time_str(), "restarting db ($locale)...\n" if $verbose;

			stop_db($locale);
			start_db($locale);

			print time_str(), "running make contrib installcheck ($locale)...\n"
			  if $verbose;

			make_contrib_install_check($locale);
		}

		if (step_wanted('testmodules-install-check')
			&& ($branch eq 'HEAD' || $branch ge 'REL9_5'))
		{
			print time_str(), "restarting db ($locale)...\n" if $verbose;

			stop_db($locale);
			start_db($locale);

			print time_str(),
			  "running make test-modules installcheck ($locale)...\n"
			  if $verbose;

			make_testmodules_install_check($locale);
		}

		print time_str(), "stopping db ($locale)...\n" if $verbose;

		stop_db($locale);

	};    # end of do block with local %ENV

	process_module_hooks('locale-end', $locale);

	rmtree("$installdir/data-$locale")
	  unless $keepall;
}

if (step_wanted('ecpg-check'))
{
	print time_str(), "running make ecpg check ...\n" if $verbose;

	make_ecpg_check();
}

if ((check_optional_step('find_typedefs') || $find_typedefs)
	&& step_wanted('find-typedefs'))
{
	print time_str(), "running find_typedefs ...\n" if $verbose;

	find_typedefs();
}

# if we get here everything went fine ...

my $saved_config = get_config_summary();

# error out if there are non-empty valgrind logs
my @vglines = run_log("grep -l VALGRINDERROR- ${st_prefix}$logdirname/*.log");
do { $_ = basename $_; $_ =~ s/\.log$//; } foreach @vglines;
if (@vglines)
{
	unshift(@vglines,
			"=== Valgrind errors were found at the following stage(s):\n");
	send_result('Valgrind', 1, \@vglines );
}

rmtree("inst") unless $keepall;    # only keep failures
rmtree("$pgsql") unless ($keepall || ($from_source && !$use_vpath));

print(time_str(), "OK\n") if $verbose;

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
  --from-source=/path       = use source in path, not from SCM
  or
  --from-source-clean=/path = same as --from-source, run make distclean first
  --find-typedefs           = extract list of typedef symbols
  --config=/path/to/file    = alternative location for config file
  --keepall                 = keep directories if an error occurs
  --verbose[=n]             = verbosity (default 1) 2 or more = huge output.
  --quiet                   = suppress normal error messages
  --test                    = short for --nosend --nostatus --verbose --force
  --skip-steps=list         = skip certain steps
  --only-steps=list         = only do certain steps, not allowed with skip-steps
  --schedule=name           = use different schedule in check and installcheck
  --tests=list              = just run these tests in chak and installcheck
  --check-warnings          = turn compiler warnings into errors
  --delay-check             = defer check step until after install steps

Default branch is HEAD. Usually only the --config option should be necessary.

!;
	exit(0);
}

sub check_optional_step
{
	my $step = shift;
	my $oconf;

	return unless ref($oconf = $optional_steps->{$step});
	if ($oconf->{branches})
	{
		return unless grep { $_ eq $branch } @{ $oconf->{branches} };
	}

	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) =
	  localtime(time);
	return if (exists $oconf->{min_hour} && $hour < $oconf->{min_hour});
	return if (exists $oconf->{max_hour} && $hour > $oconf->{max_hour});
	return
	  if (exists $oconf->{dow}
		&& grep { $_ eq $wday } @{ $oconf->{dow} });

	my $last_step = $last_status = find_last("$step") || 0;

	return
	  if (exists($oconf->{min_hours_since})
		&& time < $last_step + (3600 * $oconf->{min_hours_since}));
	set_last("$step") unless $nostatus;

	return 1;
}

sub clean_from_source
{
	my $command;
	if ($using_msvc)
	{
		$command = "cd $pgsql && src\\tools\\msvc\\clean dist";
	}
	else
	{
		$command = "cd $pgsql && $make distclean";
	}

	my @makeout = run_log($command);
	my $status  = $? >> 8;
	writelog('distclean', \@makeout);
	print "======== distclean log ===========\n", @makeout if ($verbose > 1);
	send_result('distclean', $status, \@makeout) if $status;
	return;
}

sub interrupt_exit
{
	my $signame = shift;
	print "Exiting on signal $signame\n";
	exit(1);
}

sub check_make
{
	my @out = run_log("$make -v");
	return unless ($? == 0 && grep { /GNU Make/ } @out);
	return 'OK';
}

sub make
{
	return unless step_wanted('make');
	print time_str(), "running make ...\n" if $verbose;

	my (@makeout);
	unless ($using_msvc)
	{
		my $make_cmd = $make;
		$make_cmd = "$make -j $make_jobs"
		  if ($make_jobs > 1);
		@makeout = run_log("cd $pgsql && $make_cmd");
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = run_log("perl build.pl");
		chdir $branch_root;
	}
	my $status = $? >> 8;
	writelog('make', \@makeout);
	print "======== make log ===========\n", @makeout if ($verbose > 1);
	$status ||= check_make_log_warnings('make', $verbose) if $check_warnings;
	send_result('Make', $status, \@makeout) if $status;
	$steps_completed .= " Make";
	return;
}

sub make_doc
{
	return unless step_wanted('make-doc');
	print time_str(), "running make doc ...\n" if $verbose;

	my (@makeout);
	unless ($using_msvc)
	{
		@makeout = run_log("cd $pgsql/doc && $make");
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = run_log("perl builddoc.pl");
		chdir $branch_root;
	}
	my $status = $? >> 8;
	writelog('make-doc', \@makeout);
	print "======== make doc log ===========\n", @makeout if ($verbose > 1);
	send_result('Doc', $status, \@makeout) if $status;
	$steps_completed .= " Doc";
	return;
}

sub make_install
{
	return unless step_wanted('install');
	print time_str(), "running make install ...\n" if $verbose;

	my @makeout;
	unless ($using_msvc)
	{
		@makeout = run_log("cd $pgsql && $make install");
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = run_log(qq{perl install.pl "$installdir"});
		chdir $branch_root;
	}
	my $status = $? >> 8;
	writelog('make-install', \@makeout);
	print "======== make install log ===========\n", @makeout if ($verbose > 1);
	send_result('Install', $status, \@makeout) if $status;

	# On Windows and Cygwin avoid path problems associated with DLLs
	# by copying them to the bin dir where the system will pick them
	# up regardless.

	foreach my $dll (glob("$installdir/lib/*pq.dll"))
	{
		my $dest = "$installdir/bin/" . basename($dll);
		copy($dll, $dest);
		chmod 0755, $dest;
	}

	# make sure the installed libraries come first in dynamic load paths

	if (my $ldpath = $ENV{LD_LIBRARY_PATH})
	{
		$ENV{LD_LIBRARY_PATH} = "$installdir/lib:$ldpath";
	}
	else
	{
		$ENV{LD_LIBRARY_PATH} = "$installdir/lib";
	}
	if (my $ldpath = $ENV{DYLD_LIBRARY_PATH})
	{
		$ENV{DYLD_LIBRARY_PATH} = "$installdir/lib:$ldpath";
	}
	else
	{
		$ENV{DYLD_LIBRARY_PATH} = "$installdir/lib";
	}
	if ($using_msvc)
	{
		$ENV{PATH} = "$installdir/bin;$ENV{PATH}";
	}
	else
	{
		$ENV{PATH} = "$installdir/bin:$ENV{PATH}";
	}

	$steps_completed .= " Install";
	return;
}

sub make_contrib
{

	# part of build under msvc
	return unless step_wanted('make') && step_wanted('make-contrib');
	print time_str(), "running make contrib ...\n" if $verbose;

	my $make_cmd = $make;
	$make_cmd = "$make -j $make_jobs"
	  if ($make_jobs > 1);
	my @makeout = run_log("cd $pgsql/contrib && $make_cmd");
	my $status  = $? >> 8;
	writelog('make-contrib', \@makeout);
	print "======== make contrib log ===========\n", @makeout if ($verbose > 1);
	$status ||= check_make_log_warnings('make-contrib', $verbose)
	  if $check_warnings;
	send_result('Contrib', $status, \@makeout) if $status;
	$steps_completed .= " Contrib";
	return;
}

sub make_testmodules
{
	return unless step_wanted('testmodules');
	print time_str(), "running make testmodules ...\n" if $verbose;

	my $make_cmd = $make;
	$make_cmd = "$make -j $make_jobs"
	  if ($make_jobs > 1);
	my @makeout = run_log("cd $pgsql/src/test/modules && $make_cmd");
	my $status  = $? >> 8;
	writelog('make-testmodules', \@makeout);
	print "======== make testmodules log ===========\n", @makeout
	  if ($verbose > 1);
	$status ||= check_make_log_warnings('make-testmodules', $verbose)
	  if $check_warnings;
	send_result('TestModules', $status, \@makeout) if $status;
	$steps_completed .= " TestModules";
	return;
}

sub make_contrib_install
{
	return
	  unless (step_wanted('make-contrib')
		and step_wanted('install'));
	print time_str(), "running make contrib install ...\n"
	  if $verbose;

	# part of install under msvc
	my $tmp_inst = abs_path($pgsql) . "/tmp_install";
	my $cmd =
	  "cd $pgsql/contrib && $make install && $make DESTDIR=$tmp_inst install";
	my @makeout = run_log($cmd);
	my $status  = $? >> 8;
	writelog('install-contrib', \@makeout);
	print "======== make contrib install log ===========\n", @makeout
	  if ($verbose > 1);
	send_result('ContribInstall', $status, \@makeout) if $status;
	$temp_installs++;
	$steps_completed .= " ContribInstall";
	return;
}

sub make_testmodules_install
{
	return
	  unless (step_wanted('testmodules')
		and step_wanted('install'));
	print time_str(), "running make testmodules install ...\n"
	  if $verbose;

	my $tmp_inst = abs_path($pgsql) . "/tmp_install";
	my $cmd      = "cd $pgsql/src/test/modules  && "
	  . "$make install && $make DESTDIR=$tmp_inst install";
	my @makeout = run_log($cmd);
	my $status  = $? >> 8;
	writelog('install-testmodules', \@makeout);
	print "======== make testmodules install log ===========\n", @makeout
	  if ($verbose > 1);
	send_result('TestModulesInstall', $status, \@makeout) if $status;
	$temp_installs++;
	$steps_completed .= " TestModulesInstall";
	return;
}

sub initdb
{
	my $locale = shift;
	$started_times = 0;
	my @initout;

	my $abspgsql = File::Spec->rel2abs($pgsql);

	chdir $installdir;

	@initout =
	  run_log(qq{"bin/initdb" -U buildfarm --locale=$locale data-$locale});

	my $status = $? >> 8;

	if (!$status)
	{
		my $handle;
		open($handle, ">>", "$installdir/data-$locale/postgresql.conf")
		  || die "opening $installdir/data-$locale/postgresql.conf: $!";

		if (!$using_msvc && $Config{osname} !~ /msys|MSWin/)
		{
			my $param = "unix_socket_directories";
			print $handle "$param = '$tmpdir'\n";
			print $handle "listen_addresses = ''\n";
		}
		else
		{
			print $handle "listen_addresses = 'localhost'\n";
		}

		foreach my $line (@{ $extra_config->{$branch} })
		{
			print $handle "$line\n";
		}
		close($handle);

		if ($using_msvc || $Config{osname} =~ /msys|MSWin/)
		{
			my $pg_regress;

			if ($using_msvc)
			{
				$pg_regress = "$abspgsql/Release/pg_regress/pg_regress";
				unless (-e "$pg_regress.exe")
				{
					$pg_regress =~ s/Release/Debug/;
				}
			}
			else
			{
				$pg_regress = "$abspgsql/src/test/regress/pg_regress";
			}
			my $roles =
			  $branch ne 'HEAD' && $branch lt 'REL9_5'
			  ? "buildfarm,dblink_regression_test"
			  : "buildfarm";
			my $setauth = "--create-role $roles --config-auth";
			my @lines   = run_log("$pg_regress $setauth data-$locale");
			$status = $? >> 8;
			push(@initout, "======== set config-auth ======\n", @lines);
		}

	}

	chdir $branch_root;

	writelog("initdb-$locale", \@initout);
	print "======== initdb log ($locale) ===========\n", @initout
	  if ($verbose > 1);
	send_result("Initdb-$locale", $status, \@initout) if $status;
	$steps_completed .= " Initdb-$locale";
	return;
}

sub start_valgrind_db
{
	# run the postmaster under valgrind.
	# subroutine is run in a child process.

	print "starting under valgrind\n";

	my $locale          = shift;
	my $vgstarted_times = shift;
	chdir 'inst';
	my $source = $from_source || '../pgsql';
	open(STDOUT, ">", "logfile") || die "opening valgrind log";
	open(STDERR, ">&STDOUT")    # allowed by perlcritic
	  || die "duping STDOUT for valgrind";
	my $supp  = "--suppressions=$source/src/tools/valgrind.supp";
	my $markers = "--error-markers=VALGRINDERROR-BEGIN,VALGRINDERROR-END";
	my $pgcmd = "bin/postgres -D data-$locale";
	system("valgrind $valgrind_options $supp $markers $pgcmd");
	return $? >>8 ;
}

sub start_db
{

	my $locale = shift;
	$started_times++;
	if (-e "$installdir/logfile")
	{

		# give Windows some breathing room if necessary
		sleep(5) if $Config{osname} =~ /msys|MSWin|cygwin/;
		unlink "$installdir/logfile";
		sleep(5) if $Config{osname} =~ /msys|MSWin|cygwin/;
	}

	if ($use_valgrind)
	{
		# can't use pg_ctl with valgrind, so we spawn a child process to run
		# the postmaster. We don't wait for it, it will be shut down when we
		# call stop_db and reaped when the main run ends.

		spawn(\&start_valgrind_db, $locale, $started_times);

		# postmaster takes a while to start up under valgrind.
		# We need to wait for it. We need to see the pid and socket files
		# before continuing.

		my $pidfile    = "$installdir/data-$locale/postmaster.pid";
		my $socketfile = "$tmpdir/.s.PGSQL.$buildport";

		# wait until the database has started. Under valgrind it can
		# take a while
		foreach (1 .. 600)
		{
			last if -e $pidfile && -e $socketfile;
			sleep 1;
		}
		die "cannot find $pidfile and $socketfile"
		  unless -e $pidfile
		  && -e $socketfile;

		# wait until we can ping the database. can also take a while
		foreach (1 .. 100)
		{
			system(
				"$installdir/bin/psql -c 'select 1' postgres > /dev/null 2>&1");
			last unless $?;
			sleep(1);
		}
	}
	else
	{
		# must use -w here or we get horrid FATAL errors from trying to
		# connect before the db is ready
		# clear log file each time we start
		# seem to need an intermediate file here to get round Windows bogosity

		chdir($installdir);
		my $cmd =
		  qq{"bin/pg_ctl" -D data-$locale -l logfile -w start >startlog 2>&1};
		system($cmd);
	}

	my $status = $? >> 8;
	chdir($branch_root);

	my @ctlout = ();
	@ctlout = file_lines("$installdir/startlog")
	  if -s "$installdir/startlog";

	if (-s "$installdir/logfile")
	{
		my @loglines = file_lines("$installdir/logfile");
		push(@ctlout, "=========== db log file ==========\n", @loglines);
	}
	writelog("startdb-$locale-$started_times", \@ctlout);
	print "======== start db ($locale) : $started_times log ========\n", @ctlout
	  if ($verbose > 1);
	if ($status)
	{
		chdir($installdir);
		system(qq{"bin/pg_ctl" -D data-$locale stop >/dev/null 2>&1});
		chdir($branch_root);
		send_result("StartDb-$locale:$started_times", $status, \@ctlout);
	}
	$dbstarted = 1;
	return;
}

sub stop_db
{
	my $locale = shift;
	my $logpos = -s "$installdir/logfile" || 0;
	chdir($installdir);
	my $cmd = qq{"bin/pg_ctl" -D data-$locale stop >stoplog 2>&1};
	system($cmd);
	my $status = $? >> 8;
	chdir($branch_root);
	if ($use_valgrind)
	{
        # Valgrind might take a while to stop
        # We need to wait for it. We need to see the absences of the
		# pid and socket files before continuing.

        my $pidfile = "$installdir/data-$locale/postmaster.pid";
        my $socketfile = "$tmpdir/.s.PGSQL.$buildport";

        foreach (1..600)
        {
            last unless ( -e $pidfile || -e $socketfile);
            sleep 1;
        }
        die "still have $pidfile or $socketfile"
          if -e $pidfile
          || -e $socketfile;
	}
	my @ctlout = file_lines("$installdir/stoplog");

	if (-s "$installdir/logfile")
	{
		# get contents from where log file ended before we tried to shut down.
		my @loglines = file_lines("$installdir/logfile", $logpos);
		push(@ctlout, "=========== db log file ==========\n", @loglines);
	}
	writelog("stopdb-$locale-$started_times", \@ctlout);
	print "======== stop db ($locale): $started_times log ==========\n", @ctlout
	  if ($verbose > 1);
	send_result("StopDb-$locale:$started_times", $status, \@ctlout) if $status;
	$dbstarted = undef;
	return;
}

sub make_install_check
{
	my $locale = shift;
	return unless step_wanted('install-check');
	print time_str(), "running make installcheck ($locale)...\n" if $verbose;

	my @checklog;
	unless ($using_msvc)
	{
		my $chktarget =
		  $use_installcheck_parallel
		  ? 'installcheck-parallel'
		  : 'installcheck';
		if ($schedule && -s $schedule)
		{
			$chktarget =
			  'TESTS=--schedule=' . abs_path($schedule) . " installcheck-tests";
		}
		elsif ($tests)
		{
			$chktarget = 'TESTS=' . qq{"$tests"} . " installcheck-tests";
		}
		@checklog = run_log("cd $pgsql/src/test/regress && $make $chktarget");
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@checklog = run_log("perl vcregress.pl installcheck");
		chdir $branch_root;
	}
	my $status = $? >> 8;
	my @logfiles =
	  ("$pgsql/src/test/regress/regression.diffs", "$installdir/logfile");
	foreach my $logfile (@logfiles)
	{
		next unless (-e $logfile);
		push(@checklog, "\n\n================== $logfile ==================\n");
		push(@checklog, file_lines($logfile));
	}
	if ($status)
	{
		my @trace =
		  get_stack_trace("$installdir/bin", "$installdir/data-$locale");
		push(@checklog, @trace);
	}
	writelog("install-check-$locale", \@checklog);
	print "======== make installcheck log ===========\n", @checklog
	  if ($verbose > 1);
	send_result("InstallCheck-$locale", $status, \@checklog) if $status;
	$steps_completed .= " InstallCheck-$locale";
	return;
}

sub make_contrib_install_check
{
	my $locale = shift;
	return unless step_wanted('contrib-install-check');
	my @checklog;
	unless ($using_msvc)
	{
		@checklog =
		  run_log("cd $pgsql/contrib && $make USE_MODULE_DB=1 installcheck");
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@checklog = run_log("perl vcregress.pl contribcheck");
		chdir $branch_root;
	}
	my $status = $? >> 8;
	my @logs   = glob("$pgsql/contrib/*/regression.diffs");
	push(@logs, "$installdir/logfile");
	foreach my $logfile (@logs)
	{
		next unless (-e $logfile);
		push(@checklog, "\n\n================= $logfile ===================\n");
		push(@checklog, file_lines($logfile));
	}
	if ($status)
	{
		my @trace =
		  get_stack_trace("$installdir/bin", "$installdir/data-$locale");
		push(@checklog, @trace);
	}
	writelog("contrib-install-check-$locale", \@checklog);
	print "======== make contrib installcheck log ===========\n", @checklog
	  if ($verbose > 1);
	send_result("ContribCheck-$locale", $status, \@checklog) if $status;
	$steps_completed .= " ContribCheck-$locale";
	return;
}

sub make_testmodules_install_check
{
	my $locale = shift;
	return unless step_wanted('testmodules-install-check');
	my @checklog;
	unless ($using_msvc)
	{
		my $cmd =
		  "cd $pgsql/src/test/modules && $make USE_MODULE_DB=1 installcheck";
		@checklog = run_log($cmd);
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@checklog = run_log("perl vcregress.pl modulescheck");
		chdir $branch_root;
	}
	my $status = $? >> 8;
	my @logs   = glob("$pgsql/src/test/modules/*/regression.diffs");
	push(@logs, "$installdir/logfile");
	foreach my $logfile (@logs)
	{
		next unless (-e $logfile);
		push(@checklog, "\n\n================= $logfile ===================\n");
		push(@checklog, file_lines($logfile));
	}
	if ($status)
	{
		my @trace = get_stack_trace("$installdir/bin", "$installdir/data");
		push(@checklog, @trace);
	}
	writelog("testmodules-install-check-$locale", \@checklog);
	print "======== make testmodules installcheck log ===========\n", @checklog
	  if ($verbose > 1);
	send_result("TestModulesCheck-$locale", $status, \@checklog) if $status;
	$steps_completed .= " TestModulesCheck-$locale";
	return;
}

sub make_pl_install_check
{
	my $locale = shift;
	return unless step_wanted('pl-install-check');
	my @checklog;
	unless ($using_msvc)
	{
		@checklog = run_log("cd $pgsql/src/pl && $make installcheck");
	}
	else
	{
		chdir("$pgsql/src/tools/msvc");
		@checklog = run_log("perl vcregress.pl plcheck");
		chdir($branch_root);
	}
	my $status = $? >> 8;
	my @logs   = (
		glob("$pgsql/src/pl/*/regression.diffs"),
		glob("$pgsql/src/pl/*/*/regression.diffs")
	);
	push(@logs, "$installdir/logfile");
	foreach my $logfile (@logs)
	{
		next unless (-e $logfile);
		push(@checklog, "\n\n================= $logfile ===================\n");
		push(@checklog, file_lines($logfile));
	}
	if ($status)
	{
		my @trace =
		  get_stack_trace("$installdir/bin", "$installdir/data-$locale");
		push(@checklog, @trace);
	}
	writelog("pl-install-check-$locale", \@checklog);
	print "======== make pl installcheck log ===========\n", @checklog
	  if ($verbose > 1);
	send_result("PLCheck-$locale", $status, \@checklog) if $status;

	# only report PLCheck as a step if it actually tried to do anything
	$steps_completed .= " PLCheck-$locale"
	  if (grep { /pg_regress|Checking pl/ } @checklog);
	return;
}

sub make_isolation_check
{
	my $locale = shift;
	return unless step_wanted('isolation-check');
	my @makeout;
	unless ($using_msvc)
	{
		my $cmd =
		  "cd $pgsql/src/test/isolation && $make NO_LOCALE=1 installcheck";
		@makeout = run_log($cmd);
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = run_log("perl vcregress.pl isolationcheck");
		chdir $branch_root;
	}

	my $status = $? >> 8;

	# get the log files and the regression diffs
	my @logs = glob("$pgsql/src/test/isolation/log/*.log");
	push(@logs, "$installdir/logfile");
	unshift(@logs, "$pgsql/src/test/isolation/regression.diffs")
	  if (-e "$pgsql/src/test/isolation/regression.diffs");
	unshift(@logs, "$pgsql/src/test/isolation/output_iso/regression.diffs")
	  if (-e "$pgsql/src/test/isolation/output_iso/regression.diffs");
	foreach my $logfile (@logs)
	{
		push(@makeout, "\n\n================== $logfile ===================\n");
		push(@makeout, file_lines($logfile));
	}
	if ($status)
	{
		my @trace =
		  get_stack_trace("$installdir/bin", "$installdir/data-$locale");
		push(@makeout, @trace);
	}
	writelog('isolation-check', \@makeout);
	print "======== make isolation check logs ===========\n", @makeout
	  if ($verbose > 1);

	send_result('IsolationCheck', $status, \@makeout) if $status;
	$steps_completed .= " IsolationCheck";
	return;
}

sub run_tap_test
{
	my $dir              = shift;
	my $testname         = shift;
	my $is_install_check = shift;

	my $taptarget = $is_install_check ? "installcheck" : "check";

	return unless step_wanted("$testname-$taptarget");

	# fix path temporarily on msys
	my $save_path = $ENV{PATH};
	if ($Config{osname} eq 'msys' && $branch ne 'HEAD' && $branch lt 'REL_10')
	{
		my $perlpathdir = dirname($Config{perlpath});
		$ENV{PATH} = "$perlpathdir:$ENV{PATH}";
	}

	my @makeout;

	my $pflags = "PROVE_FLAGS=--timer";
	if (exists $ENV{PROVE_FLAGS})
	{
		$pflags =
		  $ENV{PROVE_FLAGS}
		  ? "PROVE_FLAGS=$ENV{PROVE_FLAGS}"
		  : "";
	}

	if ($using_msvc)
	{
		my $test = substr($dir, length("$pgsql/"));
		chdir "$pgsql/src/tools/msvc";
		@makeout = run_log("perl vcregress.pl taptest $pflags $test");
		chdir $branch_root;
	}
	else
	{
		my $instflags = $temp_installs >= 3 ? "NO_TEMP_INSTALL=yes" : "";

		@makeout =
		  run_log("cd $dir && $make NO_LOCALE=1 $pflags $instflags $taptarget");
	}

	my $status = $? >> 8;

	my @logs = glob("$dir/tmp_check/log/*");

	foreach my $logfile (@logs)
	{
		push(@makeout, "\n\n================== $logfile ===================\n");
		push(@makeout, file_lines($logfile));
	}

	writelog("$testname-$taptarget", \@makeout);
	print "======== make $testname-$taptarget log ===========\n", @makeout
	  if ($verbose > 1);

	# restore path
	$ENV{PATH} = $save_path;

	my $captarget = $is_install_check ? "InstallCheck" : "Check";
	my $captest = $testname;

	send_result("$captest$captarget", $status, \@makeout) if $status;
	$steps_completed .= " $captest$captarget";
	return;
}

sub run_bin_tests
{
	return unless step_wanted('bin-check');

	# tests only came in with 9.4
	return unless ($branch eq 'HEAD' or $branch ge 'REL9_4');

	# don't run unless the tests have been enabled
	if ($using_msvc)
	{
		return unless $config_opts->{tap_tests};
	}
	else
	{
		return unless grep { $_ eq '--enable-tap-tests' } @$config_opts;
	}

	print time_str(), "running bin checks ...\n" if $verbose;

	foreach my $bin (glob("$pgsql/src/bin/*"))
	{
		next unless -d "$bin/t";
		run_tap_test($bin, basename($bin), undef);
	}
	return;
}

sub run_misc_tests
{
	return unless step_wanted('misc-check');

	# tests only came in with 9.4
	return unless ($branch eq 'HEAD' or $branch ge 'REL9_4');

	# don't run unless the tests have been enabled
	if ($using_msvc)
	{
		return unless $config_opts->{tap_tests};
	}
	else
	{
		return unless grep { $_ eq '--enable-tap-tests' } @$config_opts;
	}

	print time_str(), "running make misc checks ...\n" if $verbose;

	foreach my $test (qw(recovery subscription authentication))
	{
		next unless -d "$pgsql/src/test/$test/t";
		run_tap_test("$pgsql/src/test/$test", $test, undef);
	}
	return;
}

sub make_check
{
	return unless step_wanted('check');
	print time_str(), "running make check ...\n" if $verbose;

	my @makeout;
	unless ($using_msvc)
	{
		my $chktarget = "check";
		if ($schedule && -s $schedule)
		{
			$chktarget =
			  'TESTS=--schedule=' . abs_path($schedule) . " check-tests";
		}
		elsif ($tests)
		{
			$chktarget = 'TESTS=' . qq{"$tests"} . " check-tests";
		}

		@makeout =
		  run_log("cd $pgsql/src/test/regress && $make NO_LOCALE=1 $chktarget");
	}
	else
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = run_log("perl vcregress.pl check");
		chdir $branch_root;
	}

	my $status = $? >> 8;

	# get the log files and the regression diffs
	my @logs =
	  glob("$pgsql/src/test/regress/log/*.log $pgsql/tmp_install/log/*");
	unshift(@logs, "$pgsql/src/test/regress/regression.diffs")
	  if (-e "$pgsql/src/test/regress/regression.diffs");
	foreach my $logfile (@logs)
	{
		push(@makeout, "\n\n================== $logfile ===================\n");
		push(@makeout, file_lines($logfile));
	}
	my $base = "$pgsql/src/test/regress/tmp_check";
	if ($status)
	{
		my $binloc =
		  -d "$pgsql/tmp_install"
		  ? "$pgsql/tmp_install"
		  : "$base/install";
		my @trace = get_stack_trace("$binloc$installdir/bin", "$base/data");
		push(@makeout, @trace);
	}
	else
	{
		rmtree($base)
		  unless $keepall;
	}
	writelog('check', \@makeout);
	print "======== make check logs ===========\n", @makeout
	  if ($verbose > 1);

	send_result('Check', $status, \@makeout) if $status;
	$temp_installs++;
	if ($using_msvc)
	{
		# MSVC installs everything, so we now have a complete temp install
		$ENV{NO_TEMP_INSTALL} = "yes";
	}
	$steps_completed .= " Check";
	return;
}

sub make_ecpg_check
{
	return unless step_wanted('ecpg-check');
	my @makeout;
	my $ecpg_dir = "$pgsql/src/interfaces/ecpg";
	if ($using_msvc)
	{
		chdir "$pgsql/src/tools/msvc";
		@makeout = run_log("perl vcregress.pl ecpgcheck");
		chdir $branch_root;
	}
	else
	{
		my $instflags = $temp_installs >= 3 ? "NO_TEMP_INSTALL=yes" : "";
		@makeout =
		  run_log("cd  $ecpg_dir && $make NO_LOCALE=1 $instflags check");
	}
	my $status = $? >> 8;

	# get the log files and the regression diffs
	my @logs = glob("$ecpg_dir/test/log/*.log");
	unshift(@logs, "$ecpg_dir/test/regression.diffs")
	  if (-e "$ecpg_dir/test/regression.diffs");
	foreach my $logfile (@logs)
	{
		push(@makeout, "\n\n================== $logfile ===================\n");
		push(@makeout, file_lines($logfile));
	}
	if ($status)
	{
		my $base = "$ecpg_dir/test/regress/tmp_check";
		my @trace =
		  get_stack_trace("$base/install$installdir/bin", "$base/data");
		push(@makeout, @trace);
	}
	writelog('ecpg-check', \@makeout);
	print "======== make ecpg check logs ===========\n", @makeout
	  if ($verbose > 1);

	send_result('ECPG-Check', $status, \@makeout) if $status;
	$steps_completed .= " ECPG-Check";
	return;
}

sub find_typedefs
{
	my ($hostobjdump) = grep { /--host=/ } @$config_opts;
	$hostobjdump ||= "";
	$hostobjdump =~ s/--host=(.*)/$1-objdump/;
	my $objdump = 'objdump';
	my $sep = $using_msvc ? ';' : ':';

	# if we have a hostobjdump, find out which of it and objdump is in the path
	foreach my $p (split(/$sep/, $ENV{PATH}))
	{
		last unless $hostobjdump;
		last if (-e "$p/objdump" || -e "$p/objdump.exe");
		if (-e "$p/$hostobjdump" || -e "$p/$hostobjdump.exe")
		{
			$objdump = $hostobjdump;
			last;
		}
	}
	my @err        = `$objdump -W 2>&1`;
	my @readelferr = `readelf -w 2>&1`;
	my $using_osx  = (`uname` eq "Darwin\n");
	my @testfiles;
	my %syms;
	my @dumpout;
	my @flds;

	if ($using_osx)
	{

		# On OS X, we need to examine the .o files
		# exclude ecpg/test, which pgindent does too
		my $obj_wanted = sub {
			/^.*\.o\z/s
			  && !($File::Find::name =~ m!/ecpg/test/!s)
			  && push(@testfiles, $File::Find::name);
		};

		File::Find::find($obj_wanted, $pgsql);
	}
	else
	{

		# Elsewhere, look at the installed executables and shared libraries
		@testfiles = (
			glob("$installdir/bin/*"),
			glob("$installdir/lib/*"),
			glob("$installdir/lib/postgresql/*")
		);
	}
	foreach my $bin (@testfiles)
	{
		next if $bin =~ m!bin/(ipcclean|pltcl_)!;
		next unless -f $bin;
		if (@err == 1)    # Linux and sometimes windows
		{
			my $cmd = "$objdump -W $bin 2>/dev/null | "
			  . "egrep -A3 DW_TAG_typedef 2>/dev/null";
			@dumpout = `$cmd`;    # no run_log because of redirections
			foreach (@dumpout)
			{
				@flds = split;
				next unless (1 < @flds);
				next
				  if (($flds[0] ne 'DW_AT_name' && $flds[1] ne 'DW_AT_name')
					|| $flds[-1] =~ /^DW_FORM_str/);
				$syms{ $flds[-1] } = 1;
			}
		}
		elsif (@readelferr > 10)
		{

			# FreeBSD, similar output to Linux
			my $cmd = "readelf -w $bin 2>/dev/null | "
			  . "egrep -A3 DW_TAG_typedef 2>/dev/null";

			@dumpout = ` $cmd`;    # no run_log due to redirections
			foreach (@dumpout)
			{
				@flds = split;
				next unless (1 < @flds);
				next if ($flds[0] ne 'DW_AT_name');
				$syms{ $flds[-1] } = 1;
			}
		}
		elsif ($using_osx)
		{
			# no run_log due to redirections.
			@dumpout =
			  `dwarfdump $bin 2>/dev/null | egrep -A2 TAG_typedef 2>/dev/null`;
			foreach (@dumpout)
			{
				@flds = split;
				next unless (@flds == 3);
				next unless ($flds[0] eq "AT_name(");
				next unless ($flds[1] =~ m/^"(.*)"$/);
				## no critic (RegularExpressions::ProhibitCaptureWithoutTest)
				$syms{$1} = 1;
			}
		}
		else
		{
			# no run_log doe to redirections.
			@dumpout = `$objdump --stabs $bin 2>/dev/null`;
			foreach (@dumpout)
			{
				@flds = split;
				next if (@flds < 7);
				next if ($flds[1] ne 'LSYM' || $flds[6] !~ /([^:]+):t/);
				## no critic (RegularExpressions::ProhibitCaptureWithoutTest)
				$syms{$1} = 1;
			}
		}
	}
	my @badsyms = grep { /\s/ } keys %syms;
	push(@badsyms, 'date', 'interval', 'timestamp', 'ANY');
	delete @syms{@badsyms};

	my @goodsyms = sort keys %syms;
	my @foundsyms;

	my %foundwords;

	my $setfound = sub {

		# $_ is the name of the file being examined
		# its directory is our current cwd

		return unless (-f $_ && /^.*\.[chly]\z/);
		my @lines;
		my $src = file_contents($_);

		# strip C comments
		# We used to use the recipe in perlfaq6 but there is actually no point.
		# We don't need to keep the quoted string values anyway, and
		# on some platforms the complex regex causes perl to barf and crash.
		$src =~ s{/\*.*?\*/}{}gs;

		foreach my $word (split(/\W+/, $src))
		{
			$foundwords{$word} = 1;
		}
	};

	File::Find::find($setfound, "$branch_root/pgsql");

	foreach my $sym (@goodsyms)
	{
		push(@foundsyms, "$sym\n") if exists $foundwords{$sym};
	}

	writelog('typedefs', \@foundsyms);
	$steps_completed .= " find-typedefs";
	return;
}

sub configure
{

	if ($using_msvc)
	{
		my $lconfig = { %$config_opts, "--with-pgport" => $buildport };
		my $conf = Data::Dumper->Dump([$lconfig], ['config']);
		my @text = (
			"# Configuration arguments for vcbuild.\n",
			"# written by buildfarm client \n",
			"use strict; \n",
			"use warnings;\n",
			"our $conf \n",
			"1;\n"
		);

		my $handle;
		open($handle, ">", "$pgsql/src/tools/msvc/config.pl")
		  || die "opening $pgsql/src/tools/msvc/config.pl: $!";
		print $handle @text;
		close($handle);

		push(@text, "# no configure step for MSCV - config file shown\n");

		writelog('configure', \@text);

		$steps_completed .= " Configure";

		return;
	}

	my @quoted_opts;
	foreach my $c_opt (@$config_opts)
	{
		if ($c_opt =~ /['"]/)
		{
			push(@quoted_opts, $c_opt);
		}
		else
		{
			push(@quoted_opts, "'$c_opt'");
		}
	}

	my $confstr = join(" ",
		@quoted_opts, "--prefix=$installdir", "--with-pgport=$buildport");

	if ($use_accache)
	{
		# set up cache directory for autoconf cache
		my $accachedir = "$buildroot/accache-$animal";
		mkpath $accachedir;
		$accachedir = abs_path($accachedir);

		# remove old cache file if configure script is newer
		# in the case of from_source, or has been changed for this run
		# or the run is forced, in the usual build from git case
		my $accachefile = "$accachedir/config-$branch.cache";
		if (-e $accachefile)
		{
			my $obsolete;
			my @cache_stat = stat $accachefile;
			my $cache_mod  = $cache_stat[9];
			if ($from_source)
			{
				my $conffile      = "$from_source/configure";
				my @conffile_stat = stat $conffile;
				$obsolete = -e $conffile && $conffile_stat[9] > $cache_mod;
			}
			else
			{
				$obsolete = grep { /^configure / } @changed_files;
				$obsolete ||= $last_status == 0;
			}

			# also remove if the buildfarm config file is newer, or the options
			# have been changed via --config_set.
			#
			# we currently don't allow overriding the config file
			# environment settings via --config-set, but if we did
			# we'd have to account for that here too.
			#
			# if the user alters the environment that's set externally
			# for the buildfarm we can't really do anything about that.
			$obsolete ||= grep { /config_opts/ } @config_set;
			$obsolete ||= $buildconf_mod > $cache_mod;

			unlink $accachefile if $obsolete;
		}
		$confstr .= " --cache-file='$accachefile'";
	}

	my $env = $PGBuild::conf{config_env};

	my $envstr = "";
	while (my ($key, $val) = each %$env)
	{
		$envstr .= "$key='$val' ";
	}

	my $conf_path =
	  $use_vpath
	  ? ($from_source ? "$from_source/configure" : "../pgsql/configure")
	  : "./configure";

	my @confout = run_log("cd $pgsql && $envstr $conf_path $confstr");

	my $status = $? >> 8;

	print "======== configure output ===========\n", @confout
	  if ($verbose > 1);

	writelog('configure', \@confout);

	my (@config);

	if (-s "$pgsql/config.log")
	{
		@config = file_lines("$pgsql/config.log");
		writelog('config', \@config);
	}

	if ($status)
	{

		push(@confout,
			"\n\n================= config.log ================\n\n", @config);

		send_result('Configure', $status, \@confout);
	}

	if ($use_vpath && $from_source)
	{
		# vpath construction copies stuff from the source directory including
		# the buildroot stucture if it's there. Clean it up. This is not
		# necessary except in from-source builds because otherwise we would
		# have already checked that the directory was git-clean. This stuff
		# is not harmful but it can be confusing.
		my $bfdir = basename $buildroot;
		rmtree("$pgsql/$bfdir") if -d "$pgsql/bfdir";
	}

	$steps_completed .= " Configure";
	return;
}

# a reference to this subroutine is stored in the Utils module and it is called
# everywhere as send_result(...)

sub send_res
{

	my $stage = shift;

	my $ts     = $now  || time;
	my $status = shift || 0;
	my $log    = shift || [];
	print "======== log passed to send_result ===========\n", @$log
	  if ($verbose > 1)
	  or ($status && $show_error_log);

	unshift(@$log,
		"Last file mtime in snapshot: ",
		scalar(gmtime($current_snap)),
		" GMT\n", "===================================================\n")
	  unless ($from_source || !$current_snap);

	my $log_data              = join("", @$log);
	my $confsum               = "";
	my $changed_this_run      = "";
	my $changed_since_success = "";
	$changed_this_run = join("!", @changed_files)
	  if @changed_files;
	$changed_since_success = join("!", @changed_since_success)
	  if ($stage ne 'OK' && @changed_since_success);

	if ($stage eq 'OK')
	{
		$confsum = $saved_config;
	}
	elsif ($stage !~ /CVS|Git|SCM|Pre-run-port-check/)
	{
		$confsum = get_config_summary();
	}
	else
	{
		$confsum = get_script_config_dump();
	}

	my $savedata = Data::Dumper->Dump(
		[
			$changed_this_run, $changed_since_success, $branch, $status, $stage,
			$animal, $ts, $log_data, $confsum, $target, $verbose, $secret
		],
		[
			qw(changed_this_run changed_since_success branch status stage
			  animal ts log_data confsum target verbose secret)
		]
	);

	my $lrname = $st_prefix . $logdirname;

	# might happen if there is a CVS failure and have never got further
	mkdir $lrname unless -d $lrname;

	my $txfname = "$lrname/web-txn.data";
	my $txdhandle;
	open($txdhandle, ">", "$txfname") || die "opening $txfname: $!";
	print $txdhandle $savedata;
	close($txdhandle);

	if ($nosend || $stage eq 'CVS' || $stage eq 'CVS-status')
	{
		print "Branch: $branch\n";
		if ($stage eq 'OK')
		{
			print "All stages succeeded\n";
			set_last('success.snap', $current_snap) unless $nostatus;
			exit(0);
		}
		else
		{
			print "Stage $stage failed with status $status\n";
			exit(1);
		}
	}

	if ($stage !~ /CVS|Git|SCM|Pre-run-port-check/)
	{

		chdir($lrname);
		my @logfiles = glob("*.log");
		my %mtimes = map { my @st = stat $_; $_ => $st[9] } @logfiles;
		@logfiles = sort { $mtimes{$a} <=> $mtimes{$b} } @logfiles;
		my $logfiles = join(' ', @logfiles);
		$tar_log_cmd =~ s/\*\.log/$logfiles/;
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

	my $txstatus;

	if ($use_auxpath)
	{

		unless (-x "$aux_path/run_web_txn.pl")
		{
			print "Could not locate $aux_path/run_web_txn.pl\n";
			exit(1);
		}

		$ENV{PERL5LIB} = $aux_path;
		system("$aux_path/run_web_txn.pl $lrname");
		$txstatus = $? >> 8;
	}
	else
	{
		$txstatus = PGBuild::WebTxn::run_web_txn($lrname) ? 0 : 1;

	}

	if ($txstatus)
	{
		print "Web txn failed with status: $txstatus\n";

		# if the web txn fails, restore the timestamps
		# so we try again the next time.
		set_last('status',   $last_status)   unless $nostatus;
		set_last('run.snap', $last_run_snap) unless $nostatus;
		exit($txstatus);
	}

	unless ($stage eq 'OK' || $quiet)
	{
		print "Buildfarm member $animal failed on $branch stage $stage\n";
	}

	set_last('success.snap', $current_snap) if ($stage eq 'OK' && !$nostatus);

	exit 0;
}

sub get_config_summary
{
	my $config = "";

	# if configure bugs out there might not be a log file at all
	# in that case just return the rest of the summary.

	unless ($using_msvc || !-e "$pgsql/config.log")
	{
		my @lines = file_lines("$pgsql/config.log");
		my $start = undef;
		foreach (@lines)
		{
			if (!$start && /created by PostgreSQL configure/)
			{
				$start = 1;
				s/It was/This file was/;
			}
			next unless $start;
			last if /Core tests/;
			next if /^\#/;
			next if /= <?unknown>?/;

			# split up long configure line
			if (m!\$.*configure.*--with!)
			{
				foreach my $lpos (70, 140, 210, 280, 350, 420)
				{
					my $pos = index($_, " ", $lpos);
					substr($_, $pos + 1, 0, "\\\n        ") if ($pos > 0);
				}
			}
			$config .= $_;
		}
		$config .=
		  "\n========================================================\n";
	}
	$config .= get_script_config_dump();
	return $config;
}

sub get_script_config_dump
{
	my $conf = {
		%PGBuild::conf,    # shallow copy
		script_version  => $VERSION,
		invocation_args => \@invocation_args,
		steps_completed => [ split(/\s+/, $steps_completed) ],
		orig_env        => $orig_env,
		bf_perl_version => "$Config{version}",
	};
	delete $conf->{secret};
	my @modkeys = grep { /^PGBuild/ } keys %INC;
	foreach (@modkeys)
	{
		s!/!::!g;
		s/\.pm$//;
	}
	my %versions;
	foreach my $mod (sort @modkeys)
	{
		## no critic (ProhibitStringyEval)
		my $str = "\$versions{'$mod'} = \$${mod}::VERSION;";
		eval $str;
	}
	$conf->{module_versions} = \%versions;
	return Data::Dumper->Dump([$conf], ['Script_Config']);
}

sub scm_timeout
{
	my $wait_time   = shift;
	my $who_to_kill = getpgrp(0);
	my $sig         = SIGTERM;
	$sig = -$sig;
	print "waiting $wait_time secs to time out process $who_to_kill\n"
	  if $verbose;
	foreach my $sig (qw(INT TERM HUP QUIT))
	{
		$SIG{$sig} = 'DEFAULT';
	}
	sleep($wait_time);
	$SIG{TERM} = 'IGNORE';    # so we don't kill ourself, we're exiting anyway
	                          # kill the whole process group
	unless (kill $sig, $who_to_kill)
	{
		print "scm timeout kill failed\n";
	}
	return;
}

sub silent_terminate
{
	exit 0;
}

sub wait_timeout
{
	my $wait_time = shift;
	$waiter_pid = $$;
	foreach my $sig (qw(INT HUP QUIT))
	{
		$SIG{$sig} = 'DEFAULT';
	}
	$SIG{'TERM'} = \&silent_terminate;
	sleep($wait_time);
	kill 'TERM', $main_pid;
	return;
}

sub spawn
{
	my $coderef = shift;
	my $pid     = fork;
	if (defined($pid) && $pid == 0)
	{
		# call this rather than plain exit so we don't run the
		# END handler. see `perldoc -f exit`
		POSIX::_exit(&$coderef(@_));
	}
	return $pid;
}
