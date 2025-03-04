
package PGBuild::Utils;

=comment

Copyright (c) 2003-2024, Andrew Dunstan

See accompanying License file for license details

=cut

# utility routines for the buildfarm

use strict;
use warnings;

use Carp;
use Config;
use Fcntl      qw(:seek);
use File::Find qw();
use File::Path 'mkpath';
use File::Copy;
use File::Temp qw(tempfile);

our ($VERSION); $VERSION = 'REL_19_1';

## no critic (ProhibitAutomaticExportation)
use Exporter qw(import);
our (@EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@EXPORT = qw(run_log time_str process_module_hooks register_module_hooks
  get_stack_trace cleanlogs writelog
  set_last find_last step_wanted send_result
  file_lines file_contents check_make_log_warnings
  find_in_path $log_file_marker set_last_stage get_last_stage
  check_install_is_complete spawn save_install copydir
  rmtree
);
%EXPORT_TAGS = qw();
@EXPORT_OK = qw($st_prefix $logdirname $branch_root $steps_completed
  %skip_steps %only_steps $tmpdir $devnull $send_result_routine $ts_prefix
);

my %module_hooks;
our (
	$core_file_glob, $st_prefix, $logdirname, $branch_root,
	$steps_completed, %skip_steps, %only_steps, $tmpdir,
	$send_result_routine, $devnull, $log_file_marker, $ts_prefix,
);

my $saved;    # have we already saved the binaries

BEGIN
{
	$log_file_marker = "==~_~===-=-===~_~==";
	$ts_prefix = "";
}

# wrap the main program's send_res routine (formerly send_result)
sub send_result
{
	# shouldn't return, but keep perlcritic happy.
	return &$send_result_routine(@_);
}

# something like IPC::RUN but without requiring it, as some installations
# lack it.

sub run_log
{
	my $command = shift;
	my $filedir = "$branch_root/$st_prefix$logdirname";
	mkpath($filedir);
	my $file = "$filedir/lastcommand.log";
	my $stfile = "$filedir/laststatus";
	unlink $file;
	unlink $stfile;

	if ($Config{osname} eq 'MSWin32')
	{
		# can't use more robust Unix shell syntax with DOS shell
		system("$command >$file 2>&1");
	}
	else
	{
		my $ucmd = "{ $command; echo \$? > $stfile; }";
		my $getstat = "read st < $stfile; exit \$st";

		if ($ENV{BF_LOG_TIME} && -x "/usr/bin/ts")
		{
			# this somewhat convoluted syntax ensures $? will be the exit
			# status of the command
			system("$ucmd 2>&1 | /usr/bin/ts > $file; $getstat");
		}
		else
		{
			# not actually necessary in this case but done this way
			# for uniformity
			system("$ucmd > $file 2>&1; $getstat");
		}
	}
	unlink $stfile;
	my @loglines;
	if (-e $file)
	{
		# shouldn't fail, but I've seen it, so die if it does
		open(my $handle, '<', $file) || die "opening $file for $command: $!";
		@loglines = <$handle>;
		close $handle;

		# the idea is if we're interrupted the file will still be there
		# but if we get here the command has run to completion and we can
		# just return the rows and remove the file.
		# in theory there's a small race condition here
		unlink $file;
	}
	return wantarray ? @loglines : "@loglines";
}

sub time_str
{
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) =
	  localtime(time);
	return sprintf("%s[%.2d:%.2d:%.2d] ", $ts_prefix, $hour, $min, $sec);
}

sub register_module_hooks
{
	my $who = shift;
	my $what = shift;
	while (my ($hook, $func) = each %$what)
	{
		$module_hooks{$hook} ||= [];
		push(@{ $module_hooks{$hook} }, [ $func, $who ]);
	}
	return;
}

sub process_module_hooks
{
	my $hook = shift;

	# pass remaining args (if any) to module func
	foreach my $module (@{ $module_hooks{$hook} })
	{
		my ($func, $module_instance) = @$module;
		&$func($module_instance, @_);
	}
	return;
}

