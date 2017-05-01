
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

use vars qw($VERSION); $VERSION = 'REL_4.19';

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
    unlink $file;

	if ($Config{osname} eq 'MSWin32')
	{
		# can't use more robust Unix shell syntax with DOS shell
		system("$command >$file 2>&1");
	}
	elsif ($ENV{BF_LOG_TIME} && -x "/usr/bin/ts")
	{
		system("{ $command;} 2>&1 | /usr/bin/ts > $file");
	}
	else
	{
		system("{ $command;} > $file 2>&1");
	}
    my @loglines;
    if (-e $file)
    {
        open(my $handle,$file);
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
