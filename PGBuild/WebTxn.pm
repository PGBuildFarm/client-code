package PGBuild::WebTxn;

=comment

Copyright (c) 2003-2017, Andrew Dunstan

See accompanying License file for license details


Most of this code is imported from the older standalone script run_web_txn.pl
which is now just a shell that calls the function below. It is now only
needed on older Msys installations (i.e. things running perl < 5.8).

=cut

use strict;
use warnings;

use vars qw($VERSION); $VERSION = 'REL_8';

use vars qw($changed_this_run $changed_since_success $branch $status $stage
  $animal $ts $log_data $confsum $target $verbose $secret);

BEGIN
{
	## no critic (ValuesAndExpressions::ProhibitMismatchedOperators)
	# perlcritic gets confused by version comparisons - this usage is
	# sanctioned by perldoc perlvar

	# see below for why we can't always make these compile time requirements
	if (defined($^V) && $^V ge v5.8.0)
	{
		require LWP;
		require HTTP::Request::Common;
		require MIME::Base64;
		require Digest::SHA;
		require Storable;
	}
}

sub run_web_txn
{

	my $lrname = shift || 'lastrun-logs';

	# make these runtime imports so they are loaded by the perl that's running
	# the procedure. On older Msys it won't be the same as the one that's
	# running run_build.pl.

	require LWP;
	import LWP;
	require HTTP::Request::Common;
	import HTTP::Request::Common;
	require MIME::Base64;
	import MIME::Base64;
	require Digest::SHA;
	import Digest::SHA qw(sha1_hex);
	require Storable;
	import Storable qw(nfreeze);

	# not a hard requirement so we only try this at runtime
	# A number of perl installations won't have JSON::PP installed, although
	# since it's pure perl installing it should be fairly simple.
	my $json_available;
	eval { require JSON::PP; import JSON::PP; };
	$json_available = 1 unless $@;

	# avoid using the Utils file handling here so we don't introduce an
	# additional dependency. It might be OK to use but it might not,
	# so don't risk it. :-)

	my $txfname = "$lrname/web-txn.data";
	my $txdhandle;
	$/ = undef;
	open($txdhandle, '<', "$txfname") or die "opening $txfname: $!";
	my $txdata = <$txdhandle>;
	close($txdhandle);

	eval $txdata;    ## no critic (ProhibitStringyEval)
	if ($@)
	{
		warn $@;
		return;
	}

	my $tarname = "$lrname/runlogs.tgz";
	my $tardata = "";
	if (open($txdhandle, '<', $tarname))
	{
		binmode $txdhandle;
		$tardata = <$txdhandle>;
		close($txdhandle);
	}

	# add our own version string and time
	my $current_ts       = time;
	my $webscriptversion = "'web_script_version' => '$VERSION',\n";
	my $cts              = "'current_ts' => $current_ts,\n";

	# $2 here helps us to preserve the nice spacing from Data::Dumper
	my $scriptline = "((.*)'script_version' => '(REL_)?\\d+(\\.\\d+)*',?\n)";
	$confsum =~ s/$scriptline/$2$webscriptversion$2$cts$1/;
	my $sconf = $confsum;
	$sconf =~ s/.*(\$Script_Config)/$1/ms;
	my $Script_Config;

	# this whole area could do with a revisit
	# but for now just mark the stringy eval as ok
	eval $sconf;    ## no critic (ProhibitStringyEval)

	# for some reason we see intermittent failures of above code
	# so we also set this directly so it gets into frozen_sconf, which is what
	# the server side script examines.
	$Script_Config->{web_script_version} = $VERSION;

	# very modern Storable modules choke on regexes
	# the server has no need of them anyway, so just chop them out
	# they are still there in the text version used for reporting
	foreach my $k (keys %$Script_Config)
	{
		delete $Script_Config->{$k}
		  if ref($Script_Config->{$k}) eq q(Regexp);
	}

	# if we have an available json encoder from JSON::PP then use it and
	# send json. Otherwise fall back to sending a serialized blob made with
	# Storable's nfreeze. The server knows how to tell the difference.
	my $frozen_sconf =
	  $json_available
	  ? encode_json($Script_Config)
	  : nfreeze($Script_Config);

	# make the base64 data escape-proof; = is probably ok but no harm done
	# this ensures that what is seen at the other end is EXACTLY what we
	# see when we calculate the signature

	do { $_ = encode_base64($_, ""); tr/+=/$@/; }
	  foreach ($log_data, $confsum, $changed_this_run, $changed_since_success,
		$tardata, $frozen_sconf);

	my $content =
	    "changed_files=$changed_this_run&"
	  . "changed_since_success=$changed_since_success&"
	  . "branch=$branch&res=$status&stage=$stage&animal=$animal&ts=$ts"
	  . "&log=$log_data&conf=$confsum";
	my $sig = sha1_hex($content, $secret);

	$content .= "&frozen_sconf=$frozen_sconf";

	if ($tardata)
	{
		$content .= "&logtar=$tardata";
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

	unless ($response->is_success || $verbose > 1)
	{
		print
		  "Query for: stage=$stage&animal=$animal&ts=$ts\n",
		  "Target: $target/$sig\n";
		print "Status Line: ", $response->status_line, "\n";
		print "Content: \n",   $response->content,     "\n"
		  if ($verbose && $response->content);
		return;
	}

	return 1;
}

1;