sub get_stack_trace_cygwin
{
	my $bindir = shift;
	my $pgdata = shift;

	my @cores;

	if (-e "$pgdata/postgresql.conf")
	{
		@cores = glob("$pgdata/*.stackdump");
	}
	else
	{
		# if this isn't a data directory, go hunting for subdirectories
		# that are data directories and then look in those for core files
		my @datadirs;
		my $wanted =
		  sub { $_ eq 'postgresql.conf' && push @datadirs, $File::Find::dir; };
		File::Find::find($wanted, $pgdata);
		foreach my $dir (@datadirs)
		{
			push(@cores, glob("$dir/*.stackdump"));
		}
	}

	# no core = no result
	return () unless @cores;

	my @trace = ("\n\n");

	foreach my $stacktrace (@cores)
	{
		my @lines = file_lines($stacktrace);
		my @addrs;
		foreach my $line (@lines)
		{
			next unless $line =~ /^[[:xdigit:]]+\s+([[:xdigit:]]+)\s/;
			push(@addrs, "$1\n");
		}
		my ($addrfile, $addrfilename) = tempfile("stackaddrXXXX");
		print $addrfile @addrs;
		close $addrfile;
		my @tracelines = `addr2line -f -e $bindir/postgres.exe < $addrfilename`;
		do { s!.*/src/!src/!; }
		  foreach @tracelines;
		push @trace,
		  "$log_file_marker stack trace: $stacktrace $log_file_marker\n",
		  @lines, "\n---- backtrace ----\n", @tracelines;
	}

	return @trace;
}

sub get_stack_trace
{
	return get_stack_trace_cygwin(@_) if ($ENV{CYGWIN});

	my $bindir = shift;
	my $pgdata = shift;

	return () unless -d $pgdata;

	my @cores;

	if (-e "$pgdata/postgresql.conf")
	{
		@cores = glob("$pgdata/$core_file_glob");
	}
	else
	{
		# if this isn't a data directory, go hunting for subdirectories
		# that are data directories and then look in those for core files
		my @datadirs;
		my $wanted =
		  sub { $_ eq 'postgresql.conf' && push @datadirs, $File::Find::dir; };
		File::Find::find($wanted, $pgdata);
		foreach my $dir (@datadirs)
		{
			push(@cores, glob("$dir/$core_file_glob"));
		}
	}

	# no core = no result
	return () unless @cores;

	# no gdb = no result
	system "gdb --version > $devnull 2>&1";
	my $status = $? >> 8;
	return () if $status;

	my $cmdfile = "./gdbcmd";
	my $handle;
	open($handle, '>', $cmdfile) || die "opening $cmdfile: $!";
	print $handle "bt\n";
	print $handle 'p $_siginfo', "\n";
	close($handle);

	my @trace = ("\n\n");

	foreach my $core (@cores)
	{
		my @onetrace =
		  run_log("gdb -x $cmdfile --batch $bindir/postgres $core");
		push(@trace,
			"$log_file_marker stack trace: $core $log_file_marker\n",
			@onetrace);
	}

	unlink $cmdfile;

	return @trace;
}

sub cleanlogs
{
	my $lrname = $st_prefix . $logdirname;
	rmtree("$lrname");
	mkdir "$lrname" || die "can't make $lrname dir: $!";
	return;
}

sub writelog
{
	my $stage = shift;
	my $fname = "$stage.log";
	my $loglines = shift;
	my $handle;
	my $lrname = $st_prefix . $logdirname;
	open($handle, '>', "$lrname/$fname") || die "opening $lrname/$fname: $!";
	print $handle @$loglines;
	close($handle);
	return;
}

sub check_make_log_warnings
{
	my $stage = shift;
	my $verbose = shift;
	my $fname = "$stage.log";
	my $lrname = $st_prefix . $logdirname;
	my @lines = grep { /(?<!-)warning/i } file_lines("$lrname/$fname");
	print "Found warnings:\n", @lines if $verbose && @lines;
	return scalar(@lines);
}

# get a file as a list of lines

sub file_lines
{
	my $filename = shift;
	my $filepos = shift;
	my $handle;
	open($handle, '<', $filename) || croak "opening $filename: $!";
	seek($handle, $filepos, SEEK_SET) if $filepos;
	my @lines = <$handle>;
	close $handle;
	return @lines;
}

# get a file as a single string

sub file_contents
{
	my $filename = shift;
	my $filepos = shift;
	my $handle;
	open($handle, '<', $filename) || croak "opening $filename: $!";
	seek($handle, $filepos, SEEK_SET) if $filepos;
	local $/ = undef;
	my $contents = <$handle>;
	close $handle;
	return $contents;
}

sub find_last
{
	my $which = shift;
	my $stname = $st_prefix . "last.$which";
	my $handle;
	open($handle, '<', $stname) or return;
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
	open($handle, '>', $stname) or die "opening $stname: $!";
	print $handle "$st_now\n";
	close($handle);
	return;
}

sub set_last_stage
{
	my $stage = shift;
	my $stname = $st_prefix . "last.stage";
	my $handle;
	open($handle, '>', $stname) or die "opening $stname: $!";
	print $handle "$stage\n";
	close($handle);
	return;
}

