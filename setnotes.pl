#!/usr/bin/perl

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details

=cut

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_9';

use LWP;
use HTTP::Request::Common;
use MIME::Base64;
use Digest::SHA qw(sha1_hex);
use Getopt::Long;
use File::Spec;
use File::Basename;

BEGIN
{
	unshift(@INC, $ENV{BFLIB}) if $ENV{BFLIB};
	use lib File::Spec->rel2abs(dirname(__FILE__));
}

# copy command line before processing - so we can later report it
# unmunged

my @invocation_args = (@ARGV);

my $buildconf = "build-farm.conf";    # default value
my ($sys_notes, $help, $del);

GetOptions(
	'config=s' => \$buildconf,
	'help'     => \$help,
	'delete'   => \$del,
) || usage("bad command line");

$sys_notes = shift;

usage("No extra args allowed")
  if @_;

usage("must not specify notes if delete flag used")
  if $del && defined($sys_notes);

usage()
  if $help;

usage("must specify notes")
  unless ($del || defined($sys_notes));

#
# process config file
#

our ($branch) = 'HEAD';    # needed for config file, irrelevant for this purpose
require $buildconf;

my ($target, $animal, $secret) = @PGBuild::conf{qw(target animal secret)};

$target =~ s/pgstatus.pl/addnotes.pl/;

# make the base64 data escape-proof; = is probably ok but no harm done
# this ensures that what is seen at the other end is EXACTLY what we
# see when we calculate the signature

do { $_ ||= ""; $_ = encode_base64($_, ""); tr/+=/$@/; }
  foreach ($sys_notes);

my $content = "animal=$animal\&sysnotes=$sys_notes";

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
	  "Query for: animal=$animal\n",
	  "Target: $target/$sig\n",
	  "Query Content: $content\n";
	print "Status Line: ", $response->status_line, "\n";
	print "Content: \n",   $response->content,     "\n";
	exit 1;
}

exit(0);

#######################################################################

sub usage
{
	my $opt_message = shift;
	print "$opt_message\n" if $opt_message;
	print <<'EOH';
set_notes.pl [ option ... ] notes
or
set_notes.pl --delete [ option ... ]

where option is one or more of
  --config=path                 /path/to/buildfarm.conf
  --help                        get this message
EOH

	exit defined($opt_message) + 0;
}

