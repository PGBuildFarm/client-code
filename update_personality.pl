#!/usr/bin/perl

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

use strict;
use warnings;
# suppress spurious warning about conf structure
no warnings qw(once);

use vars qw($VERSION); $VERSION = 'REL_7';

use LWP;
use HTTP::Request::Common;
use MIME::Base64;
use Digest::SHA  qw(sha1_hex);
use Getopt::Long;
use File::Spec;
use File::Basename;

BEGIN { use lib File::Spec->rel2abs(dirname(__FILE__)); }

# copy command line before processing - so we can later report it
# unmunged

my @invocation_args = (@ARGV);

my $buildconf = "build-farm.conf"; # default value
my ($os_version, $compiler_version,$help);

GetOptions(
    'config=s' => \$buildconf,
    'help' => \$help,
    'os-version=s' => \$os_version,
    'compiler-version=s' => \$compiler_version,
)|| usage("bad command line");

usage("No extra args allowed")
  if @_;

usage()
  if $help;

usage("must specify at least one item to change")
  unless ($os_version or $compiler_version);

# dummy branch in case it's used by the config file
our($branch) = 'HEAD';

#
# process config file
#
require $buildconf;

my ($target,$animal,$secret,$upgrade_target) =
  @PGBuild::conf{qw(target animal secret upgrade_target)};

# default for old config files
unless ($upgrade_target)
{
    $upgrade_target = $target;
    $upgrade_target =~ s/pgstatus.pl/upgrade.pl/;
}

# make the base64 data escape-proof; = is probably ok but no harm done
# this ensures that what is seen at the other end is EXACTLY what we
# see when we calculate the signature

do { $_ ||= ""; $_ = encode_base64($_,""); tr/+=/$@/; }
  foreach ($os_version,$compiler_version);

my $ts = time;

my $content = "animal=$animal\&ts=$ts";
$content .= "\&new_os=$os_version" if $os_version;
$content .= "\&new_compiler=$compiler_version" if $compiler_version;

my $sig= sha1_hex($content,$secret);

# set environment from config
while (my ($envkey,$envval) = each %{$PGBuild::conf{build_env}})
{
    $ENV{$envkey}=$envval;
}

my $ua = LWP::UserAgent->new;
$ua->agent("Postgres Build Farm Reporter");
if (my $proxy = $ENV{BF_PROXY})
{
    my $targetURI = URI->new($upgrade_target);
    $ua->proxy($targetURI->scheme,$proxy);
}

my $request=HTTP::Request->new(POST => "$upgrade_target/$sig");
$request->content_type("application/x-www-form-urlencoded");
$request->content($content);

my $response=$ua->request($request);

unless ($response->is_success)
{
    print
      "Query for: animal=$animal&ts=$ts\n",
      "Target: $upgrade_target/$sig\n",
      "Query Content: $content\n";
    print "Status Line: ",$response->status_line,"\n";
    print "Content: \n", $response->content,"\n";
    exit 1;
}

exit(0);

#######################################################################

sub usage
{
    my $opt_message = shift;
    print "$opt_message\n" if $opt_message;
    print  <<EOH;
update_personality.pl [ option ... ]
where option is one or more of
  --config=path                 /path/to/buildfarm.conf
  --os-version=version          new operating system version
  --compiler-version=version    new compiler version
  --help                        get this message
EOH

    exit defined($opt_message)+0;
}

