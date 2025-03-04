package PGBuild::WebTxn;

=comment

Copyright (c) 2003-2024, Andrew Dunstan

See accompanying License file for license details


Most of this code is imported from the older standalone script run_web_txn.pl
which is now just a shell that calls the function below. It is now only
needed on certain Msys installations.

=cut

use strict;
use warnings;

use LWP;
use HTTP::Request::Common;
use MIME::Base64;
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP;

our ($VERSION); $VERSION = 'REL_19';

sub run_web_txn
{
	my $lrname = shift || 'lastrun-logs';

	# avoid using the Utils file handling here so we don't introduce an
	# additional dependency. It might be OK to use but it might not,
	# so don't risk it. :-)

	my $txfname = "$lrname/web-txn.data";
	my $txdhandle;
	local $/ = undef;
	open($txdhandle, '<', "$txfname") or die "opening $txfname: $!";
	my $txdata = <$txdhandle>;
	close($txdhandle);

	# variables we're going to read from $txdata
	my ($changed_this_run, $changed_since_success, $branch, $status, $stage,
		$animal, $ts, $log_data, $confsum, $target, $secret);
	my ($verbose);    ## no critic (ProhibitUnusedVariables)

	eval $txdata;     ## no critic (ProhibitStringyEval)
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
	my $current_ts = time;
	my $webscriptversion = "'web_script_version' => '$VERSION',\n";
	my $cts = "'current_ts' => $current_ts,\n";

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
	# they are still there in the text version used for reporting.
	# Note: we still do this even though we don't use Storable any more
	# on the client, because the server uses Storable.
	foreach my $k (keys %$Script_Config)
	{
		delete $Script_Config->{$k}
		  if ref($Script_Config->{$k}) eq q(Regexp);
	}
	if (ref($Script_Config->{global}->{branches_to_build}) eq q(Regexp))
	{
		delete $Script_Config->{global}->{branches_to_build};
	}

	my $frozen_sconf = encode_json($Script_Config);

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

	$content .= "&frozen_sconf=$frozen_sconf";

	if ($tardata)
	{
		$content .= "&logtar=$tardata";
	}

	my $sig = '.256h.' . hmac_sha256_hex($content, $secret);

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
		  "Query for: stage=$stage&animal=$animal&ts=$ts\n",
		  "Target: $target/$sig\n";
		print "Status Line: ", $response->status_line, "\n";
		print "Content: \n", $response->content, "\n"
		  if $response->content;
		no warnings qw(once);
		print "Request: ", $request->as_string, "\n"
		  if $PGBuild::conf{show_error_request};
		return;
	}

	return 1;
}

1;