sub get_last_stage
{
	my $stname = $st_prefix . "last.stage";
	return unless -e $stname;
	my $handle;
	open($handle, '<', $stname) or die "opening $stname: $!";
	my $stage = <$handle>;
	close($handle);
	chomp $stage;
	return $stage;
}


sub step_wanted
{
	my $step = shift;
	return $only_steps{$step} if (keys %only_steps);
	return !$skip_steps{$step} if (keys %skip_steps);
	return 1;    # default is everything is wanted
}

sub find_in_path
{
	my $what = shift;
	my $sep = $Config{path_sep};
	my @elements;
	if ($sep eq ';')
	{
		@elements = split(/;/, $ENV{PATH});
	}
	else
	{
		@elements = split(/:/, $ENV{PATH});
	}
	foreach my $pathelem (@elements)
	{
		return File::Spec->rel2abs($pathelem) if -f "$pathelem/$what";
	}
	return;
}

sub check_install_is_complete
{
	my $build_dir = shift;
	my $install_dir = shift;

	# settings that apply for MSVC
	my $tmp_loc = "$build_dir/tmp_install";
	my $bindir = "$tmp_loc/bin";
	my $libdir = "$tmp_loc/lib";
	my $suffix = '.dll';

	# adjust settings for non-MSVC

	# use a simplified test for meson - where we always install everything
	if (-e "$build_dir/meson-private")
	{
		$tmp_loc = "$tmp_loc/$install_dir";
		$bindir = "$tmp_loc/bin";
		$libdir = "$tmp_loc/lib";
		$libdir .= '/postgresql' unless $install_dir =~ /postgres|pgsql/;
		return (-d $bindir && -d $libdir);
	}
	elsif (-e "$build_dir/src/Makefile.global")    # i.e. not msvc
	{
		no warnings qw(once);
		my $make = $PGBuild::conf{make};
		$suffix = `cd $build_dir && $make show_dl_suffix`;
		chomp $suffix;
		$tmp_loc = "$tmp_loc/$install_dir";
		$bindir = "$tmp_loc/bin";
		$libdir = "$tmp_loc/lib";
		$libdir .= '/postgresql' unless $install_dir =~ /postgres|pgsql/;
	}

	# these files should be present if we've temp_installed everything,
	# and not if we haven't. The represent core, contrib and test_modules.
	my $res =
	  (      (-d $tmp_loc)
		  && (-f "$bindir/postgres" || -f "$bindir/postgres.exe")
		  && (-f "$libdir/hstore$suffix")
		  && (-f "$libdir/test_parser$suffix"));
	return $res;
}

sub spawn
{
	my $coderef = shift;
	my $pid = fork;
	if (defined($pid) && $pid == 0)
	{
		# call this rather than plain exit so we don't run the
		# END handler. see `perldoc -f exit`
		POSIX::_exit(&$coderef(@_));
	}
	return $pid;
}

sub save_install
{
	my $buildroot = shift;
	my $branch = shift;
	my $pgsql = shift;
	my $logfile = shift;
	my $prefix = shift;
	my $animal = $PGBuild::conf{animal};

	my $dest = "$buildroot/$prefix.$animal/$branch";

	if (!$saved)
	{
		rmtree($dest) if -d $dest;

		mkpath $dest;

		my $installdir = "$buildroot/$branch/inst";

		foreach my $idir (qw(bin lib share include))
		{
			copydir("$installdir/$idir", "$dest/$idir", "$logfile");
			return if $?;
		}

		$saved = 1;
	}

	return $dest;
}

sub copydir
{
	my ($from, $to, $logfile) = @_;
	my ($cp, $rd);
	if ($PGBuild::conf{using_msvc})
	{
		$cp = "robocopy /nfl /ndl /np /e /sec ";
		$rd = qq{/LOG+:"$logfile" >nul};
	}
	else
	{
		$cp = "cp -r";
		$rd = qq{> "$logfile"};
	}
	system(qq{$cp "$from" "$to" $rd 2>&1});
	## no critic (RequireLocalizedPunctuationVars)
	$? = 0 if ($cp =~ /robocopy/ && $? >> 8 == 1);
	return;
}

sub rmtree
{
	my $dir = shift;

	return unless -d $dir;

	# some Windows perls choke when calling rmtree if there are junctions
	# so we provide our own.
	if ($PGBuild::conf{using_msvc})
	{
		system(qq{rmdir /q /s "$dir"});
	}
	else
	{
		File::Path::rmtree($dir);
	}
	return;
}

1;
