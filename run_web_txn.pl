#!/usr/bin/perl

###################################################
#
# part of postgresql buildfarm suite.
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
# setup is so that thhis script does not need to change directory
# at all, which lets us get around virtual path craziness that we
# encounter on MSys.
#
######################################################



use strict;

use vars qw($VERSION); $VERSION = 'REL_4.3';

#  q$Id: run_web_txn.pl,v 1.8 2010/11/07 23:35:04 andrewd Exp $

use LWP;
use HTTP::Request::Common;
use MIME::Base64;
use Digest::SHA1  qw(sha1_hex);
use Storable qw(nfreeze);

my $lrname = $ARGV[0] || 'lastrun-logs' ;


use vars qw($changed_this_run $changed_since_success $branch $status $stage
	$animal $ts $log_data $confsum $target $verbose $secret);

my $txfname = "$lrname/web-txn.data";
my $txdhandle;
$/=undef;
open($txdhandle,"$txfname") or die "opening $txfname: $!";
my $txdata = <$txdhandle>;
close($txdhandle);

eval $txdata; die $@ if $@;

my $tarname = "$lrname/runlogs.tgz";
my $tardata="";
if (open($txdhandle,$tarname))
{
	binmode $txdhandle;
	$tardata=<$txdhandle>;
	close($txdhandle);
}

# add our own version string and time
my $current_ts = time;
my $webscriptversion = "'web_script_version' => '$VERSION',\n" ;
my $cts	= "'current_ts' => $current_ts,\n";
# $2 here helps us to preserve the nice spacing from Data::Dumper
my $scriptline = "((.*)'script_version' => '(REL_)?\\d+\\.\\d+',\n)";
$confsum =~ s/$scriptline/$1$2$webscriptversion$2$cts/;
my $sconf = $confsum;
$sconf =~ s/.*(\$Script_Config)/$1/ms;
my $Script_Config;
eval $sconf;
my $frozen_sconf = nfreeze $Script_Config;

# make the base64 data escape-proof; = is probably ok but no harm done
# this ensures that what is seen at the other end is EXACTLY what we
# see when we calculate the signature

map 
{ $_=encode_base64($_,""); tr/+=/$@/; } 
($log_data,$confsum,$changed_this_run,$changed_since_success,$tardata, 
 $frozen_sconf);

my $content = 
	"changed_files=$changed_this_run&".
	"changed_since_success=$changed_since_success&".
	"branch=$branch&res=$status&stage=$stage&animal=$animal&ts=$ts".
	"&log=$log_data&conf=$confsum";
my $sig= sha1_hex($content,$secret);

$content .= "&frozen_sconf=$frozen_sconf";

if ($tardata)
{
	$content .= "&logtar=$tardata";
}

my $ua = new LWP::UserAgent;
$ua->agent("Postgres Build Farm Reporter");
if (my $proxy = $ENV{BF_PROXY})
{
	$ua->proxy('http',$proxy);
}


my $request=HTTP::Request->new(POST => "$target/$sig");
$request->content_type("application/x-www-form-urlencoded");
$request->content($content);


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
