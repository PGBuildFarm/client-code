
package PGBuild::Utils;

=comment

Copyright (c) 2003-2010, Andrew Dunstan

See accompanying License file for license details

=cut 

# utility routines for the buildfarm

use strict;
use warnings;

use Exporter   ();
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

use vars qw($VERSION); $VERSION = 'REL_4.15.1';

@ISA         = qw(Exporter);
@EXPORT      = qw(run_log);
%EXPORT_TAGS = ();
@EXPORT_OK   = ();

# something like IPC::RUN but without requiring it, as some installations
# lack it.

sub run_log
{
    my $command = shift;
    my $file=
      "$main::branch_root/$main::st_prefix$main::logdirname/lastcomand.log";
    unlink $file;
    system("$command > $file 2>&1");
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
