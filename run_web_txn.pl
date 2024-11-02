#!/c/perl/bin/perl

=comment

Copyright (c) 2003-2024, Andrew Dunstan

See accompanying License file for license details

=cut

###################################################
#
# part of postgresql buildfarm suite.
#
#
# The comments blow now only apply to installations that can't run the web
# transaction using the perl used for the scripts. Mostly this is msys
# perls lacking LWP::Protocol::https.
#
# All other installations now do not need to set aux_path, nor should this
# script be called.
#
# auxiliary script to get around the
# fact that the SDK perl for MSys can't do the web
# transaction part. On Windows the shebang line
# must be set to a perl that has the required packages below.
# I have only tested with ActiveState perl, and on my Windows machine
# the line reads: #!/c/perl/bin/perl
#
# Unix  and Cygwin users should set the shebang line to be the same
# as the one in run_build.pl.
#
# All users need to set the aux_path setting in their config files
# to be an absolute or relative path to this script. If relative, then
# it must be relative to <buildroot>/<$branch>. The reason for this crazy
# setup is so that this script does not need to change directory
# at all, which lets us get around virtual path craziness that we
# encounter on MSys.
#
######################################################

use strict;
use warnings;

our ($VERSION); $VERSION = 'REL_17';

use FindBin;
use lib $FindBin::RealBin;

use PGBuild::WebTxn;

my $lrname = $ARGV[0] || 'lastrun-logs';

my $res = PGBuild::WebTxn::run_web_txn($lrname);

if ($res)
{
	exit 0;
}
else
{
	exit 1;
}

