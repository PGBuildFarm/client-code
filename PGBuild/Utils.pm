
package PGBuild::Utils;

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

# utility routines for the buildfarm

use strict;
use warnings;

use Config;
use File::Path;

use Exporter   ();
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

use vars qw($VERSION); $VERSION = 'REL_5';

@ISA         = qw(Exporter);
@EXPORT      = qw(run_log);
%EXPORT_TAGS = ();
@EXPORT_OK   = ();

# something like IPC::RUN but without requiring it, as some installations
# lack it.

sub run_log
{
    no warnings qw(once);

    my $command = shift;
    my $filedir = "$main::branch_root/$main::st_prefix$main::logdirname";
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

1;
