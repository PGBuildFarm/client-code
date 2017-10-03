
package PGBuild::Utils;

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

# utility routines for the buildfarm

use strict;
use warnings;

use Carp;
use Config;
use Fcntl qw(:seek);
use File::Path;

use Exporter   ();
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

use vars qw($VERSION); $VERSION = 'REL_5';

@ISA         = qw(Exporter);
@EXPORT      = qw(run_log time_str process_module_hooks register_module_hooks
				  get_stack_trace cleanlogs writelog 
				  set_last find_last step_wanted send_result
				  file_lines file_contents
				);
%EXPORT_TAGS = qw();
@EXPORT_OK   = qw($st_prefix $logdirname $branch_root $steps_completed
				  %skip_steps %only_steps $tmpdir $temp_installs $devnull
				  $send_result_routine
				);

my %module_hooks;
use vars qw($core_file_glob $st_prefix $logdirname $branch_root 
			$steps_completed %skip_steps %only_steps $tmpdir $temp_installs
			$send_result_routine $devnull
		  );

# wrap the main program's send_res routine (formerly send_result)
sub send_result
{
	&$send_result_routine(@_);
}

# something like IPC::RUN but without requiring it, as some installations
# lack it.

sub run_log
{
    no warnings qw(once);

    my $command = shift;
    my $filedir = "$branch_root/$st_prefix$logdirname";
    mkpath($filedir);
    my $file= "$filedir/lastcomand.log";
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
        open(my $handle,$file) || die "opening $file for $command: $!";
        @loglines = <$handle>;
        close $handle;

        # the idea is if we're interrupted the file will still be there
        # but if we get here the command has run to completion and we can
        # just return the rows and remove the file.
        # in theory there's a small race condition here
        unlink $file;
    }
    return @loglines;
}

sub time_str
{
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    return sprintf("[%.2d:%.2d:%.2d] ",$hour, $min, $sec);
}

sub register_module_hooks
{
    my $who = shift;
    my $what = shift;
    while (my ($hook,$func) = each %$what)
    {
        $module_hooks{$hook} ||= [];
        push(@{$module_hooks{$hook}},[$func,$who]);
    }
}

sub process_module_hooks
{
    my $hook = shift;

    # pass remaining args (if any) to module func
    foreach my $module (@{$module_hooks{$hook}})
    {
        my ($func,$module_instance) = @$module;
        &$func($module_instance, @_);
    }
}


sub get_stack_trace
{
    my $bindir = shift;
    my $pgdata = shift;

    # no core = no result
    my @cores = glob("$pgdata/$core_file_glob");
    return () unless @cores;

    # no gdb = no result
    system "gdb --version > $devnull 2>&1";
    my $status = $? >>8;
    return () if $status;

    my $cmdfile = "./gdbcmd";
    my $handle;
    open($handle, ">$cmdfile") || die "opening $cmdfile: $!";
    print $handle "bt\n";
    close($handle);

    my @trace;

    foreach my $core (@cores)
    {
        my @onetrace =run_log("gdb -x $cmdfile --batch $bindir/postgres $core");
        push(@trace,
            "\n\n================== stack trace: $core ==================\n",
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
}

sub writelog
{
    my $stage = shift;
    my $fname = "$stage.log";
    my $loglines = shift;
    my $handle;
    my $lrname = $st_prefix . $logdirname;
    open($handle,">$lrname/$fname") || die "opening $lrname/$fname: $!";
    print $handle @$loglines;
    close($handle);
}

# get a file as a list of lines

sub file_lines
{
	my $filename = shift;
	my $filepos = shift;
	my $handle;
	open($handle, $filename) || croak "opening $filename: $!";
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
	open($handle, $filename) || croak "opening $filename: $!";
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

sub step_wanted
{
    my $step = shift;
    return $only_steps{$step} if (keys %only_steps);
    return !$skip_steps{$step} if (keys %skip_steps);
    return 1; # default is everything is wanted
}

1;
