#!/usr/bin/perl

=comment

Copyright (c) 2022, Andrew Dunstan

See accompanying License file for license details

=cut

use strict;
use warnings;

our ($VERSION); $VERSION = 'REL_17';

use LWP;
use HTTP::Request::Common;
use MIME::Base64;
use Digest::SHA qw(sha1_hex);
use Getopt::Long;

use FindBin;
use lib $FindBin::RealBin;

BEGIN
{
	unshift(@INC, $ENV{BFLIB}) if $ENV{BFLIB};
}

# copy command line before processing - so we can later report it
# unmunged

my @invocation_args = (@ARGV);

my $buildconf = "build-farm.conf";    # default value
my ($help);
my ($enable, $disable);

GetOptions(
	'config=s' => \$buildconf,
	'help' => \$help,
	'enable' => \$enable,
	'disable' => \$disable,
) || usage("bad command line");

usage("No extra args allowed")
  if @_;

usage("Only one of --enable and --disable allowed")
  if (defined $enable && defined $disable);

my $enable_op = $enable || 0;    # default is disable

usage()
  if $help;

# dummy branch in case it's used by the config file
our ($branch) = 'HEAD';

#
# process config file
#
require $buildconf;

my ($target, $animal, $secret, $upgrade_target) =
  @PGBuild::conf{qw(target animal secret upgrade_target)};

$target =~ s/pgstatus.pl/manage_alerts.pl/;

my $ts = time;

my $content = "animal=$animal\&ts=$ts";
$content = "$content\&op=enable" if $enable_op;

my $sig = sha1_hex($content, $secret);

# set environment from config
while (my ($envkey, $envval) = each %{ $PGBuild::conf{build_env} })
{
	$ENV{$envkey} = $envval;
}

my $ua = LWP::UserAgent->new;
$ua->agent("Postgres Build Farm Reporter");
if (my $proxy = $ENV{BF_PROXY})
{
	my $targetURI = URI->new($target);
	$ua->proxy($targetURI->scheme, $proxy);
}

my $request = HTTP::Request->new(POST => "$target/$sig");
$request->content_type("application/x-www-form-urlencoded");
$request->content($content);

my $response = $ua->request($request);

unless ($response->is_success)
{
	print
	  "Query for: animal=$animal&ts=$ts\n",
	  "Target: $target/$sig\n",
	  "Query Content: $content\n";
	print "Status Line: ", $response->status_line, "\n";
	print "Content: \n", $response->content, "\n";
	exit 1;
}

if ($enable_op)
{
	print "Alerts enabled\n";
}
else
{
	print "Alerts disabled\n";
}

exit(0);

#######################################################################

sub usage
{
	my $opt_message = shift;
	print "$opt_message\n" if $opt_message;
	print <<'EOH';
manage_alerts.pl [ option ... ]
where option is one or more of
  --config=path                 /path/to/buildfarm.conf
  --help                        get this message
  --disable                     disable alerts (default)
  --enable                      enable_alerts
EOH

	exit defined($opt_message) + 0;
}

